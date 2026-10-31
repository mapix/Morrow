#!/usr/bin/env python3
"""Local protocol fixture for native mobile orchestration, never a live model."""
import json
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

RESULT = Path("evidence/mobile-agent-fixture-090.json")
events = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        prompt = payload["messages"][-1]["content"]
        if "NATIVE_QA_EDIT" in prompt:
            match = re.search(r"正在编辑但尚未保存的草稿:\n(.+?)\n已确认记忆:", prompt, re.S)
            draft = json.loads(match.group(1)) if match else None
            valid = bool(draft and "UNSAVED_NATIVE_DRAFT" in draft["body"])
            events.append({"case": "unsaved_draft", "has_live_draft": valid})
            plan = {"answer": "Native draft update completed.", "operations": [
                {"type": "updateDraft", "kind": draft["id"],
                 "text": draft["body"].replace("UNSAVED_NATIVE_DRAFT", "AI_UPDATED_NATIVE_DRAFT")}
            ]} if valid else {"answer": "Missing unsaved draft snapshot.", "operations": []}
        elif "Tool stats:" in prompt:
            match = re.search(r"Captured mailbox range: (\d+) messages", prompt)
            count = int(match.group(1)) if match else None
            events.append({"case": "stats_synthesis", "received_real_tool_result": count is not None, "count": count})
            plan = {"answer": f"Actual captured mailbox contains {count} messages.", "operations": []}
        else:
            events.append({"case": "stats_request"})
            plan = {"answer": "Reading actual mailbox statistics.", "operations": [{"type": "stats"}]}
        RESULT.write_text(json.dumps({"fixture": True, "events": events}, indent=2) + "\n")
        data = json.dumps({"message": {"role": "assistant", "content": json.dumps(plan)}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


ThreadingHTTPServer(("127.0.0.1", 49093), Handler).serve_forever()
