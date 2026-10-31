#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift package resolve
python3 scripts/patch-mlx-nax.py
mkdir -p evidence/private/protocol
rm -f evidence/private/protocol/ports.json
python3 scripts/mail-fixture.py evidence/private/protocol > evidence/private/protocol/server.log 2>&1 &
fixture_pid=$!
trap 'kill "$fixture_pid" 2>/dev/null || true' EXIT
for attempt in {1..30}; do
  if [[ -f evidence/private/protocol/ports.json ]]; then break; fi
  sleep 0.1
done
export MORROW_TEST_IMAP_PORT=$(python3 -c 'import json; print(json.load(open("evidence/private/protocol/ports.json"))["imap"])')
export MORROW_TEST_SMTP_PORT=$(python3 -c 'import json; print(json.load(open("evidence/private/protocol/ports.json"))["smtp"])')
export MORROW_TEST_POP_PORT=$(python3 -c 'import json; print(json.load(open("evidence/private/protocol/ports.json"))["pop"])')
swift test
python3 - <<'PY'
import json, pathlib
root=pathlib.Path('evidence/private/protocol')
mail=(root/'smtp.eml').read_bytes()
recipients=json.loads((root/'smtp-envelope.json').read_text())
assert any('hidden@example.com' in x for x in recipients)
assert b'hidden@example.com' not in mail and b'Bcc:' not in mail
print('SMTP envelope and Bcc privacy verified')
PY
