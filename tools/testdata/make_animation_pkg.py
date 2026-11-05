#!/usr/bin/env python3
"""Make non-personal raw and PNG-backed two-frame TEX animations."""
import importlib.util
from pathlib import Path
import struct
import sys
import zlib

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("pkg", Path(__file__).with_name("make_test_pkg.py"))
pkg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pkg)
root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
width, height = 16, 8
row = bytes((255, 0, 0, 255)) * 8 + bytes((0, 255, 0, 255)) * 8
raw = row * height
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress((b"\0" + row) * height)) + chunk(b"IEND", b""))
def tex(data, encoded):
    out = bytearray(pkg.nstring("TEXV0005") + pkg.nstring("TEXI0001"))
    out += struct.pack("<iiiiiiI", 0, 4, width, height, width, height, 0)
    out += pkg.nstring("TEXB0003" if encoded else "TEXB0002")
    out += struct.pack("<i", 1)
    if encoded: out += struct.pack("<i", 13)  # FreeImage PNG
    out += struct.pack("<i", 1)
    out += struct.pack("<iiiii", width, height, 0, len(data), len(data)) + data
    out += pkg.nstring("TEXS0003") + struct.pack("<iii", 2, 8, 8)
    for x, duration in [(0, 0.1), (8, 0.2)]:
        out += struct.pack("<i7f", 0, duration, x, 0, 8, 0, 0, 8)
    return bytes(out)
entries = [("materials/encoded.tex", tex(png, True)), ("materials/raw.tex", tex(raw, False))]
(root / "scene.pkg").write_bytes(pkg.build_pkg(entries))
oversized = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 10000, height, 8, 6, 0, 0, 0))
             + chunk(b"IDAT", zlib.compress((b"\0" + row) * height)) + chunk(b"IEND", b""))
invalid = bytearray(tex(oversized, True))
offset = invalid.find(oversized)
assert offset >= 20
struct.pack_into("<i", invalid, offset - 20, 10000)
(root / "oversized.pkg").write_bytes(pkg.build_pkg([("materials/oversized.tex", bytes(invalid))]))
print(root / "scene.pkg")
