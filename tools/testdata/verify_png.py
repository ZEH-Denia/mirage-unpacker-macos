#!/usr/bin/env python3
"""校验 PNG：解析 IHDR + 解压 IDAT + 反滤波，输出尺寸与若干采样点颜色。

仅支持 8-bit RGBA/RGB 非隔行 PNG（ImageSharp 输出即为此格式）。
"""
import struct
import sys
import zlib


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def decode(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a png"
    pos = 8
    width = height = bitdepth = colortype = None
    idat = b""
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        ctype = data[pos + 4:pos + 8]
        payload = data[pos + 8:pos + 8 + length]
        if ctype == b"IHDR":
            width, height, bitdepth, colortype, _, _, interlace = struct.unpack(">IIBBBBB", payload)
            assert bitdepth == 8 and interlace == 0, "unsupported png variant"
        elif ctype == b"IDAT":
            idat += payload
        elif ctype == b"IEND":
            break
        pos += 12 + length

    channels = {0: 1, 2: 3, 4: 2, 6: 4}[colortype]
    raw = zlib.decompress(idat)
    stride = width * channels
    out = bytearray()
    prev = bytearray(stride)
    p = 0
    for _ in range(height):
        ftype = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        if ftype == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif ftype == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ftype == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                upleft = prev[i - channels] if i >= channels else 0
                line[i] = (line[i] + paeth(left, prev[i], upleft)) & 0xFF
        out += line
        prev = line
    return width, height, channels, bytes(out)


def main():
    for path in sys.argv[1:]:
        w, h, ch, px = decode(path)

        def at(x, y):
            i = (y * w + x) * ch
            return tuple(px[i:i + ch])

        print(f"{path}: {w}x{h} channels={ch}")
        print(f"  左上={at(1, 1)} 右上={at(w - 2, 1)} 左下={at(1, h - 2)} 右下={at(w - 2, h - 2)}")


if __name__ == "__main__":
    main()
