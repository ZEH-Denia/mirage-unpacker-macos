#!/usr/bin/env python3
"""生成「可重复基线」用的确定性合成 scene.pkg。

这个生成器只依赖 Python 标准库，输出必须逐字节可复现（用于替代已丢失的
`extracted/3608924541` 真实基线）。所有像素/结构期望都能由本文件的常量
直接推导，不依赖 RePKG 的实际输出。

PKG 结构（与 RePKG PackageReader 一致）:
    i32 magicLen + magicBytes("PKGV0005")
    i32 entryCount
    entryCount * (i32 pathLen + pathBytes + i32 offset + i32 length)
    body（各 entry 原始字节按 offset 顺序拼接）

TEX 结构（TEXV0005 / TEXI0001 / TEXB0002）:
    "TEXV0005\\0" "TEXI0001\\0"
    i32 format, i32 flags, i32 texW, i32 texH, i32 imgW, i32 imgH, u32 unk
    "TEXB0002\\0" i32 imageCount
    imageCount * (i32 mipmapCount, mipmapCount * (i32 w, i32 h, i32 isLz4,
               i32 rawLen, i32 byteLen, bytes))

用法:
    python3 tools/testdata/make_baseline_pkg.py <out_dir>

会在 <out_dir> 写出:
    scene.pkg     合成包（被基线脚本解包的对象）
    project.json  放在 scene.pkg 旁边，供 `repkg extract -c` 复制

确定性约定:
- 不使用 float / 随机数 / 时间戳；JSON 用固定 key 顺序 + 固定分隔符。
- PNG 用 zlib level=0（stored 块），避免不同 zlib 实现产生不同压缩字节。
"""
import json
import struct
import sys
import zlib
from pathlib import Path

# ---- 已知输入（期望值全部由此推导）------------------------------------------

QUAD_W, QUAD_H = 8, 8
QUAD_COLORS = {  # 四象限纯色（RGBA8888，alpha 全不透明）
    "tl": (255, 0, 0, 255),
    "tr": (0, 255, 0, 255),
    "bl": (0, 0, 255, 255),
    "br": (255, 255, 0, 255),
}

PUPPET_W, PUPPET_H = 8, 8
PUPPET_LEFT = (255, 128, 0, 255)    # 左半：橙色，不透明
PUPPET_RIGHT = (0, 128, 255, 128)   # 右半：蓝色，半透明（验证 alpha 直通）

DXT5_W, DXT5_H = 4, 4
DXT5_RGB565 = 0xF800                # RGB565 纯红：R=31,G=0,B=0 -> (255,0,0)

OVERLAY_W, OVERLAY_H = 4, 4
OVERLAY_COLOR = (255, 255, 255, 255)  # 直接以 PNG 入库，应为原样直通

PROJECT = {
    "title": "Mirage Synthetic Baseline",
    "type": "scene",
    "workshopid": "1000000001",
    "description": "Repository-reproducible synthetic baseline fixture",
}


def quad_color(x: int, y: int):
    """8x8 四象限：左上红 / 右上绿 / 左下蓝 / 右下黄。"""
    if x < QUAD_W // 2 and y < QUAD_H // 2:
        return QUAD_COLORS["tl"]
    if x >= QUAD_W // 2 and y < QUAD_H // 2:
        return QUAD_COLORS["tr"]
    if x < QUAD_W // 2:
        return QUAD_COLORS["bl"]
    return QUAD_COLORS["br"]


def puppet_color(x: int, y: int):
    """8x8 左右两半：左橙色不透明 / 右蓝色半透明。"""
    return PUPPET_LEFT if x < PUPPET_W // 2 else PUPPET_RIGHT


def nstring(s: str) -> bytes:
    return s.encode("utf-8") + b"\x00"


def _tex_header(format_id: int, width: int, height: int) -> bytes:
    out = bytearray()
    out += nstring("TEXV0005")
    out += nstring("TEXI0001")
    out += struct.pack("<iiiiiiI", format_id, 0, width, height, width, height, 0)
    return bytes(out)


def build_tex_rgba(width: int, height: int, color_at) -> bytes:
    """构造未压缩 RGBA8888 纹理；color_at(x, y) -> (r, g, b, a)。"""
    pixels = bytearray()
    for y in range(height):
        for x in range(width):
            pixels += bytes(color_at(x, y))
    out = bytearray(_tex_header(0, width, height))  # format 0 = RGBA8888
    out += nstring("TEXB0002")
    out += struct.pack("<i", 1)                                   # imageCount
    out += struct.pack("<i", 1)                                   # mipmapCount
    out += struct.pack("<iiii", width, height, 0, len(pixels))    # w,h,isLz4,rawLen
    out += struct.pack("<i", len(pixels)) + bytes(pixels)         # byteLen + data
    return bytes(out)


def build_tex_dxt5_solid(width: int, height: int, rgb565: int) -> bytes:
    """构造纯色 DXT5 纹理（4 的倍数尺寸）。alpha 端点 255，颜色端点相同。"""
    assert width % 4 == 0 and height % 4 == 0
    alpha_block = bytes([255, 255, 0, 0, 0, 0, 0, 0])
    color_block = struct.pack("<HH", rgb565, rgb565) + bytes([0, 0, 0, 0])
    pixels = (alpha_block + color_block) * ((width // 4) * (height // 4))
    out = bytearray(_tex_header(4, width, height))  # format 4 = DXT5
    out += nstring("TEXB0002")
    out += struct.pack("<i", 1)
    out += struct.pack("<i", 1)
    out += struct.pack("<iiii", width, height, 0, len(pixels))
    out += struct.pack("<i", len(pixels)) + pixels
    return bytes(out)


def _png_chunk(tag: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


def build_png_rgba(width: int, height: int, color_at) -> bytes:
    """确定性 PNG：8-bit RGBA，zlib stored 块（level=0）。"""
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type 0
        for x in range(width):
            raw += bytes(color_at(x, y))
    compressor = zlib.compressobj(level=0)  # stored 块，跨 zlib 实现一致
    idat = compressor.compress(bytes(raw)) + compressor.flush()
    return (
        b"\x89PNG\r\n\x1a\n"
        + _png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + _png_chunk(b"IDAT", idat)
        + _png_chunk(b"IEND", b"")
    )


def build_mdl(material_path: str, width: int, height: int) -> bytes:
    """MDLV0023 网格：4 顶点（80 字节/顶点，uv 在 offset 72）+ 2 三角形。"""
    vertices = []
    for x, y, u, v in [
        (-width / 2, -height / 2, 0, 1),
        (width / 2, -height / 2, 1, 1),
        (width / 2, height / 2, 1, 0),
        (-width / 2, height / 2, 0, 0),
    ]:
        row = bytearray(80)
        struct.pack_into("<3f", row, 0, x, y, 0)
        struct.pack_into("<2f", row, 72, u, v)
        vertices.append(row)
    body = b"".join(vertices)
    indices = struct.pack("<6H", 0, 1, 2, 0, 2, 3)
    return (
        b"MDLV0023"
        + bytes(13)
        + material_path.encode("utf-8")
        + b"\x00"
        + bytes(28)
        + struct.pack("<II", 0x0180000F, len(body))
        + body
        + struct.pack("<I", len(indices))
        + indices
    )


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


def _json_bytes(value) -> bytes:
    return json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":")).encode("utf-8")


# ---- 期望值（供基线检查脚本直接 import 推导，非记录 RePKG 输出）--------------

def build_entries():
    """返回 scene.pkg 中的 (path, bytes) 列表（顺序固定）。"""
    scene = {
        "camera": {"center": "0 0", "eye": "0 0 1", "up": "0 1 0"},
        "general": {
            "orthogonalprojection": {"width": 100, "height": 80},
            "clearcolor": "0 0 0",
        },
        "objects": [
            {
                "image": "models/quad.json",
                "origin": "50 40 0",
                "size": "100 80",
                "angles": "0 0 0",
                "alpha": 1,
            },
            {
                "image": "models/puppet.json",
                "origin": "30 40 0",
                "size": "20 40",
                "angles": "0 0 1.5707963",
                "alpha": 0.5,
                "visible": {"user": "toggle", "value": True},
            },
        ],
    }
    quad_material = {
        "passes": [
            {"shader": "genericimage4", "blending": "translucent", "textures": ["quad"]}
        ]
    }
    puppet_material = {
        "passes": [
            {"shader": "genericimage4", "blending": "translucent", "textures": ["puppet"]}
        ]
    }
    xray_material = {
        "passes": [
            {
                "shader": "genericimage4",
                "blending": "translucent",
                "textures": ["quad", "dxt5"],
                "constantshadervalues": {"xray": {"enabled": True, "amount": 0.5}},
            }
        ]
    }
    effect = {
        "name": "xray",
        "passes": [
            {"shader": "xray", "textures": ["normal", "albedo"], "target": "xray"}
        ],
    }
    vertex_shader = (
        "#version 120\n"
        "// synthetic baseline vertex shader\n"
        "attribute vec3 a_Position;\n"
        "attribute vec2 a_TexCoord;\n"
        "varying vec2 v_TexCoord;\n"
        "void main() {\n"
        "    v_TexCoord = a_TexCoord;\n"
        "    gl_Position = vec4(a_Position, 1.0);\n"
        "}\n"
    )
    fragment_shader = (
        "#version 120\n"
        "// synthetic baseline fragment shader\n"
        "uniform sampler2D g_Texture0;\n"
        "varying vec2 v_TexCoord;\n"
        "void main() {\n"
        "    gl_FragColor = texture2D(g_Texture0, v_TexCoord);\n"
        "}\n"
    )
    return [
        ("scene.json", _json_bytes(scene)),
        ("models/quad.json", _json_bytes({"material": "materials/quad.json"})),
        (
            "models/puppet.json",
            _json_bytes({"material": "materials/puppet.json", "puppet": "models/puppet.mdl"}),
        ),
        ("models/puppet.mdl", build_mdl("materials/puppet.json", 20, 40)),
        ("materials/quad.json", _json_bytes(quad_material)),
        ("materials/puppet.json", _json_bytes(puppet_material)),
        ("materials/xray.json", _json_bytes(xray_material)),
        ("effects/xray/effect.json", _json_bytes(effect)),
        ("shaders/xray.vert", vertex_shader.encode("utf-8")),
        ("shaders/xray.frag", fragment_shader.encode("utf-8")),
        ("materials/quad.tex", build_tex_rgba(QUAD_W, QUAD_H, quad_color)),
        ("materials/puppet.tex", build_tex_rgba(PUPPET_W, PUPPET_H, puppet_color)),
        ("materials/dxt5.tex", build_tex_dxt5_solid(DXT5_W, DXT5_H, DXT5_RGB565)),
        (
            "materials/overlay.png",
            build_png_rgba(OVERLAY_W, OVERLAY_H, lambda x, y: OVERLAY_COLOR),
        ),
    ]


def expected_project_bytes() -> bytes:
    return _json_bytes(PROJECT)


def generate(out_dir) -> Path:
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    pkg = build_pkg(build_entries())
    (out_dir / "scene.pkg").write_bytes(pkg)
    (out_dir / "project.json").write_bytes(expected_project_bytes())
    return out_dir / "scene.pkg"


def main(argv) -> int:
    if len(argv) != 2:
        print("用法: make_baseline_pkg.py <out_dir>", file=sys.stderr)
        return 2
    pkg = generate(argv[1])
    print(f"wrote {pkg} ({pkg.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
