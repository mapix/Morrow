#!/usr/bin/env python3
import socketserver, threading, json, pathlib, sys, time
root = pathlib.Path(sys.argv[1]); root.mkdir(parents=True, exist_ok=True)
raw = b'From: Fixture <sender@example.com>\r\nTo: test@example.com\r\nSubject: Fixture mail\r\nDate: Fri, 30 Oct 2026 10:00:00 +0800\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nPlease confirm the review time.\r\n'
class IMAP(socketserver.StreamRequestHandler):
    def handle(self):
        seen = False
        def send(s): self.wfile.write(s if isinstance(s, bytes) else s.encode()); self.wfile.flush()
        send('* OK Fixture IMAP ready\r\n')
        while True:
            line = self.rfile.readline()
            if not line: return
            tag, _, command = line.decode().strip().partition(' '); upper = command.upper()
            if upper == 'CAPABILITY': send('* CAPABILITY IMAP4rev1 ID MOVE UIDPLUS\r\n')
            elif upper.startswith('LOGIN') or upper.startswith('ID '): pass
            elif upper.startswith('LIST'): send('* LIST (\\HasNoChildren) "/" "INBOX"\r\n* LIST (\\Sent) "/" "Sent"\r\n')
            elif upper.startswith('SELECT'): send('* 1 EXISTS\r\n* OK [UIDVALIDITY 42] valid\r\n')
            elif upper.startswith('UID FETCH') and 'BODY' in upper:
                if 'PEEK' not in upper: seen = True
                send(f'* 1 FETCH (UID 7 BODY[] {{{len(raw)}}}\r\n')
                for start in range(0, len(raw), 13): send(raw[start:start+13])
                send(')\r\n')
            elif upper.startswith('UID FETCH'): send('* 1 FETCH (UID 7 FLAGS (' + ('\\Seen' if seen else '') + '))\r\n')
            elif upper.startswith('UID STORE'): seen = '+FLAGS' in upper
            elif upper.startswith('UID MOVE'): send(tag+' OK [COPYUID 99 7 9] moved\r\n'); continue
            elif upper == 'LOGOUT': send('* BYE\r\n'); send(tag+' OK bye\r\n'); return
            else: send(tag+' BAD unsupported\r\n'); continue
            send(tag + ' OK completed\r\n')
class SMTP(socketserver.StreamRequestHandler):
    def handle(self):
        recipients=[]
        def send(s): self.wfile.write(s.encode()); self.wfile.flush()
        send('220 Fixture SMTP\r\n')
        while True:
            line=self.rfile.readline()
            if not line: return
            text=line.decode().strip(); upper=text.upper()
            if upper.startswith('EHLO'): send('250-fixture\r\n250 AUTH PLAIN LOGIN\r\n')
            elif upper.startswith('AUTH PLAIN'):
                if len(text.split()) == 2: send('334 \r\n'); self.rfile.readline()
                send('235 authenticated\r\n')
            elif upper.startswith('AUTH LOGIN'):
                send('334 VXNlcm5hbWU6\r\n'); self.rfile.readline()
                send('334 UGFzc3dvcmQ6\r\n'); self.rfile.readline()
                send('235 authenticated\r\n')
            elif upper.startswith('MAIL FROM'): send('250 sender accepted\r\n')
            elif upper.startswith('RCPT TO'): recipients.append(text); send('250 recipient accepted\r\n')
            elif upper == 'DATA':
                send('354 send data\r\n'); lines=[]
                while True:
                    part=self.rfile.readline()
                    if part == b'.\r\n': break
                    lines.append(part)
                (root/'smtp.eml').write_bytes(b''.join(lines)); (root/'smtp-envelope.json').write_text(json.dumps(recipients)); send('250 queued fixture-receipt\r\n')
            elif upper == 'QUIT': send('221 bye\r\n'); return
            else: send('250 ok\r\n')
class POP(socketserver.StreamRequestHandler):
    def handle(self):
        def send(value): self.wfile.write(value if isinstance(value,bytes) else value.encode()); self.wfile.flush()
        send('+OK Fixture POP ready\r\n')
        while True:
            line=self.rfile.readline()
            if not line: return
            command=line.decode().strip().upper()
            if command.startswith('USER ') or command.startswith('PASS '): send('+OK authenticated\r\n')
            elif command=='UIDL': send('+OK listing\r\n1 stable-id-1\r\n.\r\n')
            elif command=='UIDL 1': send('+OK 1 stable-id-1\r\n')
            elif command=='RETR 1':
                send('+OK message\r\n')
                data=raw+b'.Leading dot\r\n'
                for part in data.split(b'\r\n')[:-1]: send((b'.'+part if part.startswith(b'.') else part)+b'\r\n')
                send('.\r\n')
            elif command=='QUIT': send('+OK bye\r\n'); return
            elif command.startswith('DELE'): send('-ERR deletion not expected\r\n'); raise RuntimeError('POP fixture received deletion')
            else: send('-ERR unsupported\r\n')
class Server(socketserver.ThreadingTCPServer): allow_reuse_address=True; daemon_threads=True
imap=Server(('127.0.0.1',0),IMAP); smtp=Server(('127.0.0.1',0),SMTP); pop=Server(('127.0.0.1',0),POP)
(root/'ports.json').write_text(json.dumps({'imap':imap.server_address[1],'smtp':smtp.server_address[1],'pop':pop.server_address[1]}))
threading.Thread(target=imap.serve_forever,daemon=True).start(); threading.Thread(target=smtp.serve_forever,daemon=True).start()
threading.Thread(target=pop.serve_forever,daemon=True).start()
print('ready', flush=True)
while True: time.sleep(1)
