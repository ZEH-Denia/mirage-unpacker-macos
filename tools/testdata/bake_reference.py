#!/usr/bin/env python3
"""用 Mirage 自带离线场景渲染器（SceneBaker）生成可复核的引擎参考帧。

设计要点（对应渲染审查问题 2、3）：

* 参考帧由引擎**无损**离屏帧转储直接得到：给 SceneBaker 设 ``SCENERENDERER_DUMP_FRAME``，
  引擎把结果图像按 PPM(P6, 8bit RGB) 写出，不经过 H.264/MP4，也没有解码步骤。
* 参考视图由**场景自身画布** ``general.orthogonalprojection`` 推导，规则与 PKD 静态预览
  一致：``scale = min(4, 4096 / max(w, h))``，``W = round(w*scale)``，``H = round(h*scale)``。
  不再把所有场景硬压成 4096x2304。
* 引擎请求校验要求宽高为偶数；遇到奇数尺寸只把该维度 +1 后渲染，再把多出的 1 列/行
  裁掉（**不做缩放**），并在 sidecar 里显式记为 ``parity_adjusted``。这不是“把图 resize
  后冒充几何一致”。
* sidecar（``<out>.request.json``）记录：输入 pkg 与 scene.json 哈希、画布与视图、完整请求
  参数、帧号口径、随机种子/属性/音频/fillMode、引擎/工具版本与 SHA、运行返回码与日志、
  以及（可选）MP4 中转路径的 codec/pix_fmt/color 元数据与量化后的编码/色彩转换误差。
* 默认保留参考 PNG 与 sidecar；只清理本次自己创建的临时工作目录。

用法：
    python3 tools/testdata/bake_reference.py <scene.pkg> <out.png> [宽 高] [--cross-check]

环境变量：
    MIRAGE_APP   Mirage 应用路径（默认 /Applications/Mirage.app）
    FPS         烘焙帧率（默认 24；SceneBaker 只接受 24/30/60）
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import plistlib
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
import pkg_ablate  # noqa: E402  （只复用只读的 PKGV 解析）

APP = Path(os.environ.get("MIRAGE_APP", "/Applications/Mirage.app"))
BAKER = APP / "Contents/Resources/Renderers/SceneBaker"
ASSETS = APP / "Contents/Extensions/MirageWallpaperExtension.appex/Contents/Resources/assets"
FFMPEG_FALLBACK = APP / "Contents/Resources/SceneMobileTools/ffmpeg"
DEFAULT_FPS = int(os.environ.get("FPS", "24"))
WORK_BASE = REPO / "app" / ".build" / "bake-work"

_assets_manifest_cache: Optional[Dict[str, object]] = None


def sha256_file(path: os.PathLike) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_tree(root: os.PathLike) -> Dict[str, object]:
    """目录清单哈希：路径排序后把相对路径+文件哈希再摘要一次。"""
    root = Path(root)
    files = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            path = Path(dirpath) / name
            if path.is_symlink() or not path.is_file():
                continue
            files.append((str(path.relative_to(root)), sha256_file(path)))
    digest = hashlib.sha256()
    for relative, file_hash in files:
        digest.update(f"{relative}\0{file_hash}\n".encode())
    return {"file_count": len(files), "sha256": digest.hexdigest()}


def _round_half_away(value: float) -> int:
    # 与 Swift `.rounded()` 一致：.5 远离 0，而不是 Python 的银行家舍入。
    return int(math.floor(value + 0.5)) if value >= 0 else -int(math.floor(-value + 0.5))


def scene_canvas(scene: dict) -> Tuple[int, int]:
    try:
        projection = scene["general"]["orthogonalprojection"]
        width, height = int(projection["width"]), int(projection["height"])
    except (KeyError, TypeError, ValueError) as error:
        raise SystemExit(f"scene.json 缺少可用的 general.orthogonalprojection：{error}")
    if not (1 <= width <= 8192 and 1 <= height <= 8192):
        raise SystemExit(f"画布尺寸越界：{width}x{height}")
    return width, height


def scene_from_pkg(package: os.PathLike) -> Tuple[dict, str]:
    magic, entries = pkg_ablate.read_pkg(package)
    table = {name: data for name, data in entries}
    if "scene.json" not in table:
        raise SystemExit("包里没有 scene.json")
    raw = table["scene.json"]
    try:
        scene = json.loads(raw)
    except ValueError as error:
        raise SystemExit(f"scene.json 解析失败：{error}")
    if not isinstance(scene, dict):
        raise SystemExit("scene.json 顶层不是对象")
    return scene, hashlib.sha256(raw).hexdigest()


def derived_viewport(canvas: Tuple[int, int]) -> Tuple[int, int, dict]:
    width, height = canvas
    scale = min(4.0, 4096.0 / float(max(width, height)))
    out_w = max(1, _round_half_away(width * scale))
    out_h = max(1, _round_half_away(height * scale))
    return out_w, out_h, {"scale": scale, "rule": "round(canvas * min(4, 4096/max(w,h)))"}


def _bake_viewport(width: int, height: int) -> Tuple[int, int, Optional[Dict[str, int]]]:
    """引擎要求 128..4096 且偶数：必要时把奇数维度 +1，并记录裁剪量。"""
    adjusted: Dict[str, int] = {}
    bake_w, bake_h = width, height
    if bake_w % 2:
        bake_w += 1
        adjusted["width"] = 1
    if bake_h % 2:
        bake_h += 1
        adjusted["height"] = 1
    if not (128 <= bake_w <= 4096 and 128 <= bake_h <= 4096):
        raise SystemExit(
            f"引擎视图范围只接受 128..4096：请求 {width}x{height}（偶数化后 {bake_w}x{bake_h}）"
        )
    return bake_w, bake_h, (adjusted or None)


def _mirage_version() -> Optional[str]:
    info = APP / "Contents/Info.plist"
    try:
        with open(info, "rb") as handle:
            return str(plistlib.load(handle).get("CFBundleShortVersionString"))
    except (OSError, ValueError, plistlib.InvalidFileException):
        return None


def _tool_path(name: str) -> Optional[str]:
    found = shutil.which(name)
    if found:
        return found
    candidate = APP / "Contents/Resources/SceneMobileTools" / name
    return str(candidate) if candidate.is_file() else None


def _tool_version(path: Optional[str], args: List[str]) -> Optional[str]:
    if not path:
        return None
    try:
        proc = subprocess.run([path] + args, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None
    text = (proc.stdout or proc.stderr or "").strip().splitlines()
    return text[0] if text else None


def _parse_ppm(path: Path) -> Tuple[int, int, bytes]:
    data = path.read_bytes()
    if not data.startswith(b"P6"):
        raise SystemExit(f"引擎帧转储不是 P6 PPM：{path}（前 8 字节 {data[:8]!r}）")
    parts = data.split(b"\n", 3)
    if len(parts) != 4:
        raise SystemExit(f"PPM 头不完整：{path}")
    try:
        width, height = (int(value) for value in parts[1].split())
    except ValueError:
        raise SystemExit(f"PPM 尺寸不可解析：{path}")
    if parts[2].strip() != b"255":
        raise SystemExit(f"PPM 不是 8bit：{parts[2]!r}")
    pixels = parts[3]
    if len(pixels) != width * height * 3:
        raise SystemExit(f"PPM 像素长度不符：{len(pixels)} != {width * height * 3}")
    return width, height, pixels


def _ppm_to_image(pixels: bytes, width: int, height: int):
    from PIL import Image

    return Image.frombytes("RGB", (width, height), pixels)


def _read_baker_events(text: str) -> Dict[str, object]:
    events: List[dict] = []
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict):
            events.append(value)
    errors = [event for event in events if event.get("event") == "error"]
    complete = any(event.get("event") == "complete" for event in events)
    return {"events": events, "errors": errors, "complete": complete}


def _diff_metrics(a, b) -> Dict[str, object]:
    import numpy as np

    left = np.asarray(a, dtype=np.int16)
    right = np.asarray(b, dtype=np.int16)
    if left.shape != right.shape:
        return {"comparable": False, "left_shape": list(left.shape), "right_shape": list(right.shape)}
    diff = np.abs(left - right)
    channel = (left - right).reshape(-1, 3).mean(axis=0)
    return {
        "comparable": True,
        "mean_abs": round(float(diff.mean()), 4),
        "gt16_pct": round(float((diff.max(axis=2) > 16).mean() * 100), 4),
        "gt64_pct": round(float((diff.max(axis=2) > 64).mean() * 100), 4),
        "signed_channel_mean": [round(float(value), 4) for value in channel],
    }


def _flat_region_metrics(reference, decoded) -> Dict[str, object]:
    """纯色/几何区域上的编码+色彩转换偏差（用低梯度像素近似）。"""
    import numpy as np

    left = np.asarray(reference, dtype=np.int16)
    right = np.asarray(decoded, dtype=np.int16)
    if left.shape != right.shape:
        return {"available": False, "reason": "shape_mismatch"}
    gx = np.abs(np.diff(left, axis=1)).max(axis=2)
    gy = np.abs(np.diff(left, axis=0)).max(axis=2)
    flat = np.zeros(left.shape[:2], dtype=bool)
    flat[:, :-1] |= gx <= 2
    flat[:-1, :] |= gy <= 2
    # 只保留横竖都平坦的内部像素。
    flat &= np.roll(flat, 1, axis=1) & np.roll(flat, 1, axis=0)
    count = int(flat.sum())
    if count < 1000:
        return {"available": False, "reason": "too_few_flat_pixels", "flat_pixels": count}
    delta = (left.astype(np.float32) - right.astype(np.float32))[flat]
    return {
        "available": True,
        "flat_pixels": count,
        "flat_pixel_pct": round(count / float(flat.size) * 100, 3),
        "mean_abs": round(float(np.abs(delta).mean()), 4),
        "signed_channel_mean": [round(float(value), 4) for value in delta.mean(axis=0)],
    }


def _probe_video(path: Path) -> Dict[str, object]:
    ffprobe = _tool_path("ffprobe")
    if not ffprobe:
        return {"available": False, "reason": "ffprobe_not_found"}
    try:
        proc = subprocess.run(
            [ffprobe, "-v", "error", "-select_streams", "v:0", "-show_streams", "-show_format",
             "-of", "json", str(path)],
            capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"available": False, "reason": f"ffprobe_failed: {error}"}
    try:
        payload = json.loads(proc.stdout or "{}")
    except ValueError:
        return {"available": False, "reason": "ffprobe_output_not_json"}
    streams = payload.get("streams") or []
    if not streams:
        return {"available": False, "reason": "no_video_stream"}
    stream = streams[0]
    keep = ("codec_name", "profile", "pix_fmt", "color_range", "color_space",
            "color_transfer", "color_primaries", "width", "height", "r_frame_rate",
            "avg_frame_rate", "nb_frames", "bit_rate", "duration")
    info = {key: stream.get(key) for key in keep}
    info["available"] = True
    info["format"] = (payload.get("format") or {}).get("format_name")
    info["ffprobe"] = ffprobe
    info["ffprobe_version"] = _tool_version(ffprobe, ["-version"])
    return info


def _decode_frames(video: Path, indices: List[int], width: int, height: int) -> List[object]:
    import numpy as np
    from PIL import Image

    ffmpeg = shutil.which("ffmpeg") or _tool_path("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("ffmpeg 不可用，无法解码 MP4 交叉核对")
    expression = "+".join(f"eq(n\\,{index})" for index in indices)
    proc = subprocess.run(
        [ffmpeg, "-v", "error", "-i", str(video), "-vf", f"select={expression}",
         "-fps_mode", "passthrough", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
        capture_output=True, timeout=300)
    if proc.returncode != 0:
        raise RuntimeError(f"ffmpeg 解码失败：{proc.stderr[-400:]}")
    frame_bytes = width * height * 3
    count = len(proc.stdout) // frame_bytes
    if count != len(indices):
        raise RuntimeError(f"解码帧数不符：期望 {len(indices)}，实际 {count}")
    frames = []
    for index in range(count):
        chunk = proc.stdout[index * frame_bytes:(index + 1) * frame_bytes]
        frames.append(Image.frombytes("RGB", (width, height), chunk))
    return frames


def _run_baker(request: dict, work: Path, *, dump_path: Optional[Path], timeout: int = 300) -> Dict[str, object]:
    request_path = work / f"request-{int(time.time() * 1000)}.json"
    request_path.write_text(json.dumps(request, ensure_ascii=False, indent=1))
    env = dict(os.environ)
    env.pop("SCENERENDERER_DUMP_FRAME_AT", None)
    if dump_path is not None:
        env["SCENERENDERER_DUMP_FRAME"] = str(dump_path)
    else:
        env.pop("SCENERENDERER_DUMP_FRAME", None)
    started = time.time()
    try:
        proc = subprocess.run([str(BAKER), str(request_path)], cwd=str(work), env=env,
                              capture_output=True, text=True, timeout=timeout)
        timed_out = False
        returncode, stdout, stderr = proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired as failure:
        timed_out = True
        returncode = None
        stdout = failure.stdout.decode("utf-8", "replace") if isinstance(failure.stdout, bytes) else (failure.stdout or "")
        stderr = failure.stderr.decode("utf-8", "replace") if isinstance(failure.stderr, bytes) else (failure.stderr or "")
    return {
        "returncode": returncode,
        "timed_out": timed_out,
        "seconds": round(time.time() - started, 3),
        "stdout": stdout,
        "stderr": stderr,
        "events": _read_baker_events(stdout),
        "request_path": str(request_path),
    }


def bake(
    package: os.PathLike,
    out_png: os.PathLike,
    width: Optional[int] = None,
    height: Optional[int] = None,
    *,
    fps: int = DEFAULT_FPS,
    cross_check: bool = False,
    force: bool = False,
    keep_work: bool = False,
    assets_manifest: Optional[Dict[str, object]] = None,
) -> Dict[str, object]:
    """生成一张引擎参考帧，返回 sidecar 字典；同时写出 ``<out>.request.json`` 与 ``<out>.log``。"""
    package = Path(package).resolve()
    out_png = Path(out_png).resolve()
    if not package.is_file():
        raise SystemExit(f"缺少场景包：{package}")
    if not BAKER.is_file():
        raise SystemExit(f"缺少 SceneBaker：{BAKER}")
    if not ASSETS.is_dir():
        raise SystemExit(f"缺少引擎 assets：{ASSETS}")
    if fps not in (24, 30, 60):
        raise SystemExit(f"SceneBaker 只接受 24/30/60 fps，收到 {fps}")
    # 输出路径同样走安全策略：拒绝根/家目录/仓库源码树等受保护位置；目录允许创建。
    out_parent = safety.ensure_directory(out_png.parent, what="参考输出目录", create=True)
    out_png = out_parent / out_png.name
    sidecar_path = Path(str(out_png) + ".request.json")
    log_path = Path(str(out_png) + ".log")
    existing = [path for path in (out_png, sidecar_path, log_path) if path.exists()]
    if existing and not force:
        raise SystemExit(f"参考/ sidecar / 日志已存在，拒绝覆盖（--force 才覆盖）：{[str(path) for path in existing]}")

    scene, scene_sha = scene_from_pkg(package)
    canvas = scene_canvas(scene)
    if width is None or height is None:
        width, height, derivation = derived_viewport(canvas)
    else:
        width, height = int(width), int(height)
        derivation = {"scale": None, "rule": "caller_specified"}
    bake_w, bake_h, parity = _bake_viewport(width, height)
    crop = {"left": 0, "top": 0, "width": width, "height": height}

    work_owner = safety.OwnedRunDir(WORK_BASE, "bake-reference", purpose=f"参考帧 {package.name}")
    work = work_owner.path
    try:
        request = {
            "schema": 1,
            "source": str(package),
            "directory": str(package.parent),
            "overlays": [],
            "assets": str(ASSETS),
            "cache": str(work / "cache"),
            "output": str(work / "ref.mp4"),
            "properties": {},
            "storage": {},
            "width": bake_w,
            "height": bake_h,
            "fps": fps,
            "duration": 1,
            "warmup": 0,
            "speed": 1.0,
            "seed": 0,
            "fillMode": "stretch",
            "positionX": 0.0,
            "positionY": 0.0,
            "volume": 0.0,
            "audio": False,
            "quality": "standard",
        }
        (work / "cache").mkdir()
        ppm = work / "frame.ppm"
        run = _run_baker(request, work, dump_path=ppm)
        if not ppm.is_file():
            (out_png.parent / (out_png.name + ".failed.log")).write_text(
                f"returncode={run['returncode']}\n--- stdout ---\n{run['stdout']}\n--- stderr ---\n{run['stderr']}\n")
            raise SystemExit(
                f"引擎没有产出帧转储（rc={run['returncode']}，事件 {run['events']['errors']}）；"
                f"日志：{out_png.parent / (out_png.name + '.failed.log')}"
            )
        ppm_w, ppm_h, pixels = _parse_ppm(ppm)
        if (ppm_w, ppm_h) != (bake_w, bake_h):
            raise SystemExit(f"帧转储尺寸不符：{ppm_w}x{ppm_h} != {bake_w}x{bake_h}")
        ppm_sha = sha256_file(ppm)
        ppm_bytes = ppm.stat().st_size
        full_image = _ppm_to_image(pixels, ppm_w, ppm_h)
        image = full_image.crop((0, 0, width, height)) if parity is not None else full_image

        out_png.parent.mkdir(parents=True, exist_ok=True)
        image.save(out_png, format="PNG")
        png_sha = sha256_file(out_png)

        cross: Optional[Dict[str, object]] = None
        if cross_check:
            cross = _cross_check_mp4(package, request, work, ppm, full_image, bake_w, bake_h, fps)

        sidecar = {
            "schema": 2,
            "tool": {
                "name": "bake_reference.py",
                "sha256": sha256_file(Path(__file__).resolve()),
                "argv": sys.argv,
                "python": sys.version.split()[0],
            },
            "created_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "host": {
                "platform": sys.platform,
                "machine": os.uname().machine if hasattr(os, "uname") else None,
            },
            "engine": {
                "renderer": str(BAKER),
                "renderer_sha256": sha256_file(BAKER),
                "mirage_app": str(APP),
                "mirage_version": _mirage_version(),
                "assets": str(ASSETS),
                "assets_manifest": assets_manifest,
            },
            "input": {
                "package": str(package),
                "package_sha256": sha256_file(package),
                "package_bytes": package.stat().st_size,
                "scene_json_sha256": scene_sha,
                "project_json_sha256": (
                    sha256_file(package.parent / "project.json")
                    if (package.parent / "project.json").is_file() else None
                ),
            },
            "scene": {"canvas": {"width": canvas[0], "height": canvas[1]},
                      "canvas_source": "scene.json general.orthogonalprojection"},
            "viewport": {
                "requested": {"width": width, "height": height},
                "baked": {"width": bake_w, "height": bake_h},
                "derivation": derivation,
                "parity_adjusted": parity,
                "crop_to_requested": crop if parity else None,
                "fps": fps,
                "fill_mode": "stretch",
            },
            "request": request,
            "frame_semantics": {
                "dump_env": "SCENERENDERER_DUMP_FRAME",
                "dump_index_env": "SCENERENDERER_DUMP_FRAME_AT（实测在 SceneBaker 下不改变结果，dump 恒为首帧）",
                "claim": "引擎渲染循环中第一帧的结果图像（warmup=0，请求帧时间 t=0）；由引擎直接写 PPM，不经 MP4 解码",
                "not_claimed": "不等于完整播放器任意时刻画面；不解码 MP4 第 0 帧冒充 t=0；不执行脚本/音频响应",
                "mp4_is_only_cross_check": True,
            },
            "dump": {
                "ppm_sha256": ppm_sha,
                "ppm_bytes": ppm_bytes,
                "png_sha256": png_sha,
                "png_bytes": out_png.stat().st_size,
                "png_size": [image.size[0], image.size[1]],
                "png_is_lossless_conversion_of_ppm": True,
            },
            "engine_run": {
                "returncode": run["returncode"],
                "timed_out": run["timed_out"],
                "seconds": run["seconds"],
                "events": run["events"],
                "note": "dump 模式下引擎在写出首帧后仍会尝试 MP4 编码并失败；首帧转储已完整写出，"
                        "返回码与事件原样记录，不当作渲染失败掩盖。",
            },
            "logs": {
                "file": str(out_png) + ".log",
                "stdout_tail": run["stdout"][-4000:],
                "stderr_tail": run["stderr"][-4000:],
            },
            "mp4_cross_check": cross,
        }
        sidecar_path.write_text(json.dumps(sidecar, ensure_ascii=False, indent=1) + "\n")
        log_path.write_text(
            f"# dump run rc={run['returncode']}\n--- stdout ---\n{run['stdout']}\n--- stderr ---\n{run['stderr']}\n"
            + (f"\n# cross-check\n{json.dumps(cross['run'], ensure_ascii=False, indent=1)}\n" if cross and cross.get('run') else ""))
        return sidecar
    finally:
        if keep_work:
            print(f"工作目录保留：{work}", file=sys.stderr)
        else:
            try:
                work_owner.cleanup()
            except safety.ToolSafetyError as error:
                print(f"警告：临时工作目录未清理（{error}）：{work}", file=sys.stderr)


def _cross_check_mp4(package: Path, request: dict, work: Path, ppm: Path, image,
                     bake_w: int, bake_h: int, fps: int) -> Dict[str, object]:
    cross_request = dict(request)
    cross_request["output"] = str(work / "cross.mp4")
    run = _run_baker(cross_request, work, dump_path=None)
    video = Path(cross_request["output"])
    result: Dict[str, object] = {"run": {k: run[k] for k in ("returncode", "timed_out", "seconds")},
                                 "video_available": video.is_file()}
    if not video.is_file():
        result["run"]["events"] = run["events"]
        result["run"]["stderr_tail"] = run["stderr"][-2000:]
        result["conclusion"] = "MP4 中转不可用（引擎编码失败）；本参考仍是无损帧转储"
        return result

    info = _probe_video(video)
    result["video"] = info
    result["video_bytes"] = video.stat().st_size
    frames = int(round(fps * 1))
    indices = [0, min(1, frames - 1), frames - 1]
    try:
        decoded = _decode_frames(video, indices, bake_w, bake_h)
    except RuntimeError as error:
        result["decode_error"] = str(error)
        return result
    reference = image
    metrics = {}
    for index, frame in zip(indices, decoded):
        metrics[f"frame_{index}"] = _diff_metrics(reference, frame)
    best = min(metrics, key=lambda key: metrics[key].get("mean_abs", float("inf")))
    result["dump_vs_decoded"] = metrics
    result["best_match_by_mean_abs"] = best
    if len(decoded) >= 2:
        result["decoded_temporal_frame0_vs_frame1"] = _diff_metrics(decoded[0], decoded[1])
    result["flat_region"] = _flat_region_metrics(reference, decoded[0])
    result["conclusion"] = (
        "MP4 中转误差：dump（无损）与同帧 MP4 解码结果之间的差包含 H.264 量化/yuv420p 色度"
        "抽样与颜色转换，量级大于“第 0 帧 vs 第 1 帧”的时间差，因此不能用 MP4 解码反推精确"
        "帧号；这里只用它量化编码与色彩转换偏差，帧号语义以引擎转储实现为准（首帧）。"
    )
    return result


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="用 SceneBaker 生成可复核的引擎参考帧（无损帧转储）")
    parser.add_argument("package", help="scene.pkg 路径")
    parser.add_argument("output", help="输出 PNG 路径")
    parser.add_argument("width", nargs="?", type=int, help="可选：输出宽（默认按场景画布推导）")
    parser.add_argument("height", nargs="?", type=int, help="可选：输出高（默认按场景画布推导）")
    parser.add_argument("--fps", type=int, default=DEFAULT_FPS)
    parser.add_argument("--cross-check", action="store_true", help="额外跑一次 MP4，量化编码/色彩转换误差")
    parser.add_argument("--force", action="store_true", help="允许覆盖既有参考")
    parser.add_argument("--keep-work", action="store_true", help="保留临时工作目录")
    args = parser.parse_args(argv)

    try:
        sidecar = bake(args.package, args.output, args.width, args.height,
                       fps=args.fps, cross_check=args.cross_check,
                       force=args.force, keep_work=args.keep_work)
    except safety.ToolSafetyError as error:
        print(f"安全拒绝：{error}", file=sys.stderr)
        return safety.EXIT_UNSAFE
    except SystemExit as error:
        print(error, file=sys.stderr)
        return 1
    print(json.dumps({
        "png": str(Path(args.output).resolve()),
        "viewport": sidecar["viewport"]["baked"],
        "parity_adjusted": sidecar["viewport"]["parity_adjusted"],
        "engine_returncode": sidecar["engine_run"]["returncode"],
        "cross_check": bool(sidecar["mp4_cross_check"]),
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
