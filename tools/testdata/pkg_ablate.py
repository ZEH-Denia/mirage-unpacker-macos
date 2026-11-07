#!/usr/bin/env python3
"""按 PKGV0023 读写场景包，并对 scene.json 做消融，用于取得引擎的分项基准。

用法：
    python3 tools/testdata/pkg_ablate.py <原 pkg> <已解包目录> <输出基准目录> [--clean]

在 ``<输出基准目录>/<ablate-时间-随机>/`` 下生成每个变体：
    <variant>.pkg、<variant>.scene.json、<variant>.dir/（解包目录副本 + 修改后的 scene.json）
供 PKD 静态渲染器与 SceneBaker 参考帧对同一变体渲染。

安全策略（渲染审查问题 5）：每次运行使用带归属标记的专属新目录，不删除调用者目录、
不覆盖旧运行；只有 ``--clean`` 才清理本工具自己的旧运行目录（校验标记后才删）。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import struct
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))

import evidence_tool_safety as safety  # noqa: E402

TOOL = "pkg-ablate"
DEFAULT_BASE = REPO / "app/.build"


def sha256(path: os.PathLike) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_pkg(path: os.PathLike) -> Tuple[str, List[Tuple[str, bytes]]]:
    data = Path(path).read_bytes()
    offset = 0

    def i32():
        nonlocal offset
        value = struct.unpack_from("<i", data, offset)[0]
        offset += 4
        return value

    magic_len = i32()
    magic = data[offset:offset + magic_len].decode("ascii")
    offset += magic_len
    count = i32()
    index = []
    for _ in range(count):
        name_len = i32()
        name = data[offset:offset + name_len].decode("utf-8")
        offset += name_len
        start, length = i32(), i32()
        index.append((name, start, length))
    data_start = offset  # 条目 offset 相对于索引结束处
    entries = [(name, data[data_start + start:data_start + start + length])
               for name, start, length in index]
    return magic, entries


def write_pkg(entries, magic="PKGV0023"):
    header = bytearray(struct.pack("<i", len(magic)) + magic.encode("ascii"))
    header += struct.pack("<i", len(entries))
    body = bytearray()
    position = 0
    for name, data in entries:
        raw = name.encode("utf-8")
        header += struct.pack("<i", len(raw)) + raw + struct.pack("<ii", position, len(data))
        body += data
        position += len(data)
    return bytes(header) + bytes(body)


def variants(scene):
    """返回 {name: mutator(scene_dict)}；每个变体只做一种消融。"""
    def strip_effects(s):
        for obj in s.get("objects", []):
            obj.pop("effects", None)

    def drop_kind(key):
        def mutate(s):
            s["objects"] = [o for o in s.get("objects", []) if key not in o]
        return mutate

    def drop_builtin(s):
        keep = []
        for obj in s.get("objects", []):
            image = obj.get("image")
            if isinstance(image, str) and image.startswith("models/util/"):
                continue
            keep.append(obj)
        s["objects"] = keep

    def drop_animation_layers(s):
        for obj in s.get("objects", []):
            obj.pop("animationlayers", None)

    return {
        "no_effects": strip_effects,
        "no_text": drop_kind("text"),
        "no_particles": drop_kind("particle"),
        "no_sound": drop_kind("sound"),
        "no_builtin": drop_builtin,
        "no_animationlayers": drop_animation_layers,
    }


def combine(names):
    """把多个消融合并成一个变体。"""
    def mutate(scene):
        table = variants(scene)
        for name in names:
            table[name](scene)
    return mutate


def ablate(src: Path, extracted: Path, out_dir: Path, *, clean: bool = False,
           keep: bool = True) -> Dict[str, object]:
    magic, entries = read_pkg(src)
    original = src.read_bytes()
    if write_pkg(entries, magic) != original:
        raise SystemExit("重写后与原包不一致，消融链路不可信")
    print("字节保真自校验通过")
    index = {name: i for i, (name, _) in enumerate(entries)}
    if "scene.json" not in index:
        raise SystemExit("原包没有 scene.json")
    base_scene = json.loads(entries[index["scene.json"]][1])
    if not isinstance(base_scene, dict):
        raise SystemExit("scene.json 顶层不是对象")
    if not (extracted / "scene.json").is_file():
        raise SystemExit(f"解包目录缺少 scene.json：{extracted}")

    plan = {name: mutate for name, mutate in variants(base_scene).items()}
    plan["supported_subset"] = combine(
        ["no_effects", "no_text", "no_particles", "no_sound", "no_builtin"])
    plan["supported_with_builtin"] = combine(
        ["no_effects", "no_text", "no_particles", "no_sound"])
    plan["no_effects_text_particles"] = combine(["no_effects", "no_text", "no_particles"])
    # 纯静态子集：连 puppet 动画层一起去掉（用于把"蒙皮/姿态"与"效果/文本/粒子"分开测量）
    plan["supported_bindpose"] = combine(
        ["no_effects", "no_text", "no_particles", "no_sound", "no_builtin", "no_animationlayers"])

    base = safety.ensure_directory(out_dir.resolve(), what="消融输出基准目录", create=True)
    if clean:
        for path in safety.clean_owned_runs(base, TOOL):
            print(f"已清理本工具旧运行目录：{path}")
    owner = safety.OwnedRunDir(base, TOOL, purpose=f"消融 {src.name}")
    run_dir = owner.path
    written: Dict[str, object] = {}
    try:
        for name, mutate in plan.items():
            scene = json.loads(json.dumps(base_scene))
            mutate(scene)
            payload = json.dumps(scene, ensure_ascii=False).encode()
            new_entries = [(n, payload if n == "scene.json" else d) for n, d in entries]
            variant_dir = run_dir / "variants" / name
            variant_dir.mkdir(parents=True, exist_ok=True)
            pkg_bytes = write_pkg(new_entries, magic)
            (variant_dir / "scene.pkg").write_bytes(pkg_bytes)
            project = src.parent / "project.json"
            if project.is_file():
                (variant_dir / "project.json").write_bytes(project.read_bytes())
            (run_dir / f"{name}.pkg").write_bytes(pkg_bytes)
            (run_dir / f"{name}.scene.json").write_bytes(payload)
            # PKD 侧：复制真实解包目录，仅替换 scene.json（只写本次专属目录，不删除任何调用者目录）
            target = run_dir / f"{name}.dir"
            shutil.copytree(extracted, target, ignore=shutil.ignore_patterns("*.pkg"))
            (target / "scene.json").write_bytes(payload)
            written[name] = {
                "pkg": str(run_dir / f"{name}.pkg"),
                "pkg_sha256": hashlib.sha256(pkg_bytes).hexdigest(),
                "scene_json_sha256": hashlib.sha256(payload).hexdigest(),
                "dir": str(target),
            }
        manifest = {
            "schema": 1,
            "tool": {"name": "pkg_ablate.py", "sha256": sha256(Path(__file__).resolve())},
            "created_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "source_pkg": str(src),
            "source_pkg_sha256": sha256(src),
            "extracted": str(extracted),
            "run_dir": str(run_dir),
            "magic": magic,
            "roundtrip_byte_identical": True,
            "variants": written,
            "note": "运行目录默认保留；--clean 只清理本工具自己带归属标记的旧运行目录",
        }
        (run_dir / "ablate-manifest.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=1) + "\n")
        print(f"写出 {len(plan)} 个变体到 {run_dir}")
        return manifest
    finally:
        if not keep:
            try:
                owner.cleanup()
            except safety.ToolSafetyError as error:
                print(f"警告：未清理运行目录（{error}）：{run_dir}", file=sys.stderr)


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="场景包消融（安全专属目录）")
    parser.add_argument("source")
    parser.add_argument("extracted")
    parser.add_argument("out")
    parser.add_argument("--clean", action="store_true", help="清理本工具自己的旧运行目录")
    args = parser.parse_args(argv)
    try:
        manifest = ablate(Path(args.source), Path(args.extracted), Path(args.out),
                          clean=args.clean)
    except safety.ToolSafetyError as error:
        print(f"安全拒绝：{error}", file=sys.stderr)
        return safety.EXIT_UNSAFE
    except SystemExit as error:
        print(error, file=sys.stderr)
        return 1
    print(json.dumps({"run_dir": manifest["run_dir"],
                      "variants": len(manifest["variants"])}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
