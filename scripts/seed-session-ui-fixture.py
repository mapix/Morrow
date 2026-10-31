"""Copy an isolated demo workspace and seed clearly labelled sessions for native layout QA."""
import argparse,sqlite3,json,time,pathlib,shutil
p=argparse.ArgumentParser();p.add_argument('source');p.add_argument('target');p.add_argument('--count',type=int,default=64);a=p.parse_args()
s=pathlib.Path(a.source).resolve();t=pathlib.Path(a.target).resolve()
assert s!=t and 'evidence/private' in str(t) and 1<=a.count<=200
assert not t.exists() or not any(t.iterdir()),'target must be new/empty'
t.mkdir(parents=True,exist_ok=True)
for f in s.iterdir():
 if f.name.startswith('mail.sqlite'):continue
 if f.is_dir():shutil.copytree(f,t/f.name)
 else:shutil.copy2(f,t/f.name)
src=sqlite3.connect('file:'+str(s/'mail.sqlite')+'?mode=ro',uri=True);db=sqlite3.connect(t/'mail.sqlite');src.backup(db);src.close()
now=time.time()-978307200
for i in range(1,a.count+1):
 ident=f'ui-scale-demo-{i:03}'
 value={'id':ident,'title':f'演示对话 {i:02}：项目整理','createdAt':now-i*60,'updatedAt':now-i*60,'archived':False,'input':f'演示对话{i:02}的未发送内容','materials':[],'newWork':False,'summary':'','draftRevision':0}
 db.execute('insert or replace into objects(kind,id,json) values(?,?,?)',('chat-session',ident,json.dumps(value,ensure_ascii=False).encode()))
row=db.execute("select json from objects where kind='workspace-preferences' and id='main'").fetchone()
value=json.loads(row[0]) if row else {'density':'compact','memoryEnabled':True,'autoMemory':True}
value['activeSessionID']=f'ui-scale-demo-{a.count:03}'
db.execute('insert or replace into objects(kind,id,json) values(?,?,?)',('workspace-preferences','main',json.dumps(value).encode()));db.commit();db.close()
print('Isolated demo fixture:',t,'seeded sessions:',a.count)
