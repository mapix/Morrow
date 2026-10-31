#!/usr/bin/env python3
"""Download a pinned public checkpoint with certificate validation and SHA256 verification.
Uses public DNS results only for this download, without changing system DNS.
"""
import json, subprocess, pathlib, hashlib, sys
destination = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path.home() / 'Library/Application Support/Morrow/models/embeddinggemma-2')
destination.mkdir(parents=True, exist_ok=True)
repo = 'mlx-community/embeddinggemma-2-bf16'
revision = '1a4ffddb7905d3f63486748deabe091a01fb6201'
hosts = ['huggingface.co', 'cdn-lfs.huggingface.co', 'cdn-lfs-us-1.hf.co', 'cas-bridge.xethub.hf.co']
resolve = []
for host in hosts:
    try:
        raw = subprocess.check_output(['/usr/bin/curl', '-fsS', '--max-time', '20', f'https://dns.google/resolve?name={host}&type=A'])
        answers = json.loads(raw).get('Answer', [])
        ip = next(x['data'] for x in answers if x['type'] == 1)
        resolve += ['--resolve', f'{host}:443:{ip}']
    except Exception:
        pass
meta = json.loads(subprocess.check_output(['/usr/bin/curl', '-fsSL', *resolve, '--max-time', '30', f'https://huggingface.co/api/models/{repo}/revision/{revision}?blobs=true']))
selected = ['config.json', 'tokenizer.json', 'tokenizer_config.json', 'model.safetensors', 'model.safetensors.index.json', 'modules.json', '1_Pooling/config.json', '2_Normalize/config.json', 'sentence_bert_config.json']
verified = []
for f in meta['siblings']:
    name = f['rfilename']
    if name not in selected: continue
    path = destination / name
    path.parent.mkdir(parents=True, exist_ok=True)
    expected_size = f.get('size')
    expected_hash = f.get('lfs', {}).get('sha256')
    def valid():
        if not path.exists() or path.stat().st_size != expected_size: return False
        if expected_hash:
            digest = hashlib.sha256()
            with path.open('rb') as stream:
                for chunk in iter(lambda: stream.read(8*1024*1024), b''): digest.update(chunk)
            return digest.hexdigest() == expected_hash
        return True
    if not valid():
        print('Downloading', name, expected_size, flush=True)
        temporary = path.with_name(path.name + '.download')
        subprocess.run(['/usr/bin/curl', '-fSL', *resolve, '--retry', '3', '--connect-timeout', '25', '--max-time', '1800', '-o', str(temporary), f'https://huggingface.co/{repo}/resolve/{revision}/{name}?download=true'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        temporary.replace(path)
        if not valid():
            path.unlink(missing_ok=True)
            raise RuntimeError('Checkpoint verification failed: ' + name)
    verified.append({'file': name, 'size': expected_size, 'sha256': expected_hash})
    print('Verified', name, flush=True)
(destination / 'smail-manifest.json').write_text(json.dumps({'repo': repo, 'revision': revision, 'files': verified}, indent=2))
print('Ready:', destination, flush=True)
