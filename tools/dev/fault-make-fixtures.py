#!/usr/bin/env python3
"""Fault-injection fixtures for queue cancel / force-quit / engine-failure tests.

Creates ONLY synthetic, neutral content inside the supplied isolated root.
Never touches the real library or the repository test-data generators.

Usage: python3 tools/dev/fault-make-fixtures.py <isolated-root> [--force]

Layout produced under <isolated-root>:
  Library/900001/  "01 正常小包"    small valid scene.pkg (success baseline)
  Library/900002/  "02 慢速大包"    large valid scene.pkg (slow extract, for cancel/SIGKILL)
  Library/900003/  "03 损坏包"      corrupt scene.pkg (engine failure path)
  Library/900004/  "04 后续正常"    second small valid scene.pkg (queue continues after failure)
"""
import importlib.util
import json
import struct
import sys
import zlib
from pathlib import Path

sys.dont_write_bytecode = True

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('fixture_pkg', REPO / 'tools/testdata/make_test_pkg.py')
pkg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pkg)


def png_chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)


def make_preview(width: int, height: int, seed: int) -> bytes:
    rows = []
    for y in range(height):
        row = bytearray(b'\x00')
        for x in range(width):
            row += bytes(((x + seed * 19) % 256, (y + seed * 31) % 256, (100 + seed * 11) % 256))
        rows.append(bytes(row))
    raw = b''.join(rows)
    return (b'\x89PNG\r\n\x1a\n'
            + png_chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + png_chunk(b'IDAT', zlib.compress(raw))
            + png_chunk(b'IEND', b''))


def big_tex(width: int, height: int, seed: int) -> bytes:
    """RGBA8888 texture with a deterministic, low-compressibility pattern.

    Same on-disk format as make_test_pkg.build_tex, but built row-wise so a
    2048x2048 texture is cheap to generate and expensive for repkg to PNG-encode.
    """
    row = bytearray()
    for x in range(width):
        row += bytes(((x * 7 + seed) % 256, (x * 13 + seed * 3) % 256, (x * 29 + seed * 5) % 256, 255))
    pixels = bytes(row) * height
    out = bytearray()
    out += pkg.nstring('TEXV0005')
    out += pkg.nstring('TEXI0001')
    out += struct.pack('<iiiiiiI', 0, 0, width, height, width, height, 0)  # RGBA8888
    out += pkg.nstring('TEXB0002')
    out += struct.pack('<i', 1)
    out += struct.pack('<i', 1)
    out += struct.pack('<iiii', width, height, 0, len(pixels))
    out += struct.pack('<i', len(pixels)) + pixels
    return bytes(out)


def write_scene(root: Path, folder_id: str, title: str, pkg_bytes: bytes,
                preview_seed: int) -> None:
    folder = root / 'Library' / folder_id
    folder.mkdir(parents=True, exist_ok=True)
    (folder / 'project.json').write_text(
        json.dumps({'title': title, 'type': 'scene', 'preview': 'preview.png'}, ensure_ascii=False))
    (folder / 'preview.png').write_bytes(make_preview(320, 180, preview_seed))
    (folder / 'scene.pkg').write_bytes(pkg_bytes)


def small_pkg(seed: int) -> bytes:
    entries = [
        ('scene.json', b'{"camera":{"center":[0,0],"eye":[0,0,1]},"general":{"orthogonalprojection":true}}'),
        ('materials/quad.tex', pkg.build_tex(128, 128)),
        ('materials/extra.tex', pkg.build_tex(64, 64)),
        (f'scripts/entry_{seed}.json', b'{"synthetic":true}'),
    ]
    return pkg.build_pkg(entries)


def slow_pkg(seed: int) -> bytes:
    """Deliberately slow but fully valid package (~7 s on this machine).

    repkg spends most of its time on per-entry filesystem work, so 40k tiny
    entries give a reliable multi-second window for cancel / SIGKILL tests
    without hundreds of MB of payload.
    """
    entries = [('scene.json', b'{"camera":{"center":[0,0],"eye":[0,0,1]},"general":{"orthogonalprojection":true}}')]
    # 4 x 2048^2 RGBA textures -> CPU-heavy PNG encoding in repkg
    for i in range(4):
        entries.append((f'materials/big_{i}.tex', big_tex(2048, 2048, seed + i)))
    # bulk copy payload -> I/O time under `-c`
    blob = bytes(range(256)) * 4096  # 1 MiB, deterministic
    for i in range(40):
        entries.append((f'data/blob_{i:03}.bin', blob))
    # many small entries -> dominated by open/write/close syscalls
    tiny = bytes(range(256)) * 8  # 2 KiB
    for i in range(40000):
        entries.append((f'bulk/d{i // 500:03}/f{i:05}.json', tiny))
    return pkg.build_pkg(entries)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    root = Path(sys.argv[1]).resolve()
    force = '--force' in sys.argv[2:]
    for name in ('Library', 'Extracted', 'Images', 'Logs', 'History', 'Cache'):
        (root / name).mkdir(parents=True, exist_ok=True)

    targets = [
        ('900001', '01 正常小包', small_pkg(1), 1),
        ('900002', '02 慢速大包', slow_pkg(2), 2),
    ]
    for folder_id, title, data, seed in targets:
        folder = root / 'Library' / folder_id
        if folder.exists() and not force:
            print(f'skip existing {folder}')
            continue
        write_scene(root, folder_id, title, data, seed)
        print(f'wrote {folder} ({len(data) / 1e6:.1f} MB)')

    # corrupt package: valid folder shape, garbage scene.pkg payload
    folder = root / 'Library' / '900003'
    if force or not folder.exists():
        (folder).mkdir(parents=True, exist_ok=True)
        (folder / 'project.json').write_text(
            json.dumps({'title': '03 损坏包', 'type': 'scene', 'preview': 'preview.png'}, ensure_ascii=False))
        (folder / 'preview.png').write_bytes(make_preview(320, 180, 3))
        (folder / 'scene.pkg').write_bytes(b'NOT-A-REAL-PKG\x00' + bytes(range(256)) * 64)
        print(f'wrote {folder} (corrupt)')

    folder = root / 'Library' / '900004'
    if force or not folder.exists():
        write_scene(root, '900004', '04 后续正常', small_pkg(4), 4)
        print(f'wrote {folder} ({len(small_pkg(4)) / 1e6:.1f} MB)')

    print(f'fixtures ready in {root}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
