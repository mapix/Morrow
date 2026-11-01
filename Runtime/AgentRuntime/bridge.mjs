import { createInterface } from 'node:readline';
import { randomUUID } from 'node:crypto';
import { Agent, Runner, RunState, tool, Usage, setTracingDisabled } from '@openai/agents';
import { z } from 'zod';

setTracingDisabled(true);
const emit = value => process.stdout.write(JSON.stringify(value) + '\n');
const pending = new Map(); let serial = 0, fixture;
function rpc(method, params, delta) {
  if (fixture) return fixture(method, params, delta);
  if (pending.size >= 32) return Promise.reject(new Error('Native request queue limit reached'));
  const id = String(++serial);
  return new Promise((resolve, reject) => { pending.set(id, { resolve, reject, delta }); emit({ type: 'request', id, method, params }); });
}
const text = value => typeof value === 'string' ? value : Array.isArray(value) ? value.filter(x => ['text', 'input_text', 'output_text'].includes(x.type)).map(x => x.text ?? '').join('\n') : ['text','input_text','output_text'].includes(value?.type) ? value.text ?? '' : JSON.stringify(value ?? '');

class NativeModel {
  turns = 0;
  async getResponse(request) {
    if (++this.turns > 24) throw new Error('Model turn budget reached');
    const startedAt = Date.now(); emit({ type: 'phase', stage: 'model', step: this.turns, startedAt });
    const messages = request.systemInstructions ? [{ role: 'system', content: request.systemInstructions }] : [];
    const items = typeof request.input === 'string' ? [{ role: 'user', content: request.input }] : request.input;
    const replayGroups = new Set();
    for (const item of items) {
      const group = item.providerData?.morrowGroup;
      if (group && replayGroups.has(group)) continue;
      if (item.providerData?.morrowReplay) { messages.push({ role: 'assistant', content: '', providerItems: item.providerData.morrowReplay }); replayGroups.add(group); continue; }
      if (item.type === 'function_call') messages.push({ role: 'assistant', content: '', tool_calls: [{ id: item.callId, type: 'function', function: { name: item.name, arguments: item.arguments } }] });
      else if (item.type === 'function_call_result') messages.push({ role: 'tool', tool_call_id: item.callId, content: text(item.output) });
      else if (item.role) messages.push({ role: item.role, content: text(item.content) });
    }
    const tools = [...request.tools.filter(x => x.type === 'function').map(x => ({ type: 'function', function: { name: x.name, description: x.description, parameters: x.parameters, strict: false } })),
      ...request.handoffs.map(x => ({ type: 'function', function: { name: x.toolName, description: x.toolDescription, parameters: x.inputJsonSchema, strict: false } }))];
    const response = await rpc('model', { messages, tools, maxTokens: request.modelSettings.maxTokens ?? 1800, toolChoice: 'auto' }, chunk => emit({ type: 'text_delta', text: chunk }));
    emit({ type: 'model_timing', step: this.turns, elapsedMs: Date.now() - startedAt, ...(response.timing ?? {}), model: response.model });
    const output = (response.toolCalls ?? []).map(call => ({ type: 'function_call', id: call.id, callId: call.id, name: call.name, arguments: JSON.stringify(call.args), status: 'completed' }));
    if (response.content) output.push({ type: 'message', role: 'assistant', id: randomUUID(), status: 'completed', content: [{ type: 'output_text', text: response.content }] });
    if (response.replay && output.length) { const group = randomUUID(); output.forEach(x => { x.providerData = { morrowGroup: group }; }); output[0].providerData.morrowReplay = response.replay; }
    return { usage: new Usage(response.usage ?? {}), output };
  }
  async *getStreamedResponse(request) { yield { type: 'response_started' }; const response = await this.getResponse(request); yield { type: 'response_done', response }; }
}

class NativeSession {
  constructor(id) { this.id = id; this.items = undefined; }
  async getSessionId() { return this.id; }
  async getItems(limit) { if (!this.items) this.items = await rpc('state.get', { key: 'history' }) ?? []; return limit ? this.items.slice(-limit) : [...this.items]; }
  async addItems(items) { const existing = await this.getItems(); this.items = [...existing, ...items]; await rpc('state.set', { key: 'history', value: this.items }); }
  async popItem() { await this.getItems(); const last = this.items.pop(); await rpc('state.set', { key: 'history', value: this.items }); return last; }
  async clearSession() { this.items = []; await rpc('state.remove', { key: 'history' }); }
}

export async function runAgent(request) {
  const model = new NativeModel(), session = new NativeSession(request.sessionID);
  const enabled = new Set(['search_mail', 'scan_mail', 'read_mail', 'mail_statistics', 'cite_sources', 'render_ui', 'list_accounts', 'workspace_state', 'prepare_draft', 'read_draft', 'update_draft']);
  const calls = new Map(); let toolCalls = 0, plan = await rpc('state.get', { key: 'plan' }) ?? [];
  const native = async (description, args, id) => rpc('tool', { name: description.name, args, callId: id });
  const tools = request.tools.map(description => tool({
    name: description.name, description: description.description, parameters: description.parameters, strict: false,
    isEnabled: () => enabled.has(description.name),
    needsApproval: description.name === 'render_ui' ? async (context, args, callId) => !!(await native(description, args, callId))?.requiresUserInput : false,
    execute: async (args, context, details) => {
      const result = await native(description, args, details?.toolCall?.callId ?? randomUUID());
      return description.name === 'render_ui' && context?.context?.userChoice ? { ...result, requiresUserInput: false, userChoice: context.context.userChoice } : result;
    },
    errorFunction: (_, error) => ({ ok: false, error: String(error.message).slice(0, 500), instruction: '未完成此操作。仅在原有权限内调整查询，不能把失败描述为成功。' }),
  }));
  tools.push(tool({ name: 'find_tools', description: '按中文或英文目的查找并加载更多邮件、草稿、联系人、附件、设置、会话、响应器工具；offset继续查看。',
    parameters: z.object({ query: z.string(), offset: z.number().int().min(0).optional() }),
    execute: ({ query, offset = 0 }) => {
      const groups = [[/草稿|回复|draft|reply|compose/i, /draft|reply|compose|forward/], [/联系人|画像|contact/i, /contact/], [/附件|文件|分析|attachment|material|report|code/i, /attachment|material|report|code/], [/记忆|memory/i, /memor|remember/], [/设置|模型|主题|语言|布局|settings|model|theme|language|density/i, /settings|model|theme|language|density/], [/会话|session/i, /session/], [/响应|委托|responder|delegate/i, /responder|delegation/], [/邮件|邮箱|批量|标记|mail|folder/i, /mail|folder|account|search/]];
      const patterns = groups.filter(([test]) => test.test(query)).map(([, test]) => test);
      let found = request.tools.filter(x => patterns.some(test => test.test(x.name)) || x.name.includes(query) || x.description.includes(query));
      if (!found.length) found = request.tools;
      const terms = query.toLowerCase().split(/[\s,，]+/); const score = x => terms.reduce((n, t) => n + (x.name.includes(t) ? 10 : 0) + (x.description.includes(t) ? 5 : 0), 0);
      found.sort((a,b) => score(b)-score(a)); const page = found.slice(offset, offset + 24); page.forEach(x => enabled.add(x.name));
      return { total: found.length, nextOffset: offset + page.length < found.length ? offset + page.length : null, tools: page.map(x => ({ name: x.name, description: x.description.slice(0, 180) })) };
    },
  }));
  tools.push(tool({ name: 'write_plan', description: '给用户展示清楚的执行计划，复杂任务开始时调用，实际推进后更新pending/in_progress/completed状态。规划不是执行完成证明。',
    parameters: z.object({ steps: z.array(z.object({ id: z.string(), title: z.string(), status: z.enum(['pending','in_progress','completed']) })).max(16) }),
    execute: async ({ steps }) => { plan = steps; await rpc('state.set', { key: 'plan', value: steps }); emit({ type: 'plan', steps }); return { saved: true }; },
  }));
  let files = await rpc('state.get', { key: 'files' }) ?? {};
  const filePath = path => { if (!path.startsWith('/') || path.includes('..') || path.length > 256) throw new Error('Invalid virtual path'); return path; };
  const saveFiles = async () => { if (JSON.stringify(files).length > 1024 * 1024) throw new Error('Virtual file budget reached'); await rpc('state.set', { key: 'files', value: files }); };
  tools.push(tool({ name: 'list_files', description: '列出本会话的虚拟工作文件，不访问Mac文件系统。', parameters: z.object({}), execute: () => Object.entries(files).map(([path, content]) => ({ path, characters: content.length })) }));
  tools.push(tool({ name: 'read_file', description: '读取本会话虚拟文件，offset为字符起点，最多8000字。', parameters: z.object({ path: z.string(), offset: z.number().int().min(0).optional() }), execute: ({ path, offset=0 }) => { const content = files[filePath(path)]; if (content === undefined) throw new Error('Virtual file not found'); return { text: content.slice(offset, offset+8000), nextOffset: offset+8000 < content.length ? offset+8000 : null }; } }));
  tools.push(tool({ name: 'write_file', description: '创建或替换虚拟工作文件，最多128 KiB；交付给用户请用save_report。', parameters: z.object({ path: z.string(), content: z.string() }), execute: async ({ path, content }) => { if (Buffer.byteLength(content)>128*1024) throw new Error('File too large'); files[filePath(path)]=content; await saveFiles(); return { saved:true }; } }));
  tools.push(tool({ name: 'edit_file', description: '在虚拟文件中做精确文字替换。', parameters: z.object({ path:z.string(), oldText:z.string(), newText:z.string() }), execute: async ({path,oldText,newText}) => { path=filePath(path); if (!oldText || !files[path]?.includes(oldText)) throw new Error('Exact text not found'); files[path]=files[path].replace(oldText,newText); await saveFiles(); return {saved:true}; } }));
  tools.push(tool({ name:'grep_files', description:'按文字搜索本会话虚拟文件。', parameters:z.object({ query:z.string() }), execute:({query}) => Object.keys(files).filter(path=>files[path].includes(query)) }));
  const instructions = request.systemPrompt + '\n复杂任务先用write_plan给出简短计划，并按实际进度更新。先取得足够事实再交付，不重复读取已取得资料。更多工具用find_tools发现。';
  const specialist = new Agent({ name:'Morrow research', instructions:'处理被委托的邮件或附件分析任务，只根据工具事实，简短返回结论和来源。\n'+instructions, model, tools });
  tools.push(specialist.asTool({ toolName:'delegate_task', toolDescription:'把明确的邮件或附件分析子任务交给独立SDK Agent处理，继承相同原生权限。' }));
  const agent = new Agent({ name:'Morrow', instructions, model, tools });
  const runner = new Runner({ tracingDisabled:true, modelSettings:{ maxTokens:1800 } });
  runner.on('agent_tool_start', (_,agent,tool,details) => { if (++toolCalls>128) throw new Error('Tool budget reached'); const id=details.toolCall.callId;calls.set(id,Date.now()); emit({type:'phase',stage:'tool_start',name:tool.name,id,step:toolCalls,startedAt:Date.now()}); });
  runner.on('agent_tool_end', (_,agent,tool,result,details) => { const id=details.toolCall.callId;let failed=false;try{failed=JSON.parse(result)?.ok===false}catch{};emit({type:'phase',stage:failed?'tool_error':'tool_end',name:tool.name,id,step:toolCalls,elapsedMs:Date.now()-(calls.get(id)??Date.now())});calls.delete(id); });
  if (plan.length) emit({type:'plan',steps:plan});
  let input = request.instruction;
  const saved = await rpc('state.get',{key:'run'}), context = {userChoice:request.resume};
  if (saved && request.resume !== undefined) { input=await RunState.fromString(agent,saved); for (const approval of input.getInterruptions()) input.approve(approval); }
  else if (!(await session.getItems()).length && request.history?.length) await session.addItems(request.history.map(x=> x.role==='partner'?{type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:x.text}]}:{role:x.role,content:x.text}));
  const result = await runner.run(agent,input,{session,context,maxTurns:24});
  if (result.interruptions.length) { await rpc('state.set',{key:'run',value:result.state.toString()});return {text:'需要你的选择才能继续，填写下方内容后发送。',modelCalls:model.turns,toolCalls,runtime:'openai-agents/0.21.0',todos:plan,paused:true,interrupts:result.interruptions.map(x=>({name:x.rawItem.name,callId:x.rawItem.callId}))}; }
  await rpc('state.remove',{key:'run'});
  return {text:String(result.finalOutput??''),modelCalls:model.turns,toolCalls,runtime:'openai-agents/0.21.0',todos:plan,paused:false};
}

async function selfTest() {
  const state = new Map(); let turn=0,called=0;
  fixture=async(method,params)=>{ if(method==='state.get')return state.get(params.key)??null; if(method==='state.set'){state.set(params.key,params.value);return null}if(method==='state.remove'){state.delete(params.key);return null} if(method==='tool'){called++;return {found:true}}if(method==='model'){return {content:++turn===1?'':'SDK verified',toolCalls:turn===1?[{id:'test-call',name:'search_mail',args:{query:'game'}}]:[]}}throw new Error('Unknown fixture method')};
  const result=await runAgent({sessionID:'test',instruction:'Search mail',systemPrompt:'Use search_mail before answering.',tools:[{name:'search_mail',description:'Search mail',parameters:{type:'object',properties:{query:{type:'string'}},required:['query']}}]});
  if(result.text!=='SDK verified'||called!==1||turn!==2)throw new Error('SDK loop failed');emit({type:'self_test',result:'passed',...result});
}
if(process.argv.includes('--self-test'))await selfTest();
else {
  const lines=createInterface({input:process.stdin,crlfDelay:Infinity});let started=false;
  lines.on('line',line=>{if(Buffer.byteLength(line)>24*1024*1024){emit({type:'error',message:'Protocol size limit reached'});process.exit(1)}let value;try{value=JSON.parse(line)}catch{emit({type:'error',message:'Invalid protocol record'});process.exit(1)}
    if(value.type==='start'&&!started){started=true;runAgent(value).then(result=>{emit({type:'complete',result});lines.close()}).catch(error=>{emit({type:'error',message:String(error.message??'SDK run failed').slice(0,500)});lines.close()})}
    else if(value.id&&pending.has(value.id)){const handler=pending.get(value.id);if(value.type==='delta'){handler.delta?.(value.text??'');return}pending.delete(value.id);value.error?handler.reject(new Error(value.error)):handler.resolve(value.result)}
  });lines.on('close',()=>{for(const value of pending.values())value.reject(new Error('Native channel closed'));pending.clear()});
}
