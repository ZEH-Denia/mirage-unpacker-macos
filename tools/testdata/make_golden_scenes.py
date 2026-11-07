#!/usr/bin/env python3
"""合成「金标准」场景：每个场景只验证一个可在静态帧上判定的语义。

这些场景供 PKD 的静态组合渲染器读取；像素预期由 verify_golden.py 按场景语义手算
（不读取 PKD 的实现输出，因此不是"拿实现输出当基线"）。
注意：合成包只用于 PKD 侧回归——引擎的 SceneBaker 不接受这种手工构造的包
（实测输出为空帧），与真实引擎的逐帧对照改用 pkg_ablate.py 对真实包做消融。

用法：python3 tools/testdata/make_golden_scenes.py <输出目录>
每个场景生成 <输出目录>/<name>/scene.pkg（PNG 供 PKD 读取；TEX 仅用于将来可能的引擎加载实验，当前引擎不接受这些合成包）。
"""
import importlib.util
import json
import struct
import sys
import zlib
from pathlib import Path

sys.dont_write_bytecode = True
_HERE = Path(__file__).with_name("make_test_pkg.py")
spec = importlib.util.spec_from_file_location("pkg", _HERE)
pkg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pkg)

CANVAS = (800, 640)
CAMERA = {"center": "0.00000 0.00000 -1.00000", "eye": "0.00000 0.00000 0.00000",
          "up": "0.00000 1.00000 0.00000"}


def png(color, size=8):
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    raw = (b"\0" + bytes(color) * size) * size
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def mesh(name, w, h):
    rows = []
    for x, y, u, v in [(-w / 2, -h / 2, 0, 1), (w / 2, -h / 2, 1, 1),
                       (w / 2, h / 2, 1, 0), (-w / 2, h / 2, 0, 0)]:
        row = bytearray(80)
        struct.pack_into("<3f", row, 0, x, y, 0)
        struct.pack_into("<2f", row, 72, u, v)
        rows.append(row)
    body = b"".join(rows)
    indices = struct.pack("<6H", 0, 1, 2, 0, 2, 3)
    return (b"MDLV0023" + bytes(13) + f"materials/{name}.json".encode() + b"\0" + bytes(28)
            + struct.pack("<II", 0x0180000f, len(body)) + body
            + struct.pack("<I", len(indices)) + indices)


class Scene:
    def __init__(self, root, name):
        self.dir = Path(root) / name
        self.dir.mkdir(parents=True, exist_ok=True)
        self.entries = []
        self.objects = []
        self._textures = {}

    def add(self, path, data, engine_data=None):
        if not isinstance(data, bytes):
            data = json.dumps(data).encode()
        target = self.dir / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        self.entries.append((path, data))
        if engine_data is not None:
            tex_path = path.rsplit(".", 1)[0] + ".tex"
            tex_file = self.dir / tex_path
            tex_file.parent.mkdir(parents=True, exist_ok=True)
            tex_file.write_bytes(engine_data)
            self.entries.append((tex_path, engine_data))

    def texture(self, name, color):
        if name in self._textures:
            return
        self._textures[name] = True
        self.add(f"models/{name}.json", {"material": f"materials/{name}.json"})
        self.add(f"materials/{name}.json",
                 {"passes": [{"shader": "genericimage4", "blending": "translucent",
                              "textures": [name]}]})
        self.add(f"materials/{name}.png", png(color), engine_data=pkg.build_tex(8, 8))

    def puppet(self, name, color, w, h):
        self.texture(name, color)
        model = self.dir / f"models/{name}.json"
        descriptor = json.loads(model.read_text())
        descriptor["puppet"] = f"models/{name}.mdl"
        model.write_bytes(json.dumps(descriptor).encode())
        self.entries = [(p, d) for p, d in self.entries if p != f"models/{name}.json"]
        self.add(f"models/{name}.json", descriptor)
        self.add(f"models/{name}.mdl", mesh(name, w, h))

    def finish(self):
        w, h = CANVAS
        scene = {"camera": CAMERA, "version": 5,
                 "general": {"orthogonalprojection": {"width": w, "height": h},
                             "clearcolor": "0 0 0"},
                 "objects": self.objects}
        self.add("scene.json", scene)
        # 引擎只接受新版容器（PKGV0023），PKD 侧读取解包目录，不受影响。
        (self.dir / "scene.pkg").write_bytes(pkg.build_pkg(self.entries, "PKGV0023"))
        (self.dir / "project.json").write_text(json.dumps({"title": self.dir.name, "type": "scene"}))
        return self.dir


def background(scene, color):
    scene.texture("bg", color)
    scene.objects.append({"image": "models/bg.json", "origin": f"{CANVAS[0] / 2} {CANVAS[1] / 2} 0",
                          "size": f"{CANVAS[0]} {CANVAS[1]}", "alpha": 1})


def build(root):
    root = Path(root)
    made = []

    # 1) 内建纯色层：flat 着色器输出 vec4(g_Color, g_Alpha)
    s = Scene(root, "solid")
    background(s, (64, 64, 64, 255))
    s.objects.append({"image": "models/util/solidlayer.json", "origin": "400 320 0",
                      "size": "200 200", "color": "1 0 0", "alpha": 0.5})
    made.append(s.finish())

    # 2) 普通图片层：45°（弧度）+ 色调 + 整层不透明度
    s = Scene(root, "flat")
    background(s, (0, 0, 0, 255))
    s.texture("white", (255, 255, 255, 255))
    s.objects.append({"image": "models/white.json", "origin": "400 320 0", "size": "200 200",
                      "angles": "0 0 0.78540", "color": "0 1 0", "alpha": 0.5})
    made.append(s.finish())

    # 3) 父子变换：父层 90°（弧度）+ 0.5 缩放，子层偏移 100
    s = Scene(root, "parent")
    background(s, (0, 0, 0, 255))
    s.texture("white", (255, 255, 255, 255))
    s.objects.append({"id": 100, "origin": "300 300 0", "angles": "0 0 1.57080",
                      "scale": "0.5 0.5 1", "alpha": 1})
    s.objects.append({"image": "models/white.json", "origin": "100 0 0", "size": "100 100",
                      "parent": 100, "alpha": 1})
    made.append(s.finish())

    # 4) puppet 网格：静态姿态下的顶点位置与 UV 映射
    s = Scene(root, "puppet")
    background(s, (0, 0, 255, 255))
    s.puppet("red", (255, 0, 0, 255), 200, 200)
    s.objects.append({"image": "models/red.json", "origin": "400 320 0", "size": "200 200",
                      "alpha": 1})
    made.append(s.finish())

    # 5) 百分比 / 小数不透明度叠加
    s = Scene(root, "alpha")
    background(s, (0, 0, 0, 255))
    s.texture("white", (255, 255, 255, 255))
    s.objects.append({"image": "models/white.json", "origin": "300 320 0", "size": "200 200",
                      "alpha": 50})
    s.objects.append({"image": "models/white.json", "origin": "500 320 0", "size": "200 200",
                      "alpha": 0.25})
    made.append(s.finish())

    return made


if __name__ == "__main__":
    for path in build(sys.argv[1]):
        print(path)
