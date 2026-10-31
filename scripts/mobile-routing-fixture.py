#!/usr/bin/env python3
"""Local typed-tool fixture for native navigation and captured mail scopes."""
import json
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

events = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        prompt = body['messages'][-1]['content']
        if 'NATIVE_QA_EDIT' in prompt:
            match = re.search(r'正在编辑但尚未保存的草稿:\n(.+?)\n已确认记忆:', prompt, re.S)
            draft = json.loads(match.group(1)) if match else None
            valid = bool(draft and 'UNSAVED_NATIVE_DRAFT' in draft['body'])
            events.append({'case': 'draft', 'live': valid})
            plan = {'answer': 'Native draft update completed.', 'operations': [
                {'type': 'updateDraft', 'kind': draft['id'], 'text': draft['body'].replace('UNSAVED_NATIVE_DRAFT', 'AI_UPDATED_NATIVE_DRAFT')}
            ]} if valid else {'answer': 'Missing draft', 'operations': []}
        elif 'Tool stats:' in prompt:
            match = re.search(r'Captured mailbox range: (\d+) messages', prompt)
            count = int(match.group(1)) if match else None
            routing = 'NATIVE_ROUTE_' in prompt
            events.append({'case': 'route_scope' if routing else 'stats', 'count': count})
            plan = {'answer': f'Route kept captured mailbox count {count}.' if routing else f'Actual captured mailbox contains {count} messages.', 'operations': []}
        elif 'NATIVE_ROUTE_ATTACHMENT' in prompt:
            match = re.search(r'Tool attachments:\n([^\s]+) [^\n]+ mailID:', prompt)
            if match:
                plan = {'answer': 'Opening the actual attachment.', 'operations': [{'type': 'selectAttachment', 'text': match.group(1)}, {'type': 'stats'}]}
            else:
                plan = {'answer': 'Reading attachment IDs.', 'operations': [{'type': 'attachments'}]}
        elif 'NATIVE_ROUTE_CONTACT' in prompt:
            plan = {'answer': 'Opening the actual contact.', 'operations': [{'type': 'selectContact', 'recipient': 'lin@example.com'}, {'type': 'stats'}]}
        elif 'NATIVE_ROUTE_MAIL' in prompt:
            plan = {'answer': 'Opening the other mailbox message.', 'operations': [{'type': 'select', 'messageID': 'mobile-demo-mail-3'}, {'type': 'stats'}]}
        elif 'NATIVE_ROUTE_SETTINGS' in prompt:
            plan = {'answer': 'Opening settings.', 'operations': [{'type': 'navigate', 'text': '设置'}]}
        else:
            plan = {'answer': 'Reading actual statistics.', 'operations': [{'type': 'stats'}]}
        Path('evidence/mobile-routing-fixture-090.json').write_text(json.dumps({'fixture': True, 'events': events}, indent=2) + '\n')
        data = json.dumps({'message': {'role': 'assistant', 'content': json.dumps(plan)}}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


ThreadingHTTPServer(('127.0.0.1', 49093), Handler).serve_forever()
