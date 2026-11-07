#!/usr/bin/env python3
"""后台批量核对：真实场景包 → 解包 → PKD 静态组合 → 引擎参考帧对照。

不接触前台、不切换壁纸、不改用户配置：全部在私有输出目录离屏完成。

与旧版的差别（渲染审查问题 1、5、6）：

* 参考帧视图按**场景画布**推导（与 PKD 相同的 ``min(4, 4096/max(w,h))`` 规则），不再一律
  压成 4096x2304；因此“可比”不再被固定尺寸人为制造，也不再因尺寸不同把差异算成失败。
* 每个场景明确分类：``comparable`` / ``comparable_parity_adjusted``（引擎要求偶数尺寸，只
  裁 1 列/行，不缩放） / ``not_applicable``（渲染失败等） / ``unexpected``。
* 解包失败不再只留一句猜测：记录 RePKG 返回码、完整日志路径、stdout/stderr 尾部、
  文件计数，以及“有 .tex 但没有对应图片”的可观察清单。
* 两种退出语义：
    - ``--mode report``（默认）：报告型统计。跑完即 0；但只要出现**未预期**状态
      （输出缺失、参考失败、尺寸不符、未知解包失败等）返回 4，不给“全绿”。
    - ``--mode accept``：验收型。除 ``--allow-class`` 显式允许的预期受限分类外，任何
      非 comparable 行都返回 1。
* 默认保留参考 PNG 与 sidecar 便于取证；``--prune-references`` 才删除本次生成的参考 PNG
  （保留哈希与 sidecar），并在 summary 中记录保留策略。
* 输出目录安全：拒绝根目录/家目录/仓库源码树/非空混入；``--reuse`` 需本工具归属标记。

用法：
    python3 tools/testdata/scene_matrix_report.py --workshop <工坊 content 目录> --out <私有输出目录> \
        [--mode report|accept] [--no-reference] [--no-cross-check] [--reuse] [--limit N] \
        [--prune-references] [--disk-budget-gb 2]

输出：<out>/matrix.json、<out>/matrix.md、<out>/summary.json、<out>/run-meta.json、
      <out>/extracted/、<out>/reference/、<out>/logs/。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))

import evidence_tool_safety as safety  # noqa: E402
import bake_reference  # noqa: E402

SELFTEST = REPO / "app/.build/debug/pkd-selftest"
REPKG = REPO / "tools/bin/repkg"
OUTPUT_NAME = "场景预览-实验.png"
TOOL = "scene-matrix"
MARKER = safety.MARKER_NAME

EXIT_OK = 0
EXIT_ACCEPT_FAILED = 1
EXIT_USAGE = 2
EXIT_UNEXPECTED = 4
EXIT_RESOURCE = 5

IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".tga", ".bmp", ".webp"}
VIDEO_SUFFIXES = {".mp4", ".webm", ".mov", ".m4v"}
TEX_SUFFIXES = {".tex"}
#: accept 模式下无需 allow-class 即可通过的正常分类；其余分类必须显式允许。
NORMAL_CATEGORIES = {"ok", "ok_parity_adjusted", "ok_extract_warning"}


def sha256(path: os.PathLike) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _identity(path: os.PathLike) -> Dict[str, object]:
    """文件身份：内容哈希 + 元数据，用于发现“就地重建但内容相同”的替换。"""
    stat = os.stat(path)
    return {
        "sha256": sha256(path),
        "bytes": stat.st_size,
        "inode": stat.st_ino,
        "mtime_ns": stat.st_mtime_ns,
        "ctime_ns": stat.st_ctime_ns,
    }


def _read_json(path: Path) -> Optional[Dict[str, object]]:
    try:
        value = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def _tail(lines: List[str], count: int = 15) -> List[str]:
    return [line for line in lines[-count:] if line.strip()]


def _text_tail(path: Path, count: int = 15) -> List[str]:
    try:
        return _tail(path.read_text(errors="replace").splitlines(), count)
    except OSError:
        return []


def extraction_facts(directory: Path) -> Dict[str, object]:
    """只记录可观察事实：文件后缀计数与“有 .tex 但没有同目录图片”。"""
    counts: Dict[str, int] = {}
    tex_without_image: List[str] = []
    video_texture: List[str] = []
    for dirpath, dirnames, filenames in os.walk(directory):
        dirnames.sort()
        stems = {}
        for name in filenames:
            suffix = Path(name).suffix.lower()
            counts[suffix] = counts.get(suffix, 0) + 1
            stems.setdefault(Path(name).stem, set()).add(suffix)
        for name in sorted(filenames):
            path = Path(name)
            if path.suffix.lower() not in TEX_SUFFIXES:
                continue
            stem_suffixes = stems.get(path.stem, set())
            relative = str((Path(dirpath) / name).relative_to(directory))
            if not (stem_suffixes & IMAGE_SUFFIXES):
                tex_without_image.append(relative)
                if stem_suffixes & VIDEO_SUFFIXES:
                    video_texture.append(relative)
    return {
        "suffix_counts": dict(sorted(counts.items())),
        "tex_count": counts.get(".tex", 0),
        "image_count": sum(counts.get(suffix, 0) for suffix in IMAGE_SUFFIXES),
        "tex_without_image": {"count": len(tex_without_image), "sample": tex_without_image[:25]},
        "video_texture_without_image": {"count": len(video_texture), "sample": video_texture[:25]},
    }


def extract(package: Path, target: Path, *, reuse: bool, log_path: Path,
            pkg_sha256: str) -> Dict[str, object]:
    source_marker = target / ".source.json"
    if reuse and (target / "scene.json").is_file():
        facts = extraction_facts(target)
        recorded = _read_json(source_marker)
        base = {"log": str(log_path), "scene_json_present": True, "seconds": 0.0,
                **facts}
        if recorded is None:
            return {"status": "reuse_provenance_missing", "reason":
                    "解包目录没有 .source.json 输入来源记录，无法证明与当前包一致；请换新输出目录重跑",
                    "returncode": None, "timed_out": False, **base}
        if recorded.get("package_sha256") != pkg_sha256:
            return {"status": "reuse_input_mismatch",
                    "reason": "解包目录来源包哈希与当前包不一致，拒绝把旧解包结果当本次输入",
                    "recorded_package_sha256": recorded.get("package_sha256"),
                    "expected_package_sha256": pkg_sha256,
                    "returncode": None, "timed_out": False, **base}
        return {"status": "reused", "returncode": None, "timed_out": False,
                "provenance_verified": True, **base}
    target.mkdir(parents=True, exist_ok=True)
    started = time.perf_counter()
    try:
        proc = subprocess.run([str(REPKG), "extract", str(package), "-o", str(target), "--overwrite"],
                              capture_output=True, text=True, timeout=1800)
        stdout, stderr, returncode, timed_out = proc.stdout, proc.stderr, proc.returncode, False
    except subprocess.TimeoutExpired as failure:
        stdout = (failure.stdout or "") if isinstance(failure.stdout, str) else ""
        stderr = (failure.stderr or "") if isinstance(failure.stderr, str) else ""
        returncode, timed_out = None, True
    seconds = round(time.perf_counter() - started, 2)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.write_text(f"# rc={returncode} timed_out={timed_out} seconds={seconds}\n"
                        f"--- stdout ---\n{stdout}\n--- stderr ---\n{stderr}\n")
    scene_present = (target / "scene.json").is_file()
    facts = extraction_facts(target)
    if scene_present:
        source_marker.write_text(json.dumps({
            "schema": 1,
            "package": str(package),
            "package_sha256": pkg_sha256,
            "package_bytes": package.stat().st_size,
            "extracted_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "tool": "scene_matrix_report.py",
            "repkg_returncode": returncode,
        }, ensure_ascii=False, indent=1))
    if not scene_present:
        status = "failed"
    elif returncode != 0 or timed_out:
        status = "warning_nonzero_returncode"
    else:
        status = "ok"
    return {
        "status": status,
        "returncode": returncode,
        "timed_out": timed_out,
        "seconds": seconds,
        "log": str(log_path),
        "scene_json_present": scene_present,
        "stdout_tail": _tail(stdout.splitlines()),
        "stderr_tail": _tail(stderr.splitlines()),
        "source_marker": str(source_marker) if scene_present else None,
        **facts,
    }


def render(directory: Path, *, log_path: Path, selftest: Path) -> Dict[str, object]:
    output = directory / OUTPUT_NAME
    before_mtime = output.stat().st_mtime_ns if output.is_file() else None
    started = time.perf_counter()
    try:
        proc = subprocess.run([str(selftest), "--render-directory", str(directory)],
                              capture_output=True, text=True, timeout=600)
        stdout, stderr, returncode, timed_out = proc.stdout, proc.stderr, proc.returncode, False
    except subprocess.TimeoutExpired as failure:
        stdout = (failure.stdout or "") if isinstance(failure.stdout, str) else ""
        stderr = (failure.stderr or "") if isinstance(failure.stderr, str) else ""
        returncode, timed_out = None, True
    seconds = round(time.perf_counter() - started, 2)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.write_text(f"# rc={returncode} timed_out={timed_out} seconds={seconds}\n"
                        f"--- stdout ---\n{stdout}\n--- stderr ---\n{stderr}\n")
    lines = stdout.strip().splitlines()
    after_mtime = output.stat().st_mtime_ns if output.is_file() else None
    stale_output = (returncode == 0 and output.is_file() and before_mtime is not None
                    and after_mtime == before_mtime)
    return {
        "ok": returncode == 0 and output.is_file() and not stale_output,
        "stale_output": stale_output,
        "returncode": returncode,
        "timed_out": timed_out,
        "seconds": seconds,
        "report": lines[-1] if lines else "",
        "stdout_tail": _tail(lines),
        "stderr_tail": _tail(stderr.splitlines()),
        "log": str(log_path),
        "output_present": output.is_file(),
        "output_sha256": sha256(output) if output.is_file() else None,
        "output_bytes": output.stat().st_size if output.is_file() else None,
        "output_size": _image_size(output) if output.is_file() else None,
    }


def _image_size(path: Path) -> Optional[List[int]]:
    from PIL import Image

    try:
        with Image.open(path) as image:
            return [image.size[0], image.size[1]]
    except OSError:
        return None


def compare(reference: Path, ours: Path) -> Dict[str, object]:
    from PIL import Image
    import numpy as np

    try:
        with Image.open(reference) as handle:
            a = np.asarray(handle.convert("RGB"), dtype=np.int16)
        with Image.open(ours) as handle:
            b = np.asarray(handle.convert("RGB"), dtype=np.int16)
    except OSError as error:
        return {"status": "error", "comparable": False, "reason": f"图片读取失败：{error}"}
    if a.shape != b.shape:
        return {
            "status": "incomparable",
            "comparable": False,
            "reason": "shape_mismatch",
            "reference_shape": list(a.shape),
            "ours_shape": list(b.shape),
        }
    diff = np.abs(a - b)
    return {
        "status": "comparable",
        "comparable": True,
        "mean_abs": round(float(diff.mean()), 3),
        "gt16_pct": round(float((diff.max(axis=2) > 16).mean() * 100), 3),
        "gt64_pct": round(float((diff.max(axis=2) > 64).mean() * 100), 3),
        "signed_channel_mean": [round(float(value), 3) for value in (a - b).reshape(-1, 3).mean(axis=0)],
        "shape": list(a.shape),
    }



def _reuse_reference(reference_png: Path, pkg_sha: str, canvas, meta: Dict[str, object]) -> Optional[Dict[str, object]]:
    """--reuse 时复用上一轮同输入、同引擎的参考；只复用有 sidecar 且哈希自洽的。"""
    sidecar_path = Path(str(reference_png) + ".request.json")
    if not (reference_png.is_file() and sidecar_path.is_file()):
        return None
    try:
        sidecar = json.loads(sidecar_path.read_text())
        detail = sidecar["input"]
        viewport = sidecar["viewport"]
        renderer_sha = sidecar["engine"]["renderer_sha256"]
    except (OSError, ValueError, KeyError, TypeError):
        return None
    if detail.get("package_sha256") != pkg_sha:
        return None
    expected_w, expected_h, _ = bake_reference.derived_viewport(canvas)
    bake_w, bake_h, parity = bake_reference._bake_viewport(expected_w, expected_h)
    if viewport.get("baked") != {"width": bake_w, "height": bake_h}:
        return None
    current_renderer = ((meta.get("tools") or {}).get("scene_baker") or {}).get("sha256")
    if current_renderer and renderer_sha != current_renderer:
        return None
    # 引擎 assets 与请求参数也必须一致；否则复用的参考不是同一条件。
    current_assets = (meta.get("assets_manifest") or {}).get("sha256") if isinstance(meta.get("assets_manifest"), dict) else None
    sidecar_assets = (sidecar.get("engine") or {}).get("assets_manifest") or {}
    if current_assets and sidecar_assets.get("sha256") != current_assets:
        return None
    request = sidecar.get("request") or {}
    expected_request = {"fps": 24, "duration": 1, "warmup": 0, "speed": 1.0, "seed": 0,
                        "fillMode": "stretch", "properties": {}, "audio": False,
                        "width": bake_w, "height": bake_h}
    for key, expected in expected_request.items():
        if request.get(key) != expected:
            return None
    if (sidecar.get("frame_semantics") or {}).get("dump_env") != "SCENERENDERER_DUMP_FRAME":
        return None
    if sidecar.get("dump", {}).get("png_sha256") != sha256(reference_png):
        return None
    cross = sidecar.get("mp4_cross_check") or {}
    return {
        "status": "ok",
        "reused": True,
        "reuse_validated": {
            "package_sha256": True, "viewport": True, "renderer_sha256": True,
            "assets_manifest": bool(current_assets), "request": True, "frame_semantics": True,
        },
        "path": str(reference_png),
        "sha256": sidecar["dump"]["png_sha256"],
        "sidecar": str(sidecar_path),
        "viewport": viewport["baked"],
        "parity_adjusted": viewport.get("parity_adjusted"),
        "engine_returncode": sidecar.get("engine_run", {}).get("returncode"),
        "cross_check": {
            "video": (cross.get("video") or {}),
            "dump_vs_decoded": cross.get("dump_vs_decoded"),
            "frame_semantics_note": cross.get("conclusion"),
        } if cross else None,
    }


def classify(row: Dict[str, object]) -> Tuple[str, bool]:
    """返回 (分类, 是否属于预期受限/正常)。"""
    extraction = row.get("extract") or {}
    rendering = row.get("render") or {}
    reference = row.get("reference") or {}
    comparison = row.get("compare") or {}

    if extraction.get("status") in ("reuse_provenance_missing", "reuse_input_mismatch"):
        return "reuse_input_unverified", False
    if extraction.get("status") == "failed" or not extraction.get("scene_json_present"):
        return "extract_failed", False
    if extraction.get("status") == "warning_nonzero_returncode" and rendering.get("ok") \
            and (reference.get("status") in ("ok", "skipped")):
        return "ok_extract_warning", True
    if rendering.get("stale_output"):
        return "stale_render_output", False
    if not rendering.get("output_present") and rendering.get("returncode") == 0:
        # 命令成功却没有输出：这是真正的未预期状态，不是已知受限。
        return "missing_render_output", False
    if not rendering.get("ok"):
        tex_missing = (extraction.get("tex_without_image") or {}).get("count", 0)
        video_texture = (extraction.get("video_texture_without_image") or {}).get("count", 0)
        report = str(rendering.get("report") or "")
        if video_texture:
            return "render_fallback_video_texture", True
        if tex_missing:
            return "render_fallback_texture_missing", True
        return "render_failed_other", False
    if reference.get("status") == "error":
        return "reference_failed", False
    if reference.get("status") in ("skipped", None):
        return "not_applicable_no_reference", True
    if comparison.get("status") == "incomparable":
        return "incomparable_shape", False
    if comparison.get("status") != "comparable":
        return "compare_unavailable", False
    if (reference.get("parity_adjusted")):
        return "ok_parity_adjusted", True
    return "ok", True


def _summary(rows: List[Dict[str, object]]) -> Dict[str, object]:
    def count(predicate) -> int:
        return sum(1 for row in rows if predicate(row))

    render_ok = count(lambda row: (row.get("render") or {}).get("ok"))
    comparable = count(lambda row: (row.get("compare") or {}).get("comparable"))
    parity = count(lambda row: ((row.get("compare") or {}).get("comparable")
                                and (row.get("reference") or {}).get("parity_adjusted")))
    categories: Dict[str, int] = {}
    unexpected = []
    for row in rows:
        category = row.get("classification") or "unclassified"
        categories[category] = categories.get(category, 0) + 1
        if not row.get("expected", False):
            unexpected.append({"scene": row.get("scene"), "classification": category})
    return {
        "scenes": len(rows),
        "extract_ok": count(lambda row: (row.get("extract") or {}).get("status") in ("ok", "reused", "warning_nonzero_returncode")),
        "extract_failed": count(lambda row: (row.get("extract") or {}).get("status") == "failed"),
        "render_ok": render_ok,
        "render_failed": len(rows) - render_ok,
        "reference_ok": count(lambda row: (row.get("reference") or {}).get("status") == "ok"),
        "reference_failed": count(lambda row: (row.get("reference") or {}).get("status") == "error"),
        "reference_skipped": count(lambda row: (row.get("reference") or {}).get("status") == "skipped"),
        "comparable": comparable,
        "comparable_parity_adjusted": parity,
        "comparable_exact": comparable - parity,
        "not_comparable": len(rows) - comparable,
        "not_applicable": count(lambda row: (row.get("compare") or {}).get("status") == "not_applicable"),
        "categories": dict(sorted(categories.items())),
        "unexpected": unexpected,
        "unexpected_count": len(unexpected),
    }


def _matrix_markdown(rows: List[Dict[str, object]], summary: Dict[str, object],
                     meta: Dict[str, object]) -> str:
    lines = [
        "# 真实场景矩阵（自动生成）",
        "",
        f"- 生成时间：{meta['started_at']}（耗时 {meta.get('seconds')} 秒）",
        f"- 工坊目录：`{meta['workshop']}`（只读）",
        f"- 场景数：{summary['scenes']}；渲染成功 {summary['render_ok']}；"
        f"引擎参考可比 {summary['comparable']}（精确 {summary['comparable_exact']} + "
        f"仅偶数化裁剪 {summary['comparable_parity_adjusted']}）",
        f"- 不可比/不适用：{summary['not_comparable']}；未预期：{summary['unexpected_count']}",
        f"- 保留策略：{'保留参考 PNG' if meta['keep_references'] else '已按 --prune-references 删除参考 PNG（保留哈希与 sidecar）'}",
        "",
        "## 分类（自动统计）",
        "",
        "| 分类 | 数量 | 说明 |",
        "| --- | --- | --- |",
    ]
    notes = {
        "ok": "渲染成功且与引擎参考同尺寸可比",
        "ok_parity_adjusted": "渲染成功；引擎要求偶数视图，参考多渲 1 列/行后裁掉，未缩放",
        "ok_extract_warning": "渲染/参考正常，但 RePKG 返回码非 0（已记录真实日志）",
        "render_fallback_texture_missing": "预期受限：包内纹理没有转换出图片（RePKG 日志有明确原因），渲染按回退失败",
        "render_fallback_video_texture": "预期受限：纹理是视频纹理（.tex 旁有同名视频、没有图片），静态预览无法绘制",
        "extract_failed": "解包失败（无 scene.json）",
        "missing_render_output": "渲染命令成功但没有输出文件",
        "stale_render_output": "渲染命令返回 0，但输出文件未被本次运行更新（疑似旧产物）",
        "reuse_input_unverified": "复用解包目录但缺少输入来源记录 / 与当前包哈希不一致（拒绝混用）",
        "render_failed_other": "渲染失败，原因未归类为已知纹理限制",
        "reference_failed": "引擎参考帧生成失败",
        "incomparable_shape": "输出与参考尺寸不一致（不应发生）",
        "compare_unavailable": "缺少可用于比较的图片",
        "not_applicable_no_reference": "按要求跳过参考对照",
    }
    for category, count in summary["categories"].items():
        lines.append(f"| `{category}` | {count} | {notes.get(category, '')} |")
    lines += ["", "## 逐场景", "",
              "| 场景 | 画布 | 解包 | 渲染 | 参考 | 比较 | mean / >16 | 耗时 |",
              "| --- | --- | --- | --- | --- | --- | --- | --- |"]
    for row in rows:
        extraction = row.get("extract") or {}
        rendering = row.get("render") or {}
        reference = row.get("reference") or {}
        comparison = row.get("compare") or {}
        viewport = row.get("viewport") or {}
        canvas = viewport.get("canvas") or {}
        extract_state = extraction.get("status", "-")
        if extraction.get("returncode") not in (None, 0):
            extract_state += f"(rc={extraction['returncode']})"
        render_state = "成功" if rendering.get("ok") else "失败"
        ref_state = reference.get("status", "-")
        if reference.get("parity_adjusted"):
            ref_state += "(parity)"
        if comparison.get("status") == "comparable":
            compare_state = comparison["status"]
            if "mean_abs" in comparison and "gt16_pct" in comparison:
                metric = f"{comparison['mean_abs']} / {comparison['gt16_pct']}%"
            else:
                metric = "-"
        else:
            compare_state = comparison.get("reason") or comparison.get("status", "-")
            metric = "-"
        lines.append(
            f"| {row.get('scene')} | {canvas.get('width', '-')}x{canvas.get('height', '-')} | "
            f"{extract_state} | {render_state} | {ref_state} | {compare_state} | {metric} | "
            f"{rendering.get('seconds', '-')}s |")
    lines.append("")
    return "\n".join(lines)


def _hash_if_file(path: Path) -> Optional[str]:
    return sha256(path) if path.is_file() else None


def _evaluate_existing(out: Path, args) -> int:
    """只读既有 matrix.json：重新分类、重写 summary，并按 report/accept 返回退出码。"""
    matrix_path = out / "matrix.json"
    if not matrix_path.is_file():
        print(f"缺少 {matrix_path}", file=sys.stderr)
        return EXIT_USAGE
    try:
        rows = json.loads(matrix_path.read_text())
    except ValueError as error:
        print(f"matrix.json 解析失败：{error}", file=sys.stderr)
        return EXIT_USAGE
    if not isinstance(rows, list):
        print("matrix.json 顶层不是数组", file=sys.stderr)
        return EXIT_USAGE
    for row in rows:
        row["classification"], row["expected"] = classify(row)
    summary = _summary(rows)
    meta_path = out / "run-meta.json"
    try:
        meta = json.loads(meta_path.read_text())
    except (OSError, ValueError):
        meta = {"started_at": "-", "workshop": "-", "keep_references": True}
    (out / "summary.json").write_text(json.dumps({"meta": meta, "summary": summary},
                                                 ensure_ascii=False, indent=1))
    (out / "matrix.md").write_text(_matrix_markdown(rows, summary, meta))
    print(json.dumps({"mode": args.mode, "summary": summary,
                      "allow_class": args.allow_class}, ensure_ascii=False))
    allowed = set(args.allow_class)
    disallowed = [row for row in rows
                  if (row.get("classification") or "") not in NORMAL_CATEGORIES
                  and (row.get("classification") or "") not in allowed]
    if args.mode == "accept":
        if disallowed:
            return EXIT_ACCEPT_FAILED
        if summary["comparable"] == 0:
            return EXIT_ACCEPT_FAILED
        return EXIT_OK
    return EXIT_UNEXPECTED if summary["unexpected_count"] else EXIT_OK


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="真实场景矩阵（后台离屏）")
    parser.add_argument("--workshop", help="工坊 content 目录（含 <id>/scene.pkg）；--evaluate-only 时可省略")
    parser.add_argument("--out", required=True, help="私有输出目录（新目录/空目录，或本工具上一次的证据目录 + --reuse）")
    parser.add_argument("--mode", choices=("report", "accept"), default="report")
    parser.add_argument("--no-reference", action="store_true", help="跳过引擎参考帧对照")
    parser.add_argument("--no-cross-check", action="store_true", help="不做 MP4 编码/色彩误差交叉核对")
    parser.add_argument("--reuse", action="store_true", help="复用本工具上一次的解包目录（只读复用，不删除）")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--prune-references", action="store_true",
                        help="显式删除本次生成的参考 PNG（保留 sha256/sidecar）")
    parser.add_argument("--disk-budget-gb", type=float, default=3.0,
                        help="运行前要求的最小可用空间（GB，默认 3，含约 2.4 GB 解包/参考/日志）")
    parser.add_argument("--allow-class", action="append", default=[],
                        help="accept 模式允许的预期受限分类（可重复）")
    parser.add_argument("--evaluate-only", action="store_true",
                        help="不重跑，只读取既有 matrix.json 重新分类并按模式返回退出码")
    args = parser.parse_args(argv)

    if args.evaluate_only:
        # 只读既有 matrix.json 的离线复核：不依赖工坊目录、待测二进制或 repkg。
        out = Path(args.out).resolve()
        try:
            out = safety.ensure_directory(out, what="矩阵证据目录", create=False)
            if not safety.has_owned_marker(out, tool=TOOL):
                print(f"--evaluate-only 只接受本工具带归属标记的证据目录：{out}", file=sys.stderr)
                return safety.EXIT_UNSAFE
        except safety.ToolSafetyError as error:
            print(f"安全拒绝：{error}", file=sys.stderr)
            return safety.EXIT_UNSAFE
        if not (out / "matrix.json").is_file():
            print(f"--evaluate-only 需要既有 matrix.json：{out}", file=sys.stderr)
            return EXIT_USAGE
        return _evaluate_existing(out, args)

    if not args.workshop:
        print("--workshop 在正常运行时必填", file=sys.stderr)
        return EXIT_USAGE
    if not SELFTEST.is_file():
        print(f"缺少 {SELFTEST}，请先构建", file=sys.stderr)
        return EXIT_RESOURCE
    if not REPKG.is_file():
        print(f"缺少 {REPKG}", file=sys.stderr)
        return EXIT_RESOURCE

    workshop = Path(args.workshop).resolve()
    if not workshop.is_dir():
        print(f"工坊目录不存在：{workshop}", file=sys.stderr)
        return EXIT_USAGE
    packages = sorted(workshop.glob("*/scene.pkg"))
    if args.limit:
        packages = packages[: args.limit]
    if not packages:
        print(f"工坊目录下没有 <id>/scene.pkg：{workshop}", file=sys.stderr)
        return EXIT_USAGE

    out = Path(args.out).resolve()
    try:
        out = safety.ensure_directory(out, what="矩阵输出目录", create=True)
        if any(out.iterdir()):
            if safety.has_owned_marker(out, tool=TOOL):
                if not args.reuse:
                    print(f"输出目录已有本工具的证据；如要复用解包请显式 --reuse：{out}", file=sys.stderr)
                    return EXIT_USAGE
            else:
                print(f"输出目录已存在且非空，拒绝混入（请换新目录）：{out}", file=sys.stderr)
                return EXIT_USAGE
        else:
            safety.write_owner_marker(out, TOOL, purpose="真实场景矩阵证据")
    except safety.ToolSafetyError as error:
        print(f"安全拒绝：{error}", file=sys.stderr)
        return safety.EXIT_UNSAFE

    usage = shutil.disk_usage(out)
    free_gb = usage.free / 1e9
    if free_gb < args.disk_budget_gb:
        print(f"可用空间不足：{free_gb:.1f} GB < 预算 {args.disk_budget_gb} GB", file=sys.stderr)
        return EXIT_RESOURCE

    started = time.time()
    meta: Dict[str, object] = {
        "tool": {"name": "scene_matrix_report.py", "sha256": sha256(Path(__file__).resolve())},
        "argv": sys.argv,
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "workshop": str(workshop),
        "out": str(out),
        "mode": args.mode,
        "keep_references": not args.prune_references,
        "cross_check": not args.no_cross_check,
        "disk_free_gb_at_start": round(free_gb, 2),
        "tools": {
            "pkd_selftest": {"path": str(SELFTEST), **_identity(SELFTEST)},
            "repkg": {"path": str(REPKG), **_identity(REPKG)},
            "scene_baker": ({"path": str(bake_reference.BAKER), **_identity(bake_reference.BAKER)}
                            if bake_reference.BAKER.is_file() else {"path": str(bake_reference.BAKER)}),
            "mirage_version": bake_reference._mirage_version(),
        },
        "assets_manifest": None,
    }
    if not args.no_reference:
        try:
            meta["assets_manifest"] = bake_reference.sha256_tree(bake_reference.ASSETS)
        except OSError as error:
            meta["assets_manifest"] = {"error": str(error)}

    (out / "extracted").mkdir(exist_ok=True)
    (out / "reference").mkdir(exist_ok=True)
    (out / "logs").mkdir(exist_ok=True)
    (out / "bin").mkdir(exist_ok=True)
    # 固定待测二进制：把当前构建复制到证据目录后只用副本渲染，避免并发就地重建导致
    # “同一次矩阵用不同二进制”或 exec 被 SIGKILL；原始路径与哈希仍完整记录。
    selftest_bin = out / "bin" / "pkd-selftest"
    if not selftest_bin.is_file():
        shutil.copy2(SELFTEST, selftest_bin)
    os.chmod(selftest_bin, 0o755)
    meta["tools"]["pkd_selftest"] = {
        "source_path": str(SELFTEST),
        "source_identity": _identity(SELFTEST),
        "pinned_path": str(selftest_bin),
        "pinned_identity": _identity(selftest_bin),
        "renders_use": "pinned_path",
    }
    attempt_name = time.strftime("%Y%m%d-%H%M%S")
    attempt_start = out / "logs" / f"attempt-{attempt_name}-start.json"
    attempt_start.write_text(json.dumps({
        "argv": sys.argv, "pid": os.getpid(), "started_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "out": str(out), "mode": args.mode, "reuse": args.reuse,
        "tools": {name: {"sha256": value.get("sha256"), "inode": value.get("inode"),
                         "mtime_ns": value.get("mtime_ns")}
                  for name, value in meta["tools"].items() if isinstance(value, dict)},
    }, ensure_ascii=False, indent=1))
    meta["attempt_logs"] = [str(attempt_start)]
    (out / "run-meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1))

    rows: List[Dict[str, object]] = []
    for index, package in enumerate(packages, 1):
        scene = package.parent.name
        target = out / "extracted" / scene
        viewport: Dict[str, object] = {}
        row: Dict[str, object] = {"scene": scene, "pkg_bytes": package.stat().st_size,
                                  "pkg_sha256": sha256(package)}
        print(f"[{index}/{len(packages)}] {scene}", flush=True)

        extract_info = extract(package, target, reuse=args.reuse,
                               log_path=out / "logs" / f"{scene}-repkg.log",
                               pkg_sha256=row["pkg_sha256"])
        row["extract"] = extract_info
        if extract_info["status"] == "failed":
            row["viewport"] = viewport
            row["classification"], row["expected"] = classify(row)
            rows.append(row)
            continue

        # 画布来自场景文件本身（与 PKD 相同规则），先记录再决定参考视图。
        try:
            scene_json, _ = bake_reference.scene_from_pkg(package)
            canvas = bake_reference.scene_canvas(scene_json)
            viewport["canvas"] = {"width": canvas[0], "height": canvas[1]}
            derived = bake_reference.derived_viewport(canvas)
            viewport["pkd_output_expected"] = {"width": derived[0], "height": derived[1]}
        except SystemExit as error:
            row["viewport"] = viewport
            row["scene_error"] = str(error)
            row["classification"], row["expected"] = "scene_error", False
            rows.append(row)
            continue

        row["render"] = render(target, log_path=out / "logs" / f"{scene}-render.log",
                               selftest=selftest_bin)
        row["viewport"] = viewport
        if args.no_reference:
            row["reference"] = {"status": "skipped", "reason": "--no-reference"}
        elif not row["render"]["ok"]:
            row["reference"] = {"status": "skipped", "reason": "render_failed"}
        else:
            reference_png = out / "reference" / f"{scene}.png"
            reused = _reuse_reference(reference_png, row["pkg_sha256"], canvas, meta) if args.reuse else None
            if reused is not None:
                row["reference"] = reused
            else:
                try:
                    sidecar = bake_reference.bake(
                        package, reference_png, fps=24,
                        cross_check=not args.no_cross_check,
                        force=args.reuse and reference_png.is_file(),
                        assets_manifest=meta.get("assets_manifest"))
                    cross = sidecar.get("mp4_cross_check") or {}
                    row["reference"] = {
                        "status": "ok",
                        "path": str(reference_png),
                        "sha256": sidecar["dump"]["png_sha256"],
                        "sidecar": str(reference_png) + ".request.json",
                        "viewport": sidecar["viewport"]["baked"],
                        "parity_adjusted": sidecar["viewport"]["parity_adjusted"],
                        "engine_returncode": sidecar["engine_run"]["returncode"],
                        "cross_check": {
                            "video": (cross.get("video") or {}),
                            "dump_vs_decoded": cross.get("dump_vs_decoded"),
                            "frame_semantics_note": (cross.get("conclusion")),
                        } if cross else None,
                    }
                    reference_status = "ok"
                except (SystemExit, safety.ToolSafetyError, OSError) as error:
                    reference_status = "error"
                    row["reference"] = {"status": "error", "error": str(error),
                                        "real_engine_message": str(error)}
                row["reference"]["status"] = reference_status

        ours = target / OUTPUT_NAME
        if row["render"]["ok"] and row["reference"].get("status") == "ok":
            reference_png = Path(str(row["reference"]["path"]))
            row["compare"] = compare(reference_png, ours)
        elif not row["render"]["ok"]:
            row["compare"] = {"status": "not_applicable", "comparable": False,
                              "reason": "render_failed"}
        elif row["reference"].get("status") == "skipped":
            row["compare"] = {"status": "not_applicable", "comparable": False,
                              "reason": "reference_skipped"}
        else:
            row["compare"] = {"status": "not_applicable", "comparable": False,
                              "reason": "reference_failed"}

        row["classification"], row["expected"] = classify(row)
        if args.prune_references and row["reference"].get("path"):
            try:
                Path(row["reference"]["path"]).unlink()
                row["reference"]["pruned_after_hashing"] = True
            except OSError as error:
                row["reference"]["prune_error"] = str(error)
        rows.append(row)

    finished = time.time()
    meta["finished_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(finished))
    meta["seconds"] = round(finished - started, 1)
    if SELFTEST.is_file():
        meta["tools"]["pkd_selftest"]["source_identity_after"] = _identity(SELFTEST)
    if selftest_bin.is_file():
        meta["tools"]["pkd_selftest"]["pinned_identity_after"] = _identity(selftest_bin)
    for name, path in (("scene_baker", bake_reference.BAKER), ("repkg", REPKG)):
        if path.is_file():
            after = _identity(path)
            meta["tools"][name]["identity_after"] = after
            meta["tools"][name]["sha256_after"] = after["sha256"]
    summary = _summary(rows)

    (out / "matrix.json").write_text(json.dumps(rows, ensure_ascii=False, indent=1))
    (out / "summary.json").write_text(json.dumps({"meta": meta, "summary": summary},
                                                 ensure_ascii=False, indent=1))
    (out / "matrix.md").write_text(_matrix_markdown(rows, summary, meta))
    (out / "run-meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1))

    print("\n".join([
        f"场景 {summary['scenes']}；解包失败 {summary['extract_failed']}；"
        f"渲染成功 {summary['render_ok']}/{summary['scenes']}；参考可比 {summary['comparable']}"
        f"（精确 {summary['comparable_exact']} + 偶数化裁剪 {summary['comparable_parity_adjusted']}）",
        f"分类：{json.dumps(summary['categories'], ensure_ascii=False)}",
        f"未预期：{summary['unexpected_count']}",
        f"耗时 {meta['seconds']} 秒；明细 {out}/matrix.md",
    ]))

    selftest_meta = meta["tools"]["pkd_selftest"]
    source_changed = selftest_meta.get("source_identity") != selftest_meta.get("source_identity_after")
    pinned_changed = selftest_meta.get("pinned_identity") != selftest_meta.get("pinned_identity_after")
    other_changed = False
    for name in ("scene_baker", "repkg"):
        entry = meta["tools"].get(name) or {}
        after = entry.get("identity_after") or {}
        if (entry.get("sha256") != after.get("sha256")
                or entry.get("inode") != after.get("inode")
                or entry.get("mtime_ns") != after.get("mtime_ns")):
            other_changed = True
    if source_changed and not pinned_changed:
        print("提示：运行期间原始构建被就地重建；本次全部渲染使用证据目录内的固定副本 "
              f"{selftest_meta.get('pinned_path')}（sha256 {selftest_meta.get('pinned_identity', {}).get('sha256')}），"
              "副本运行前后未变", file=sys.stderr)
    if pinned_changed or other_changed:
        print("警告：证据目录内的固定二进制/引擎/repkg 在运行期间被改动，本次统计不是同一份快照",
              file=sys.stderr)
    attempt_result = out / "logs" / f"attempt-{attempt_name}-result.json"
    attempt_result.write_text(json.dumps({
        "argv": sys.argv, "finished_at": meta["finished_at"], "seconds": meta["seconds"],
        "summary": summary, "source_changed": source_changed,
        "pinned_changed": pinned_changed, "other_changed": other_changed,
    }, ensure_ascii=False, indent=1))
    meta["attempt_logs"].append(str(attempt_result))
    (out / "run-meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1))

    if args.mode == "accept":
        allowed = set(args.allow_class)
        failures = [row for row in rows
                    if (row.get("classification") or "") not in NORMAL_CATEGORIES
                    and (row.get("classification") or "") not in allowed]
        if failures:
            for row in failures:
                print(f"验收失败：{row['scene']} -> {row.get('classification')}", file=sys.stderr)
            if allowed:
                print(f"允许分类：{sorted(allowed)}", file=sys.stderr)
            return EXIT_ACCEPT_FAILED
        if summary["comparable"] == 0:
            print("验收失败：没有任何可比对场景", file=sys.stderr)
            return EXIT_ACCEPT_FAILED
        return EXIT_OK
    return EXIT_UNEXPECTED if summary["unexpected_count"] else EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
