#!/usr/bin/env python3
"""生成一个合成的 Wallpaper Engine 风格 PKG 文件，用于验证 RePKG 的读取与 TEX->PNG 转换链路。

PKG 结构（与 RePKG PackageReader 一致）:
    i32 magicLen + magicBytes("PKGV0005")
    i32 entryCount
    entryCount * (i32 pathLen + pathBytes + i32 offset + i32 length)
    body（各 entry 的原始字节按 offset 顺序拼接）

TEX 结构（TEXV0005 / TEXI0001 / TEXB0002，未压缩 RGBA8888）:
    "TEXV0005\\0" "TEXI0001\\0"
    i32 format=0(RGBA8888), i32 flags=0, i32 texW, i32 texH, i32 imgW, i32 imgH, u32 unk
    "TEXB0002\\0" i32 imageCount
    imageCount * (i32 mipmapCount, mipmapCount * (i32 w, i32 h, i32 isLz4, i32 rawLen, i32 byteLen, bytes))
"""
import struct
import sys
from pathlib import Path


def nstring(s: str) -> bytes:
    return s.encode("utf-8") + b"\x00"


def build_tex(width: int, height: int) -> bytes:
    # 生成一张可辨认的测试图：四象限不同颜色 + 左上角纯红标记
    pixels = bytearray()
    for y in range(height):
        for x in range(width):
            if x < width // 2 and y < height // 2:
                r, g, b, a = 255, 0, 0, 255        # 左上 红
            elif x >= width // 2 and y < height // 2:
                r, g, b, a = 0, 255, 0, 255        # 右上 绿
            elif x < width // 2:
                r, g, b, a = 0, 0, 255, 255        # 左下 蓝
            else:
                r, g, b, a = 255, 255, 0, 255      # 右下 黄
            pixels += bytes((r, g, b, a))

    out = bytearray()
    out += nstring("TEXV0005")
    out += nstring("TEXI0001")
    out += struct.pack("<iiiiiiI", 0, 0, width, height, width, height, 0)  # format=RGBA8888
    out += nstring("TEXB0002")
    out += struct.pack("<i", 1)                                          # imageCount
    out += struct.pack("<i", 1)                                          # mipmapCount
    out += struct.pack("<iiii", width, height, 0, len(pixels))           # w,h,isLz4,rawLen
    out += struct.pack("<i", len(pixels)) + bytes(pixels)                # byteLen + data
    return bytes(out)


def build_tex_dxt5(width: int, height: int, rgb565: int) -> bytes:
    """构造一张纯色 DXT5 纹理，用于验证 DXT 解压路径。"""
    # DXT5 块: alpha(a0,a1,6字节索引) + color(c0,c1,4字节索引)
    alpha_block = bytes([255, 255, 0, 0, 0, 0, 0, 0])
    color_block = struct.pack("<HH", rgb565, rgb565) + bytes([0, 0, 0, 0])
    blocks = (width // 4) * (height // 4)
    pixels = (alpha_block + color_block) * blocks

    out = bytearray()
    out += nstring("TEXV0005")
    out += nstring("TEXI0001")
    out += struct.pack("<iiiiiiI", 4, 0, width, height, width, height, 0)  # format=4 -> DXT5
    out += nstring("TEXB0002")
    out += struct.pack("<i", 1)
    out += struct.pack("<i", 1)
    out += struct.pack("<iiii", width, height, 0, len(pixels))
    out += struct.pack("<i", len(pixels)) + pixels
    return bytes(out)


def build_pkg(entries) -> bytes:
    header = bytearray()
    body = bytearray()
    magic = "PKGV0005"
    header += struct.pack("<i", len(magic)) + magic.encode("utf-8")
    header += struct.pack("<i", len(entries))

    offset = 0
    for path, data in entries:
        header += struct.pack("<i", len(path)) + path.encode("utf-8")
        header += struct.pack("<ii", offset, len(data))
        body += data
        offset += len(data)

    return bytes(header) + bytes(body)


def main() -> int:
    out_dir = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    out_dir.mkdir(parents=True, exist_ok=True)

    tex = build_tex(64, 64)
    tex_dxt5 = build_tex_dxt5(16, 16, 0xF800)  # 纯红
    entries = [
        ("scene.json", b'{"camera":{"center":[0,0],"eye":[0,0,1],"up":[0,1,0]},"general":{"orthogonalprojection":true}}'),
        ("materials/test_quad.tex", tex),
        ("materials/test_dxt5.tex", tex_dxt5),
        ("readme.txt", b"RePKG synthetic test package\n"),
    ]

    pkg_path = out_dir / "test_scene.pkg"
    pkg_path.write_bytes(build_pkg(entries))
    print(f"wrote {pkg_path} ({pkg_path.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
