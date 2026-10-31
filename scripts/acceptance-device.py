#!/usr/bin/env python3
"""Launch/collect one explicit synthetic acceptance phase on a paired physical iOS device.

Without --launch this is read-only and copies only the named acceptance proof file.
The launch option is for the deployment coordinator after the acceptance build is installed.
"""

import argparse
import datetime as dt
import json
import pathlib
import re
import subprocess
import sys
import time
import uuid

MODES = ("gemma", "cloud-publish", "cloud-receive", "cloud-update", "cloud-verify-update", "cloud-delete", "cloud-verify-delete")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="8C094C4B-A46C-5B90-BD14-E334AC67EB80")
    parser.add_argument("--bundle", default="app.smail.mobile")
    parser.add_argument("--id", required=True, type=uuid.UUID)
    parser.add_argument("--mode", choices=MODES, required=True)
    parser.add_argument("--peer-binding")
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--launch", action="store_true", help="Coordinator-only: replace the installed app process with this opt-in acceptance phase.")
    parser.add_argument("--timeout", type=int, default=360, help="Overall proof collection window, seconds (1–900).")
    parser.add_argument("--print-command", action="store_true", help="Print the launch and scoped copy commands without contacting the device.")
    args = parser.parse_args()
    test_id = str(args.id)
    if not 1 <= args.timeout <= 900:
        parser.error("--timeout must be 1–900 seconds")
    if args.peer_binding and not re.fullmatch(r"[0-9a-fA-F]{64}", args.peer_binding):
        parser.error("--peer-binding must be a 64-digit SHA-256 hash")
    if args.mode not in ("gemma", "cloud-publish") and not args.peer_binding:
        parser.error("This cloud phase requires --peer-binding from the publishing proof")
    args.output.mkdir(parents=True, exist_ok=True)
    proof_path = args.output / ("proof-" + args.mode + ".json")
    scoped_source = "Documents/acceptance-" + test_id + "/proof-" + args.mode + ".json"
    launch = ["xcrun", "devicectl", "device", "process", "launch", "--device", args.device, "--terminate-existing", "--timeout", "45", "--json-output", str(args.output / ("launch-" + args.mode + ".json")), args.bundle, "--acceptance-mode", args.mode, "--acceptance-id", test_id]
    if args.peer_binding:
        launch.extend(["--acceptance-peer-binding", args.peer_binding.lower()])
    copy = ["xcrun", "devicectl", "device", "copy", "from", "--device", args.device, "--source", scoped_source, "--destination", str(proof_path), "--domain-type", "appDataContainer", "--domain-identifier", args.bundle, "--timeout", "15", "--json-output", str(args.output / ("copy-" + args.mode + ".json"))]
    if args.print_command:
        print(json.dumps({"launch": launch, "copy": copy}, indent=2))
        return 0
    launched_at = dt.datetime.now(dt.timezone.utc) if args.launch else None
    if args.launch:
        result = subprocess.run(launch, capture_output=True, text=True, timeout=50)
        (args.output / ("launch-" + args.mode + ".log")).write_text(result.stdout + result.stderr)
        if result.returncode:
            print("Acceptance app launch failed; see coordinator launch JSON/log.", file=sys.stderr)
            return result.returncode
    deadline = time.monotonic() + args.timeout
    last_error = "proof not yet available"
    while time.monotonic() < deadline:
        try:
            copied = subprocess.run(copy, capture_output=True, text=True, timeout=min(20, max(1, deadline - time.monotonic())))
            if copied.returncode == 0:
                proof = json.loads(proof_path.read_text())
                if proof.get("acceptanceID") != test_id or proof.get("mode") != args.mode:
                    raise ValueError("Proof identity/mode does not match the requested phase")
                if launched_at:
                    started = dt.datetime.fromisoformat(proof["startedAt"].replace("Z", "+00:00"))
                    if started < launched_at - dt.timedelta(seconds=5):
                        last_error = "waiting for a fresh proof from this process launch"
                        time.sleep(min(3, max(0, deadline - time.monotonic())))
                        continue
                if proof.get("finished"):
                    print(json.dumps(proof, indent=2, ensure_ascii=False))
                    return 0 if proof.get("passed") is True else 1
                last_error = "app phase: " + str(proof.get("phase", "running"))
            else:
                last_error = "proof copy pending (see copy JSON)"
        except (subprocess.TimeoutExpired, OSError, ValueError, KeyError) as error:
            last_error = str(error)
        time.sleep(min(3, max(0, deadline - time.monotonic())))
    result = {"acceptanceID": test_id, "mode": args.mode, "finished": False, "passed": False, "collectorTimedOut": True, "error": "Acceptance proof was not completed within " + str(args.timeout) + " seconds", "lastState": last_error}
    (args.output / ("collector-timeout-" + args.mode + ".json")).write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2), file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
