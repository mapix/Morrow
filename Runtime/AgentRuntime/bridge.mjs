import { createInterface } from 'node:readline';
import { AsyncLocalStorage } from 'node:async_hooks';
import { createDeepAgent } from 'deepagents';
import { tool, createMiddleware, todoListMiddleware } from 'langchain';
import { Command, interrupt } from '@langchain/langgraph';
import { BaseChatModel } from '@langchain/core/language_models/chat_models';
import { AIMessage, AIMessageChunk } from '@langchain/core/messages';
import { ChatGenerationChunk } from '@langchain/core/outputs';
import { convertToOpenAITool } from '@langchain/core/utils/function_calling';
import { BaseCheckpointSaver, MemorySaver, WRITES_IDX_MAP } from '@langchain/langgraph-checkpoint';
import { z } from 'zod';

// Only protocol records go to stdout. No provider keys or mail credentials are
// supplied to this process; model I/O and all application tools belong to Swift.
const emit = value => process.stdout.write(JSON.stringify(value) + '\n');
const pending = new Map();
const invocation = new AsyncLocalStorage();
let serial = 0;
let fixture;
function rpc(method, params, delta) {
  if (fixture) return fixture(method, params, delta);
  if (pending.size >= 32) return Promise.reject(new Error('Native request queue limit reached'));
  const id = String(++serial);
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject, delta }); emit({ type: 'request', id, method, params });
  });
}

function apiMessage(message) {
  const type = message._getType();
  const role = ({ human: 'user', ai: 'assistant', system: 'system', tool: 'tool' })[type] ?? 'user';
  const value = { role, content: message.content };
  if (role === 'tool') value.tool_call_id = message.tool_call_id;
  if (message.additional_kwargs?.morrow_response_items) value.providerItems = message.additional_kwargs.morrow_response_items;
  if (message.tool_calls?.length) value.tool_calls = message.tool_calls.map(call => ({
    id: call.id, type: 'function', function: { name: call.name, arguments: JSON.stringify(call.args) },
  }));
  return value;
}

export class NativeChatModel extends BaseChatModel {
  constructor(window = 16384) { super({ maxRetries: 0 }); this.window = window; this.turns = 0; }
  _llmType() { return 'morrow-native'; }
  get profile() { return { maxInputTokens: this.window, toolCalling: true, structuredOutput: false }; }
  bindTools(tools, kwargs = {}) { return this.withConfig({ ...kwargs, tools: tools.map(value => convertToOpenAITool(value)) }); }
  async _generate(messages, options, manager) {
    if (++this.turns > 24) throw new Error('Model turn budget reached');
    const response = await rpc('model', {
      messages: messages.map(apiMessage), tools: options.tools ?? [],
      toolChoice: options.tool_choice ?? 'auto', maxTokens: 1800,
    }, async text => { await manager?.handleLLMNewToken(text); });
    const message = new AIMessage({
      content: response.content ?? '', tool_calls: response.toolCalls ?? [],
      additional_kwargs: response.replay ? { morrow_response_items: response.replay } : {},
      usage_metadata: response.usage,
      response_metadata: { finish_reason: response.finishReason, model: response.model },
    });
    return { generations: [{ text: typeof message.content === 'string' ? message.content : '', message }] };
  }
  async *_streamResponseChunks(messages, options, manager) {
    const value = await this._generate(messages, options, manager);
    const message = value.generations[0].message;
    yield new ChatGenerationChunk({ text: value.generations[0].text, message: new AIMessageChunk({
      content: message.content, tool_calls: message.tool_calls,
      usage_metadata: message.usage_metadata, response_metadata: message.response_metadata,
    }) });
  }
}

// LangGraph owns checkpoint semantics and serialization. The host stores the
// opaque records in the existing private SQLite database, not another database.
class NativeCheckpointer extends BaseCheckpointSaver {
  async pack(value) { const [type, bytes] = await this.serde.dumpsTyped(value); return { type, data: Buffer.from(bytes).toString('base64') }; }
  async unpack(value) { return this.serde.loadsTyped(value.type, Buffer.from(value.data, 'base64')); }
  async getTuple(config) {
    const value = await rpc('checkpoint.get', { config: config.configurable ?? {} });
    if (!value) return undefined;
    return {
      config: value.config, parentConfig: value.parentConfig,
      checkpoint: await this.unpack(value.checkpoint), metadata: await this.unpack(value.metadata),
      pendingWrites: await Promise.all((value.writes ?? []).map(async write => [write.taskId, write.channel, await this.unpack(write.value)])),
    };
  }
  async *list(config, options = {}) {
    const values = await rpc('checkpoint.list', { config: config.configurable ?? {}, options });
    for (const value of values) { const tuple = await this.getTuple(value); if (tuple) yield tuple; }
  }
  async put(config, checkpoint, metadata) {
    const configurable = { ...(config.configurable ?? {}), checkpoint_id: checkpoint.id, checkpoint_ns: config.configurable?.checkpoint_ns ?? '' };
    await rpc('checkpoint.put', {
      config: { configurable }, parentConfig: config.configurable?.checkpoint_id ? { configurable: config.configurable } : undefined,
      checkpoint: await this.pack(checkpoint), metadata: await this.pack(metadata), timestamp: checkpoint.ts,
    });
    return { configurable };
  }
  async putWrites(config, writes, taskId, taskPath = '') {
    const values = await Promise.all(writes.map(async ([channel, value], index) => ({ taskId, taskPath, index: WRITES_IDX_MAP[channel] ?? index, channel, value: await this.pack(value) })));
    await rpc('checkpoint.writes', { config: config.configurable ?? {}, writes: values });
  }
  async deleteThread(threadId) { await rpc('checkpoint.delete', { threadId }); }
}

export async function runAgent(request, checkpointer = new NativeCheckpointer()) {
  const model = new NativeChatModel(request.contextWindow ?? 16384);
  const tools = request.tools.map(description => tool(async args => {
    try {
      const result = await rpc('tool', { name: description.name, args, callId: invocation.getStore()?.id });
      return typeof result === 'string' ? result : JSON.stringify(result);
    } catch (error) {
      return JSON.stringify({ ok: false, error: String(error.message).slice(0, 500), instruction: '未完成此操作。仅在原有权限内调整查询；不得扩大来源范围或把失败描述为成功。' });
    }
  }, { name: description.name, description: description.description, schema: z.fromJSONSchema(description.parameters) }));
  const enabled = new Set(['search_mail', 'scan_mail', 'read_mail', 'mail_statistics', 'cite_sources', 'render_ui', 'list_accounts', 'workspace_state']);
  const groups = [
    [/草稿|回复|写邮件|draft|reply|compose/i, /draft|reply|compose|forward|review_send/],
    [/联系人|画像|contact|people/i, /contact/], [/附件|文件|截图|分析|attachment|file|material|report|code/i, /attachment|material|report|code/],
    [/记忆|偏好|memory|remember/i, /memor|remember/], [/设置|模型|主题|语言|布局|settings|model|theme|language|density/i, /settings|model|theme|language|density/],
    [/会话|对话|session|chat/i, /session/], [/响应|委托|自动|responder|delegate/i, /responder|delegation/],
    [/批量|标记|归档|删除|标签|邮箱|邮件|mail|folder|account|batch/i, /mail|folder|account|search/],
  ];
  const finder = tool(({ query, offset = 0 }) => {
    const matchers = groups.filter(([pattern]) => pattern.test(query)).map(([, pattern]) => pattern);
    let found = request.tools.filter(value => matchers.some(pattern => pattern.test(value.name)) || value.name.includes(query) || value.description.includes(query));
    if (!found.length) found = request.tools;
    const terms = query.toLowerCase().split(/[\s,，:：]+/).filter(Boolean);
    const score = value => terms.reduce((sum, term) => sum + (value.name.toLowerCase().includes(term) ? 10 : 0) + (value.description.toLowerCase().includes(term) ? 5 : 0), 0);
    found.sort((left, right) => score(right) - score(left));
    const page = found.slice(offset, offset + 24); page.forEach(value => enabled.add(value.name));
    return JSON.stringify({ total: found.length, nextOffset: offset + page.length < found.length ? offset + page.length : null, tools: page.map(value => ({ name: value.name, description: value.description.slice(0, 160), loaded: enabled.has(value.name) })) });
  }, { name: 'find_tools', description: '按目的发现并加载更多邮件、草稿、联系人、附件、设置、会话和响应器工具。找不到功能时先用此工具，query可用中文或英文主题，offset继续查看更多工具。', schema: z.object({ query: z.string(), offset: z.number().int().min(0).optional() }) });
  const nativeNames = new Set(request.tools.map(value => value.name));
  const discovery = createMiddleware({ name: 'MorrowToolDiscovery', wrapModelCall: async (request, handler) => handler({ ...request, tools: request.tools.filter(value => !nativeNames.has(value.name) || enabled.has(value.name)) }) });
  let modelCalls = 0, toolCalls = 0;
  const telemetry = createMiddleware({
    name: 'MorrowExecution',
    wrapToolCall: async (request, handler) => {
      if (++toolCalls > 128) throw new Error('Tool budget reached');
      const name = request.toolCall.name;
      emit({ type: 'phase', stage: 'tool_start', name, step: toolCalls });
      try {
        const value = await invocation.run({ id: request.toolCall.id }, () => handler(request));
        if (name === 'render_ui' && typeof value.content === 'string') {
          let prepared; try { prepared = JSON.parse(value.content); } catch {}
          if (prepared?.requiresUserInput) {
            const choice = interrupt({ kind: 'openui', interactionID: prepared.interactionID });
            value.content = JSON.stringify({ ...prepared, userChoice: choice, requiresUserInput: false });
          }
        }
        let failed = false;
        if (typeof value.content === 'string') { try { failed = JSON.parse(value.content)?.ok === false; } catch {} }
        emit({ type: 'phase', stage: failed ? 'tool_error' : 'tool_end', name, step: toolCalls }); return value;
      }
      catch (error) { emit({ type: 'phase', stage: 'tool_error', name, step: toolCalls }); throw error; }
    },
  });
  const callbacks = [{
    handleLLMStart() { emit({ type: 'phase', stage: 'model', step: ++modelCalls }); },
    handleLLMNewToken(token) { emit({ type: 'text_delta', text: token }); },
  }];
  const agent = createDeepAgent({ name: 'Morrow', model, tools: [...tools, finder], systemPrompt: request.systemPrompt, checkpointer, middleware: [todoListMiddleware(), discovery, telemetry] });
  const history = (request.history ?? []).map(value => ({ role: value.role === 'partner' ? 'assistant' : value.role, content: value.text }));
  const config = { configurable: { thread_id: request.sessionID }, recursionLimit: 128, callbacks };
  // History seeds only new SDK sessions; checkpointed sessions carry their own
  // replay history and must not receive duplicated conversation transcripts.
  const previous = await checkpointer.getTuple(config);
  const messages = [...(previous ? [] : history), { role: 'user', content: request.instruction }];
  const result = await agent.invoke(request.resume === undefined ? { messages } : new Command({ resume: request.resume }), config);
  if (result.__interrupt__?.length) return { text: '需要你的选择才能继续，填写下方内容后发送。', modelCalls, toolCalls, runtime: 'deepagents/1.16.2', todos: result.todos ?? [], paused: true, interrupts: result.__interrupt__ };
  const last = [...result.messages].reverse().find(message => message._getType() === 'ai' && !message.tool_calls?.length);
  const text = typeof last?.content === 'string' ? last.content : (last?.content ?? []).filter(value => value.type === 'text').map(value => value.text).join('\n');
  if (!text?.trim()) throw new Error('Agent ended without a final answer');
  return { text, modelCalls, toolCalls, runtime: 'deepagents/1.16.2', todos: result.todos ?? [], paused: false };
}

async function selfTest() {
  let turn = 0; const called = [];
  fixture = async (method, params, delta) => {
    if (method === 'tool') { called.push(params.name); return { source: 'synthetic-mail', found: true }; }
    if (method === 'model') {
      const toolCalls = ++turn === 1 ? [{ id: 'fixture-call', name: 'search_mail', args: { query: 'game monetization' }, type: 'tool_call' }] : [];
      return { content: toolCalls.length ? '' : 'Verified synthetic mail result', toolCalls, model: 'fixture' };
    }
    throw new Error('Unexpected fixture request');
  };
  const result = await runAgent({ sessionID: 'synthetic', instruction: 'Find game monetization mail', systemPrompt: 'Use search before answering.', tools: [{ name: 'search_mail', description: 'Search mail', parameters: { type: 'object', properties: { query: { type: 'string' } }, required: ['query'] } }] }, new MemorySaver());
  if (result.text !== 'Verified synthetic mail result' || called.join() !== 'search_mail' || turn !== 2) throw new Error('SDK tool loop did not complete');
  emit({ type: 'self_test', result: 'passed', ...result });
  let discovered = 0;
  fixture = async (method, params) => {
    if (method === 'tool') return { draftID: 'synthetic-draft', sent: false };
    if (method !== 'model') throw new Error('Unexpected discovery request');
    const names = params.tools.map(value => value.function?.name);
    const step = ++discovered;
    if (step === 1 && names.includes('prepare_draft')) throw new Error('All tools were eagerly loaded');
    if (step === 2 && !names.includes('prepare_draft')) throw new Error('Tool discovery did not load the requested tool');
    return { content: step === 3 ? 'Discovered draft tool' : '', toolCalls: step === 1 ? [{ id: 'find', name: 'find_tools', args: { query: 'draft' }, type: 'tool_call' }] : step === 2 ? [{ id: 'draft', name: 'prepare_draft', args: { text: 'Synthetic reply' }, type: 'tool_call' }] : [] };
  };
  const discovery = await runAgent({ sessionID: 'discover', instruction: 'Prepare a draft', systemPrompt: 'Discover the tool first.', tools: [{ name: 'prepare_draft', description: 'Prepare a draft', parameters: { type: 'object', properties: { text: { type: 'string' } }, required: ['text'] } }] }, new MemorySaver());
  if (discovery.text !== 'Discovered draft tool' || discovered !== 3) throw new Error('Discovery run failed');
  emit({ type: 'self_test_discovery', result: 'passed' });
}

if (process.argv.includes('--self-test')) {
  await selfTest();
} else {
  const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
  let started = false;
  lines.on('line', line => {
    if (Buffer.byteLength(line) > 24 * 1024 * 1024) { emit({ type: 'error', message: 'Protocol size limit reached' }); process.exit(1); }
    let value; try { value = JSON.parse(line); } catch { emit({ type: 'error', message: 'Invalid native protocol record' }); process.exit(1); }
    if (value.type === 'start' && !started) {
      started = true;
      runAgent(value).then(result => { emit({ type: 'complete', result }); lines.close(); }).catch(error => { emit({ type: 'error', message: String(error.message ?? 'SDK run failed').slice(0, 500) }); lines.close(); });
    } else if (value.id && pending.has(value.id)) {
      const handler = pending.get(value.id);
      if (value.type === 'delta') { handler.delta?.(value.text ?? ''); return; }
      pending.delete(value.id); value.error ? handler.reject(new Error(value.error)) : handler.resolve(value.result);
    }
  });
  lines.on('close', () => { for (const value of pending.values()) value.reject(new Error('Native channel closed')); pending.clear(); });
}
