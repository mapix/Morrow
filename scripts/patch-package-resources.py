#!/usr/bin/env python3
"""Locate pinned Hub resources in an app's Resources directory or CLI bundle.

SwiftPM's command-line generated Bundle.module accessor embeds the developer's
absolute build directory. Its main-bundle candidate also points outside a macOS
app's Contents/Resources. This replaces the single pinned fallback-tokenizer
resource lookup with a relocatable lookup, without altering tokenizer data.
"""
import json
from pathlib import Path
import stat
import subprocess

root = Path(__file__).resolve().parent.parent
checkout = root / '.build/checkouts/swift-transformers'
resolved = json.loads((root / 'Package.resolved').read_text())
pin = next(p for p in resolved['pins'] if p['identity'] == 'swift-transformers')
revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=checkout, text=True).strip()
if revision != pin['state']['revision']:
    raise SystemExit('Hub resource patch refuses an unpinned dependency revision.')
path = checkout / 'Sources/Hub/Hub.swift'
original = 'guard let url = Bundle.module.url(forResource: fallbackTokenizerConfigBaseName, withExtension: "json") else {'
replacement = '''let resourceRoot = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        guard let resourceBundle = Bundle(url: resourceRoot.appendingPathComponent("swift-transformers_Hub.bundle")),
              let url = resourceBundle.url(forResource: fallbackTokenizerConfigBaseName, withExtension: "json") else {'''
source = path.read_text()
if replacement in source and original not in source:
    print('Hub resource lookup already relocatable.')
elif source.count(original) == 1:
    mode = stat.S_IMODE(path.stat().st_mode)
    try:
        path.chmod(mode | stat.S_IWUSR)
        path.write_text(source.replace(original, replacement))
    finally:
        path.chmod(mode)
    print('Patched pinned Hub resource lookup for packaged applications.')
else:
    raise SystemExit('Hub resource source changed; review the dependency before packaging.')
