#!/usr/bin/env python3
"""Keep macOS SRT library resources; no executable CLI wrappers or other OS tools."""
from pathlib import Path
import argparse, shutil
p=argparse.ArgumentParser();p.add_argument('runtime',type=Path);args=p.parse_args()
root=args.runtime.resolve();sdk=root/'node_modules/@anthropic-ai/sandbox-runtime'
if not (root/'bridge.mjs').is_file() or not (sdk/'package.json').is_file():raise SystemExit('Not a prepared responder runtime')
for path in (sdk/'vendor/seccomp',sdk/'vendor/srt-win',root/'node_modules/.bin'):
    if path.is_dir():shutil.rmtree(path)
changed=0
for path in root.rglob('*'):
    if not path.is_file() or path.is_symlink():continue
    if path.suffix in {'.js','.mjs','.ts'}:
        data=path.read_bytes()
        if data.startswith(b'#!'):
            path.write_bytes(data.split(b'\n',1)[1] if b'\n' in data else b'');changed+=1
        path.chmod(0o644)
print('macOS sandbox library prepared; CLI interpreter headers removed:',changed)
