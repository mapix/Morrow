#!/usr/bin/env python3
"""Loopback-only XOAUTH2 transcript gates; accepts only a fixed dummy credential.

Usage: python3 scripts/oauth-imap-fixture.py /absolute/fixture-directory
The directory receives ports.json and sanitized per-case transcript JSON.
No received credential bytes are written to logs or evidence.
"""

import base64
import json
import pathlib
import signal
import socketserver
import sys
import threading


FIXTURE_EMAIL = "fixture@example.com"
FIXTURE_TOKEN = "dummy-token"
EXPECTED_PAYLOAD = (
    f"user={FIXTURE_EMAIL}\x01auth=Bearer {FIXTURE_TOKEN}\x01\x01".encode("ascii")
)
CASES = ("sasl-ir", "continuation", "challenge-401")
REQUIRED_SCOPE = "https://mail.google.com/"


class TranscriptFailure(Exception):
    pass


class OAuthIMAPHandler(socketserver.StreamRequestHandler):
    def send(self, value):
        self.wfile.write(value.encode("ascii") if isinstance(value, str) else value)
        self.wfile.flush()

    def read_line(self):
        line = self.rfile.readline(4097)
        if len(line) > 4096 or not line.endswith(b"\r\n"):
            raise TranscriptFailure("Expected one bounded CRLF line")
        return line

    def save_report(self):
        path = self.server.root / (self.server.case_name + "-transcript.json")
        temporary = path.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.report, indent=2) + "\n")
        temporary.replace(path)

    def validate_payload(self, encoded):
        self.report["singleLineBase64"] = not any(x in encoded for x in b" \t\r\n")
        try:
            decoded = base64.b64decode(encoded, validate=True)
        except (ValueError, base64.binascii.Error):
            raise TranscriptFailure("Invalid initial-response base64")
        self.report["decodedMatches"] = decoded == EXPECTED_PAYLOAD
        self.report["userMatches"] = decoded.startswith(
            f"user={FIXTURE_EMAIL}\x01".encode("ascii")
        )
        self.report["controlByteCount"] = decoded.count(b"\x01")
        self.report["delimiterBytes"] = list(decoded[-2:]) if decoded == EXPECTED_PAYLOAD else []
        self.report["credentialResponses"] += 1
        if not self.report["singleLineBase64"] or decoded != EXPECTED_PAYLOAD:
            raise TranscriptFailure("Expected exact fixed dummy user/Bearer/control-byte payload")

    def handle(self):
        case_name = self.server.case_name
        self.request.settimeout(10)
        self.report = {
            "caseName": case_name,
            "passed": False,
            "completed": False,
            "userMatches": False,
            "decodedMatches": False,
            "controlByteCount": 0,
            "delimiterBytes": [],
            "singleLineBase64": False,
            "responseLocation": "",
            "continuationRequested": False,
            "credentialResponses": 0,
        }
        self.save_report()
        auth_tag = "F00"
        try:
            self.send("* OK Fixed-credential XOAUTH2 fixture ready\r\n")
            capability_line = self.read_line()
            capability_tag, separator, command = capability_line[:-2].partition(b" ")
            if not separator or command.upper() != b"CAPABILITY":
                raise TranscriptFailure("Expected CAPABILITY before authentication")
            capabilities = "IMAP4rev1 AUTH=XOAUTH2"
            if case_name != "continuation":
                capabilities += " SASL-IR"
            self.send("* CAPABILITY " + capabilities + "\r\n")
            self.send(capability_tag + b" OK capability complete\r\n")

            authentication = self.read_line()[:-2]
            tag, separator, command = authentication.partition(b" ")
            if not separator:
                raise TranscriptFailure("Missing authentication command")
            auth_tag = tag.decode("ascii")
            mechanism = b"AUTHENTICATE XOAUTH2"
            if case_name == "continuation":
                if command.upper() != mechanism:
                    raise TranscriptFailure("Non-IR authentication must omit initial response")
                self.report["continuationRequested"] = True
                self.report["responseLocation"] = "continuation"
                self.send("+ \r\n")
                self.validate_payload(self.read_line()[:-2])
            else:
                if not command.upper().startswith(mechanism + b" "):
                    raise TranscriptFailure("SASL-IR authentication must include initial response")
                self.report["responseLocation"] = "initial"
                self.validate_payload(command[len(mechanism) + 1:])

            if case_name == "challenge-401":
                # This scope is a server requirement, never an OAuth granted scope.
                challenge = {"status": "401", "schemes": "bearer", "scope": REQUIRED_SCOPE}
                self.report["challengeStatus"] = "401"
                self.report["challengeRequirementScope"] = REQUIRED_SCOPE
                self.report["scopeSource"] = "serverRequirement"
                encoded = base64.b64encode(json.dumps(challenge).encode("ascii"))
                self.send(b"+ " + encoded + b"\r\n")
                response = self.read_line()
                self.report["emptyResponseBytes"] = list(response) if response == b"\r\n" else []
                if response != b"\r\n":
                    raise TranscriptFailure("Error challenge requires exactly empty CRLF response")
                self.report["completionStatus"] = "NO"
            else:
                self.report["completionStatus"] = "OK"

            self.report["passed"] = True
            self.report["completed"] = True
            self.save_report()
            if case_name == "challenge-401":
                self.send(auth_tag + " NO SASL authentication failed\r\n")
            else:
                self.send(auth_tag + " OK authenticated fixture\r\n")
        except (TranscriptFailure, OSError, UnicodeError) as failure:
            # Messages are static protocol diagnostics; incoming bytes are never echoed.
            self.report["failure"] = str(failure)
            self.report["completed"] = True
            self.save_report()
            try:
                self.send(auth_tag + " BAD fixture transcript mismatch\r\n")
            except OSError:
                pass


class OAuthIMAPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, root, case_name):
        self.root = root
        self.case_name = case_name
        super().__init__(("127.0.0.1", 0), OAuthIMAPHandler)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: oauth-imap-fixture.py FIXTURE_DIRECTORY")
    root = pathlib.Path(sys.argv[1]).resolve()
    root.mkdir(parents=True, exist_ok=True)
    servers = [OAuthIMAPServer(root, case_name) for case_name in CASES]
    stop = threading.Event()
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, lambda *_: stop.set())
    try:
        for server in servers:
            threading.Thread(target=server.serve_forever, daemon=True).start()
        ports = {server.case_name: server.server_address[1] for server in servers}
        temporary = root / "ports.tmp"
        temporary.write_text(json.dumps(ports) + "\n")
        temporary.replace(root / "ports.json")
        print("ready: loopback XOAUTH2 dummy-token fixtures", flush=True)
        stop.wait()
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
