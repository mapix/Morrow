#!/usr/bin/env python3
"""Prepare pure JavaScript SDK resources; leave all private application data alone."""
from pathlib import Path
import argparse, shutil

parser = argparse.ArgumentParser()
parser.add_argument('runtime', type=Path)
root = parser.parse_args().runtime.resolve()
if not (root / 'bridge.mjs').is_file() or not (root / 'node_modules/@openai/agents/package.json').is_file():
    raise SystemExit('Not a prepared OpenAI Agents runtime')
bins = root / 'node_modules/.bin'
if bins.is_dir(): shutil.rmtree(bins)
for path in root.rglob('*'):
    if not path.is_file() or path.is_symlink(): continue
    if path.name.endswith(('.map', '.d.ts', '.d.cts', '.d.mts')):
        path.unlink(); continue
    data = path.read_bytes()
    if data.startswith(b'#!') and path.suffix not in {'.js', '.mjs', '.cjs', '.ts'}:
        path.unlink(); continue
    if path.suffix in {'.js', '.mjs', '.cjs', '.ts'}:
        if data.startswith(b'#!'): path.write_bytes(data.split(b'\n', 1)[1])
        path.chmod(0o644)
print('OpenAI Agents JavaScript runtime prepared')
