#!/usr/bin/env python3
"""可重复合成基线检查器（由 tools/dev/baseline-verify.sh 调用）。

职责：
1. 解包 `tools/testdata/baseline-scene/scene.pkg`（`repkg extract -c --overwrite`）。
2. 逐文件比对「期望清单」里的路径与 SHA-256。
3. 用**生成器已知输入**独立推导期望：直通文件逐字节等于生成器写入的字节、
   `.tex-json` 的 format/nomip 由纹理头推导、`.tex` 转换出的 PNG 尺寸与像素
   由生成器的颜色函数 / RGB565 端点推导。期望值不取自 RePKG 的实际输出。
4. 在两个独立目录各解包一次，确认可重复。
5. 篡改检测：复制一份输出并改动两个文件，确认比对会失败。

退出码：0 全部通过；1 检查失败；2 前置条件缺失（不静默跳过）。

期望清单（SHA-256 golden）默认位于
`tools/testdata/baseline-scene.expected.json`。清单里的 SHA-256 是引擎输出的
黄金快照；像素/结构断言始终由生成器推导，`--update-manifest` 只有在这些独立
断言全部通过之后才会重写清单（用于引擎版本升级后人工复核再更新）。
"""
import argparse
import hashlib
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

sys.dont_write_bytecode = True  # 不在仓库里生成 __pycache__

FIXTURE_DIR = Path("tools/testdata/baseline-scene")
FIXTURE_PKG = FIXTURE_DIR / "scene.pkg"
FIXTURE_PROJECT = FIXTURE_DIR / "project.json"
GENERATOR = Path("tools/testdata/make_baseline_pkg.py")
MANIFEST = Path("tools/testdata/baseline-scene.expected.json")
PNG_DECODER = Path("tools/testdata/verify_png.py")
DEFAULT_ENGINE = Path("tools/bin/repkg")

# 期望的 sidecar 键集合（字段值见 _check_sidecars，format/nomip 由输入推导）。
SIDECAR_KEYS = {
    "bleedtransparentcolors",
    "clampuvs",
    "format",
    "nomip",
    "nointerpolation",
    "nonpoweroftwo",
}


class PreflightError(RuntimeError):
    """前置条件缺失：脚本必须以非零退出并说明原因。"""


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def load_module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise PreflightError(f"无法加载模块: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def tree_hashes(root: Path) -> dict:
    """返回 {相对路径: sha256}（按路径排序，忽略目录）。"""
    return {
        path.relative_to(root).as_posix(): sha256_file(path)
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


class Checker:
    def __init__(self) -> None:
        self.results = []

    def check(self, name: str, ok: bool, detail: str = "") -> bool:
        self.results.append({"name": name, "ok": bool(ok), "detail": detail})
        mark = "✅" if ok else "❌"
        print(f"  {mark} {name}" + (f" — {detail}" if detail else ""))
        return bool(ok)

    @property
    def failed(self) -> int:
        return sum(1 for item in self.results if not item["ok"])

    def summary(self) -> bool:
        total = len(self.results)
        if self.failed == 0:
            print(f"\n✅ 合成基线全部通过（{total} 项检查）")
            return True
        print(f"\n❌ 合成基线失败：{self.failed}/{total} 项检查未通过")
        return False


def reset_owned_dirs(work: Path, names) -> None:
    """清理本次运行自己生成的子目录，保证同一证据目录可重复运行。"""
    for name in names:
        target = work / name
        if target.is_dir():
            shutil.rmtree(target)
        elif target.exists():
            target.unlink()


def run_engine(repkg: Path, pkg: Path, out_dir: Path, log_path: Path):
    """执行 repkg extract；返回 (进程, 日志文本)。不把退出码当作唯一成功依据。"""
    out_dir.parent.mkdir(parents=True, exist_ok=True)
    cmd = [str(repkg), "extract", str(pkg), "-o", str(out_dir), "-c", "--overwrite"]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    log = (
        f"$ {' '.join(cmd)}\n"
        f"--- exit code: {proc.returncode} ---\n"
        f"--- stdout ---\n{proc.stdout}"
        f"--- stderr ---\n{proc.stderr}"
    )
    log_path.write_text(log, encoding="utf-8")
    return proc, log


def compare_manifest(got: dict, expected: dict):
    """比对待测输出与期望清单，返回 (missing, extra, mismatched)。"""
    missing = sorted(set(expected) - set(got))
    extra = sorted(set(got) - set(expected))
    mismatched = sorted(k for k in set(got) & set(expected) if got[k] != expected[k])
    return missing, extra, mismatched


def derive_dxt5_color(rgb565: int):
    """由 RGB565 端点推导解压后的 8-bit 颜色（5/6 位扩展到 8 位）。"""
    r5 = (rgb565 >> 11) & 0x1F
    g6 = (rgb565 >> 5) & 0x3F
    b5 = rgb565 & 0x1F
    expand5 = lambda v: (v << 3) | (v >> 2)  # noqa: E731 — 5 -> 8 bit
    expand6 = lambda v: (v << 2) | (v >> 4)  # noqa: E731 — 6 -> 8 bit
    return (expand5(r5), expand6(g6), expand5(b5), 255)


def check_png_pixels(decoder, out_dir: Path, checker: Checker, generator) -> None:
    """独立像素断言：期望值来自生成器常量/格式语义，而非 RePKG 输出。"""
    quad_w, quad_h = generator.QUAD_W, generator.QUAD_H
    quad_path = out_dir / "materials/quad.png"
    try:
        w, h, ch, px = decoder.decode(quad_path)
    except Exception as exc:  # noqa: BLE001 — 如实报告解析失败
        checker.check("quad.png 可解码", False, f"{type(exc).__name__}: {exc}")
        return

    ok = checker.check(
        "quad.png 尺寸",
        (w, h, ch) == (quad_w, quad_h, 4),
        f"{w}x{h} channels={ch}（期望 {quad_w}x{quad_h} channels=4）",
    )
    if ok:
        bad = []
        for y in range(quad_h):
            for x in range(quad_w):
                i = (y * w + x) * ch
                got = tuple(px[i:i + ch])
                want = generator.quad_color(x, y)
                if got != want:
                    bad.append((x, y, want, got))
        checker.check(
            "quad.png 像素全部符合生成器四象限颜色",
            not bad,
            "64 个像素一致" if not bad else f"首个不符 {bad[0]}",
        )

    puppet_w, puppet_h = generator.PUPPET_W, generator.PUPPET_H
    try:
        w, h, ch, px = decoder.decode(out_dir / "materials/puppet.png")
    except Exception as exc:  # noqa: BLE001
        checker.check("puppet.png 可解码", False, f"{type(exc).__name__}: {exc}")
        return
    ok = checker.check(
        "puppet.png 尺寸",
        (w, h, ch) == (puppet_w, puppet_h, 4),
        f"{w}x{h} channels={ch}（期望 {puppet_w}x{puppet_h} channels=4）",
    )
    if ok:
        bad = []
        for y in range(puppet_h):
            for x in range(puppet_w):
                i = (y * w + x) * ch
                got = tuple(px[i:i + ch])
                want = generator.puppet_color(x, y)
                if got != want:
                    bad.append((x, y, want, got))
        checker.check(
            "puppet.png 像素符合左右两半颜色（含 alpha=128 直通）",
            not bad,
            "64 个像素一致" if not bad else f"首个不符 {bad[0]}",
        )

    dxt5_w, dxt5_h = generator.DXT5_W, generator.DXT5_H
    want_dxt5 = derive_dxt5_color(generator.DXT5_RGB565)
    try:
        w, h, ch, px = decoder.decode(out_dir / "materials/dxt5.png")
    except Exception as exc:  # noqa: BLE001
        checker.check("dxt5.png 可解码", False, f"{type(exc).__name__}: {exc}")
        return
    ok = checker.check(
        "dxt5.png 尺寸",
        (w, h, ch) == (dxt5_w, dxt5_h, 4),
        f"{w}x{h} channels={ch}（期望 {dxt5_w}x{dxt5_h} channels=4）",
    )
    if ok:
        pixels = {
            tuple(px[(y * w + x) * ch:(y * w + x) * ch + ch])
            for y in range(h)
            for x in range(w)
        }
        checker.check(
            "dxt5.png 纯色像素由 RGB565 端点推导",
            pixels == {want_dxt5},
            f"实际集合={sorted(pixels)} 期望={want_dxt5}",
        )

    overlay_w = generator.OVERLAY_W
    overlay_h = generator.OVERLAY_H
    try:
        w, h, ch, px = decoder.decode(out_dir / "materials/overlay.png")
    except Exception as exc:  # noqa: BLE001
        checker.check("overlay.png 可解码", False, f"{type(exc).__name__}: {exc}")
        return
    pixels = {
        tuple(px[(y * w + x) * ch:(y * w + x) * ch + ch])
        for y in range(h)
        for x in range(w)
    }
    checker.check(
        "overlay.png 直通尺寸/颜色",
        (w, h, ch) == (overlay_w, overlay_h, 4)
        and pixels == {tuple(generator.OVERLAY_COLOR)},
        f"{w}x{h} channels={ch} 颜色集合={sorted(pixels)}",
    )


def check_passthrough(out_dir: Path, checker: Checker, generator) -> None:
    """直通文件必须逐字节等于生成器写入 scene.pkg 的字节。"""
    entries = dict(generator.build_entries())
    mismatched = []
    missing = []
    for rel_path, data in entries.items():
        target = out_dir / rel_path
        if not target.is_file():
            missing.append(rel_path)
        elif target.read_bytes() != data:
            mismatched.append(rel_path)
    checker.check(
        f"包内 {len(entries)} 个条目逐字节直通",
        not missing and not mismatched,
        "全部一致"
        if not missing and not mismatched
        else f"缺失={missing[:3]} 不一致={mismatched[:3]}",
    )
    project = out_dir / "project.json"
    expected_project = generator.expected_project_bytes()
    checker.check(
        "project.json（-c 复制）逐字节等于生成器内容",
        project.is_file() and project.read_bytes() == expected_project,
        "" if project.is_file() else "文件缺失",
    )


def check_sidecars(out_dir: Path, checker: Checker, generator) -> None:
    """`.tex-json` 的 format 由纹理头 format 字段推导，nomip 由 mipmapCount=1 推导。"""
    cases = [
        ("materials/quad.tex", "rgba8888"),
        ("materials/puppet.tex", "rgba8888"),
        ("materials/dxt5.tex", "dxt5"),
    ]
    for tex_name, expected_format in cases:
        sidecar = out_dir / (tex_name + "-json")
        if not sidecar.is_file():
            checker.check(f"{sidecar.name} 存在", False, "文件缺失")
            continue
        try:
            data = json.loads(sidecar.read_text(encoding="utf-8"))
        except Exception as exc:  # noqa: BLE001
            checker.check(f"{sidecar.name} 可解析", False, f"{type(exc).__name__}: {exc}")
            continue
        ok = (
            set(data) == SIDECAR_KEYS
            and data.get("format") == expected_format
            and data.get("nomip") == "true"
        )
        checker.check(
            f"{sidecar.name} format/nomip 由输入推导",
            ok,
            f"format={data.get('format')!r} nomip={data.get('nomip')!r} keys={len(data)}",
        )


def engine_version(repkg: Path) -> str:
    """`repkg version` 的输出走 stderr（CommandLineParser 行为），两路都读。"""
    proc = subprocess.run([str(repkg), "version"], capture_output=True, text=True)
    raw = (proc.stderr or proc.stdout).strip().splitlines()
    return raw[0].strip() if raw else ""


def check_engine_identity(repkg: Path, manifest_engine, checker: Checker) -> str:
    version = engine_version(repkg)
    if manifest_engine is None:  # 首次 bootstrap：记录当前引擎版本
        checker.check("引擎版本（bootstrap 记录）", bool(version), version)
        return version
    checker.check(
        "引擎版本与期望清单一致",
        version == manifest_engine,
        f"实际 {version!r} / 期望 {manifest_engine!r}"
        "（引擎升级后需复核输出并 --update-manifest --allow-engine-version-change）",
    )
    return version


def verify(repo: Path, repkg: Path, work: Path, keep: bool, report_path) -> int:
    checker = Checker()
    generator = load_module(repo / GENERATOR, "baseline_generator")
    decoder = load_module(repo / PNG_DECODER, "baseline_png_decoder")
    manifest = json.loads((repo / MANIFEST).read_text(encoding="utf-8"))

    print(f"== 合成可重复基线 ==")
    print(f"   repo:   {repo}")
    print(f"   repkg:  {repkg}")
    print(f"   work:   {work}")
    print()

    reset_owned_dirs(work, ["generated", "extract-a", "extract-b", "tampered"])

    # ---- 1. 夹具完整性 + 生成器确定性 -------------------------------------
    fixture_pkg = repo / FIXTURE_PKG
    fixture_project = repo / FIXTURE_PROJECT
    pkg_sha = sha256_file(fixture_pkg)
    checker.check(
        "已入库 scene.pkg 与清单记录的 SHA-256 一致",
        pkg_sha == manifest["fixture"]["pkg_sha256"],
        f"{pkg_sha}",
    )
    gen_dir = work / "generated"
    generator.generate(gen_dir)
    gen_pkg = (gen_dir / "scene.pkg").read_bytes()
    gen_project = (gen_dir / "project.json").read_bytes()
    checker.check(
        "生成器输出与已入库 scene.pkg 逐字节一致（可重复生成）",
        gen_pkg == fixture_pkg.read_bytes(),
        f"生成 {sha256_bytes(gen_pkg)} / 入库 {pkg_sha}",
    )
    checker.check(
        "生成器输出 project.json 与已入库文件一致",
        gen_project == fixture_project.read_bytes(),
        sha256_bytes(gen_project),
    )

    # ---- 2. 引擎身份 -------------------------------------------------------
    version = check_engine_identity(repkg, manifest["engine"]["version"], checker)

    # ---- 3. 解包（两次，独立目录） ----------------------------------------
    out_a = work / "extract-a"
    out_b = work / "extract-b"
    proc, log = run_engine(repkg, fixture_pkg, out_a, work / "extract-a.log")
    checker.check(
        "解包进程退出码为 0",
        proc.returncode == 0,
        f"exit={proc.returncode}",
    )
    checker.check(
        "输出含完成哨兵 `Done`（不依赖退出码）",
        any(line.strip() == "Done" for line in log.splitlines()),
    )
    checker.check(
        "输出中没有引擎失败标志",
        "Failed" not in log and "Exception" not in log,
        "" if "Failed" not in log and "Exception" not in log else "日志出现 Failed/Exception",
    )
    hashes_a = tree_hashes(out_a) if out_a.is_dir() else {}
    checker.check("输出非空", bool(hashes_a), f"{len(hashes_a)} 个文件")
    if not hashes_a:
        _write_report(report_path, checker, repo, repkg, version, work, file_hashes={})
        return 1

    # ---- 4. 期望清单逐文件比对 --------------------------------------------
    expected_files = manifest["files"]
    missing, extra, mismatched = compare_manifest(hashes_a, expected_files)
    checker.check(
        "输出文件数与清单一致",
        len(hashes_a) == manifest["file_count"],
        f"实际 {len(hashes_a)} / 清单 {manifest['file_count']}",
    )
    checker.check("无缺失文件", not missing, f"缺失 {missing[:5]}" if missing else "")
    checker.check("无多余文件", not extra, f"多余 {extra[:5]}" if extra else "")
    checker.check(
        "逐文件 SHA-256 与期望清单一致",
        not mismatched,
        f"{len(mismatched)} 个不一致: {mismatched[:5]}" if mismatched else f"{len(expected_files)} 个文件全部一致",
    )

    # ---- 5. 独立期望（由生成器已知输入推导） ------------------------------
    check_passthrough(out_a, checker, generator)
    check_sidecars(out_a, checker, generator)
    check_png_pixels(decoder, out_a, checker, generator)

    # ---- 6. 两次解包可重复 -------------------------------------------------
    proc_b, _ = run_engine(repkg, fixture_pkg, out_b, work / "extract-b.log")
    hashes_b = tree_hashes(out_b) if out_b.is_dir() else {}
    checker.check(
        "第二次解包退出码为 0",
        proc_b.returncode == 0,
        f"exit={proc_b.returncode}",
    )
    checker.check(
        "两次独立解包逐文件 SHA-256 完全相同（可重复）",
        hashes_a == hashes_b,
        f"{len(hashes_a)} 个文件一致" if hashes_a == hashes_b else "存在差异",
    )
    missing_b, extra_b, mismatched_b = compare_manifest(hashes_b, expected_files)
    checker.check(
        "第二次解包同样匹配期望清单",
        not (missing_b or extra_b or mismatched_b),
        f"缺失={missing_b[:3]} 多余={extra_b[:3]} 不一致={mismatched_b[:3]}",
    )

    # ---- 7. 篡改检测 -------------------------------------------------------
    tampered = work / "tampered"
    shutil.copytree(out_a, tampered)
    tamper_targets = ["shaders/xray.vert", "materials/quad.png"]
    for rel in tamper_targets:
        target = tampered / rel
        data = bytearray(target.read_bytes())
        data[0] ^= 0xFF  # 改动首字节，足以改变 SHA-256
        target.write_bytes(bytes(data))
    tampered_hashes = tree_hashes(tampered)
    _, _, tamper_mismatched = compare_manifest(tampered_hashes, expected_files)
    checker.check(
        "篡改检测：改动 2 个输出文件后比对必须报错",
        set(tamper_mismatched) >= set(tamper_targets),
        f"检测到 {sorted(tamper_mismatched)}",
    )
    clean_after_tamper = all(
        tampered_hashes[k] != expected_files[k] for k in tamper_targets if k in expected_files
    )
    checker.check("篡改检测：改动文件的 SHA-256 确实与清单不同", clean_after_tamper)

    _write_report(report_path, checker, repo, repkg, version, work, file_hashes=hashes_a)
    if keep:
        print(f"\n证据目录：{work}")
    return 0 if checker.summary() else 1


def _write_report(report_path, checker, repo, repkg, version, work, file_hashes=None) -> None:
    if not report_path:
        return
    report = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "repo": str(repo),
        "repkg": str(repkg),
        "engine_version": version,
        "python": sys.version.split()[0],
        "work_dir": str(work),
        "fixture_pkg_sha256": sha256_file(repo / FIXTURE_PKG),
        "extracted_file_count": len(file_hashes or {}),
        "file_hashes": file_hashes or {},
        "checks": checker.results,
        "passed": checker.failed == 0,
        "failed": checker.failed,
        "total": len(checker.results),
    }
    report_path = Path(report_path)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def update_manifest(repo: Path, repkg: Path, work: Path, allow_version_change: bool = False) -> int:
    """引擎升级后重新记录 SHA-256 黄金快照；独立断言必须先全部通过。

    默认仍要求引擎版本与旧清单一致（防止悄悄换引擎）；引擎升级必须先人工确认，
    显式传入 allow_version_change=True（CLI: --allow-engine-version-change）才允许
    记录新版本。无论是否换版本，都会先跑完全部独立断言，失败则拒绝写盘。
    """
    checker = Checker()
    generator = load_module(repo / GENERATOR, "baseline_generator")
    decoder = load_module(repo / PNG_DECODER, "baseline_png_decoder")
    manifest_path = repo / MANIFEST
    old = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.is_file() else {}
    print("== 重新生成期望清单（先跑完全部独立断言）==")
    reset_owned_dirs(work, ["generated-update", "extract-update"])
    out_a = work / "extract-update"
    proc, log = run_engine(repkg, repo / FIXTURE_PKG, out_a, work / "extract-update.log")
    checker.check("解包退出码为 0", proc.returncode == 0, f"exit={proc.returncode}")
    checker.check(
        "输出含完成哨兵 `Done`",
        any(line.strip() == "Done" for line in log.splitlines()),
    )
    hashes = tree_hashes(out_a) if out_a.is_dir() else {}
    checker.check("输出非空", bool(hashes), f"{len(hashes)} 个文件")
    if not hashes:
        return 1

    check_passthrough(out_a, checker, generator)
    check_sidecars(out_a, checker, generator)
    check_png_pixels(decoder, out_a, checker, generator)
    gen_dir = work / "generated-update"
    generator.generate(gen_dir)
    checker.check(
        "生成器输出与已入库 scene.pkg 逐字节一致",
        (gen_dir / "scene.pkg").read_bytes() == (repo / FIXTURE_PKG).read_bytes(),
    )
    old_version = old.get("engine", {}).get("version")
    if allow_version_change:
        version = engine_version(repkg)
        checker.check(
            "引擎版本显式允许变更（记录新版本）",
            bool(version),
            f"{old_version!r} -> {version!r}",
        )
    else:
        version = check_engine_identity(repkg, old_version, checker)

    if checker.failed:
        checker.summary()
        print("❌ 独立断言失败，拒绝重写期望清单")
        return 1

    manifest = {
        "schema": old.get("schema", 1),
        "kind": "synthetic-reproducible-baseline",
        "description": (
            "Synthetic, repository-reproducible extraction baseline replacing the "
            "unrecoverable extracted/3608924541 real baseline. SHA-256 values are "
            "engine-output goldens pinned to the engine version below; file/pixel "
            "structure expectations are derived independently from the generator."
        ),
        "replaces": {
            "historical_path": "extracted/3608924541",
            "status": "unrecoverable-gitignored",
            "note": "Original real-asset baseline cannot be restored or re-run; do not claim it passed.",
        },
        "fixture": {
            "generator": GENERATOR.as_posix(),
            "directory": FIXTURE_DIR.as_posix(),
            "pkg": FIXTURE_PKG.as_posix(),
            "pkg_sha256": sha256_file(repo / FIXTURE_PKG),
            "project_json": FIXTURE_PROJECT.as_posix(),
            "project_json_sha256": sha256_file(repo / FIXTURE_PROJECT),
        },
        "engine": {
            "executable": DEFAULT_ENGINE.as_posix(),
            "version": version,
        },
        "extract_command": ["extract", "<scene.pkg>", "-o", "<out>", "-c", "--overwrite"],
        "file_count": len(hashes),
        "files": hashes,
        "textures": {
            "materials/quad.tex": {
                "format": "rgba8888",
                "width": generator.QUAD_W,
                "height": generator.QUAD_H,
                "expectation": "solid quadrant colors from generator",
            },
            "materials/puppet.tex": {
                "format": "rgba8888",
                "width": generator.PUPPET_W,
                "height": generator.PUPPET_H,
                "expectation": "left/right half colors incl. alpha=128 from generator",
            },
            "materials/dxt5.tex": {
                "format": "dxt5",
                "width": generator.DXT5_W,
                "height": generator.DXT5_H,
                "expectation": "solid RGB565 color expanded from endpoint",
            },
        },
        "created": old.get("created") or datetime.now(timezone.utc).date().isoformat(),
        "updated": datetime.now(timezone.utc).date().isoformat(),
        "verified_by": "bash tools/dev/baseline-verify.sh",
    }
    (repo / MANIFEST).write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"✅ 已写入 {MANIFEST}（{len(hashes)} 个文件）")
    return 0


def parse_args(argv):
    parser = argparse.ArgumentParser(description="Mirage 合成可重复基线检查器")
    parser.add_argument("--repo", required=True, help="仓库根目录")
    parser.add_argument("--repkg", default=None, help="repkg 可执行文件（默认 tools/bin/repkg）")
    parser.add_argument("--work-dir", default=None, help="证据目录（默认系统临时目录，结束即清理）")
    parser.add_argument("--update-manifest", action="store_true", help="重新生成期望清单（引擎升级后）")
    parser.add_argument(
        "--allow-engine-version-change",
        action="store_true",
        help="仅在 --update-manifest 时有效：显式允许引擎版本变化后重写清单",
    )
    parser.add_argument("--report", default=None, help="写入 JSON 报告路径")
    return parser.parse_args(argv)


def main(argv) -> int:
    args = parse_args(argv)
    if args.allow_engine_version_change and not args.update_manifest:
        print(
            "❌ 参数错误：--allow-engine-version-change 只能与 --update-manifest 一起使用"
            "（验收模式默认必须匹配清单里的引擎版本）",
            file=sys.stderr,
        )
        return 2
    repo = Path(args.repo).resolve()
    repkg = Path(args.repkg).resolve() if args.repkg else (repo / DEFAULT_ENGINE)

    work = None
    try:
        # ---- 前置条件：缺失即非零退出并说明（不静默跳过）------------------
        if not (repo / GENERATOR).is_file():
            raise PreflightError(f"缺少生成器 {repo / GENERATOR}")
        if not (repo / PNG_DECODER).is_file():
            raise PreflightError(f"缺少 PNG 解码器 {repo / PNG_DECODER}")
        if not (repo / FIXTURE_PKG).is_file():
            raise PreflightError(f"缺少已入库夹具 {repo / FIXTURE_PKG}")
        if not (repo / FIXTURE_PROJECT).is_file():
            raise PreflightError(f"缺少已入库夹具 {repo / FIXTURE_PROJECT}")
        if not args.update_manifest and not (repo / MANIFEST).is_file():
            raise PreflightError(f"缺少期望清单 {repo / MANIFEST}（可用 --update-manifest 生成）")
        if not repkg.is_file():
            raise PreflightError(
                f"缺少 RePKG 引擎: {repkg}\n"
                "   这是 Git 忽略的本地构建产物，请先运行 ./tools/build-repkg.sh，"
                "或用 REPKG=/path/to/repkg 指定。"
            )
        if not repkg.stat().st_mode & 0o111:
            raise PreflightError(f"RePKG 不可执行: {repkg}")
        if sys.version_info < (3, 8):
            raise PreflightError(f"需要 Python >= 3.8，当前 {sys.version.split()[0]}")

        if args.work_dir:
            work = Path(args.work_dir).resolve()
            work.mkdir(parents=True, exist_ok=True)
            keep = True
        else:
            work = Path(tempfile.mkdtemp(prefix="baseline-work-"))
            keep = False

        if args.update_manifest:
            return update_manifest(repo, repkg, work, args.allow_engine_version_change)
        report = args.report or (work / "report.json" if keep else None)
        return verify(repo, repkg, work, keep, report)
    except PreflightError as exc:
        print(f"❌ 前置条件缺失：{exc}", file=sys.stderr)
        return 2
    finally:
        if work is not None and not args.work_dir and work.is_dir():
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
