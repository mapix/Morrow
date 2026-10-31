import json,sys
from http.server import BaseHTTPRequestHandler,HTTPServer
from pathlib import Path
root=Path(sys.argv[1]); root.mkdir(parents=True,exist_ok=True)
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_GET(self):
  assert self.path=='/v1/models'
  (root/'catalog-auth.txt').write_text(self.headers.get('Authorization',''))
  self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(json.dumps({'data':[{'id':'fixture-model'}]}).encode())
 def do_POST(self):
  assert self.path=='/v1/chat/completions'
  payload=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  (root/'request.json').write_text(json.dumps(payload))
  (root/'completion-auth.txt').write_text(self.headers.get('Authorization',''))
  self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(json.dumps({'choices':[{'message':{'content':'连接成功'}}]}).encode())
server=HTTPServer(('127.0.0.1',0),Handler); (root/'port.txt').write_text(str(server.server_port)); server.serve_forever()
