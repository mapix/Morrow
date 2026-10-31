#!/usr/bin/env python3
"""Compile MLX's vendored Metal kernels through the installed real toolchain.
Xcode's stub metal executable does not discover an on-demand cryptex on this host.
"""
import pathlib, subprocess, concurrent.futures, os
root=pathlib.Path(__file__).resolve().parent.parent
source=root/'.build/checkouts/mlx-swift/Source/Cmlx/mlx'
kernel=source/'mlx/backend/metal/kernels'
output=root/'.build/morrow-metal'; output.mkdir(parents=True,exist_ok=True)
files=list(kernel.rglob('*.metal'))
def build(path):
    air=output/('metal4-'+path.stem+'.air')
    command=['xcrun','-sdk','macosx','metal','-x','metal','-std=metal4.0','-mmacosx-version-min=26.0','-fno-fast-math','-Wno-c++17-extensions','-Wno-c++20-extensions','-I',str(source),'-I',str(kernel),'-c',str(path),'-o',str(air)]
    result=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    if result.returncode: raise RuntimeError(path.name+'\n'+result.stdout[-3000:])
    print('Compiled',path.name,flush=True)
    return air
with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
    outputs=list(pool.map(build,files))
subprocess.run(['xcrun','-sdk','macosx','metallib',*[str(x) for x in outputs],'-o',str(output/'mlx.metallib')],check=True)
print('Ready',output/'mlx.metallib',flush=True)
