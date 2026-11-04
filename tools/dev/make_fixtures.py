#!/usr/bin/env python3
"""Only creates synthetic assets in the supplied development directory."""
import importlib.util
import json
from pathlib import Path
import struct
import sys
import zlib

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location('fixture_pkg', Path(__file__).parents[1] / 'testdata/make_test_pkg.py')
pkg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pkg)
root = Path(sys.argv[1]).resolve()
for i in range(12):
    folder = root / 'Library' / str(800000 + i)
    folder.mkdir(parents=True, exist_ok=True)
    width, height = 640, 360
    raw = b''.join(b'\0' + bytes(c for x in range(width) for c in ((x+i*19)%256, (y+i*31)%256, (100+i*11)%256)) for y in range(height))
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind+data)&0xffffffff)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,2,0,0,0)) + chunk(b'IDAT',zlib.compress(raw)) + chunk(b'IEND',b'')
    (folder/'preview.png').write_bytes(png)
    (folder/'project.json').write_text(json.dumps({'title': f'示例场景 {i+1:02}', 'type':'scene','preview':'preview.png'},ensure_ascii=False))
    entries = [('scene.json', b'{"objects":[]}'), ('materials/placeholder.tex',pkg.build_tex(64,64))]
    if i%4 == 1: entries += [('models/example_puppet.mdl', b'unsupported synthetic model')]
    if i%4 == 2: entries += [('effects/example/effect.json', b'{}'), ('particles/example.json', b'{}')]
    if i%4 == 3: entries += [('materials/second.tex',pkg.build_tex(32,32))]
    (folder/'scene.pkg').write_bytes(pkg.build_pkg(entries))
for directory in ('Images','Extracted','Logs','History','Cache'):
    (root/directory).mkdir(parents=True, exist_ok=True)
print(f'Created 12 synthetic scenes in {root}')
