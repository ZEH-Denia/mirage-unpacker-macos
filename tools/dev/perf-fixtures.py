#!/usr/bin/env python3
"""Generate a large, fully synthetic "neutral card" library for UI QA.

Only writes generated placeholder art (flat gradients + a caption-free colour
field) into the caller-supplied root. No personal wallpapers, no source packs,
no network. Deterministic for a given --seed/--count so before/after runs are
comparable.

Layout matches what the app scans:

    <root>/Library/<id>/{project.json, preview.png|preview.jpg, scene.pkg}
    <root>/{Logs,History,Cache,Images,Extracted}

Usage:
    python3 tools/dev/perf-fixtures.py --root app/.build/ui-qa/data/library-400 --count 400
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import random
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

sys.dont_write_bytecode = True

REPO = Path(__file__).resolve().parents[2]


def _load_test_pkg():
    spec = importlib.util.spec_from_file_location(
        "fixture_pkg", REPO / "tools/testdata/make_test_pkg.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _png(width: int, height: int, colour) -> bytes:
    rows = bytearray()
    for y in range(height):
        rows.append(0)  # filter type 0
        for x in range(width):
            rows.extend(colour(x, y))
    def chunk(kind: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        )
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(rows), 6))
        + chunk(b"IEND", b"")
    )


def _upscale(source: Path, destination: Path, width: int, height: int) -> None:
    result = subprocess.run(
        ["sips", "-z", str(height), str(width), str(source), "--out", str(destination)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise SystemExit(f"sips failed for {destination}: {result.stderr.strip()}")


def _neutral_colour(seed: int):
    base_r = 40 + seed * 37 % 120
    base_g = 60 + seed * 53 % 120
    base_b = 90 + seed * 71 % 120

    def colour(x: int, y: int):
        return (
            (base_r + x // 24) % 256,
            (base_g + y // 24) % 256,
            (base_b + (x + y) // 40) % 256,
        )

    return colour


TITLE_POOL = [
    "中性占位 · 场景 {n:04d}",
    "Synthetic Placeholder {n:04d}",
    "抽象渐变占位 {n:04d}（不含真实素材）",
    "很长很长很长很长很长很长很长很长很长的占位标题 {n:04d}",
    "QA Neutral Card {n:04d}",
]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--count", type=int, default=400)
    parser.add_argument("--seed", type=int, default=20261106)
    parser.add_argument("--start-id", type=int, default=900000)
    parser.add_argument("--force", action="store_true", help="replace an existing library")
    args = parser.parse_args()

    root = args.root.resolve()
    if root.exists():
        if not args.force:
            raise SystemExit(f"refusing to overwrite existing root {root} (use --force)")
        shutil.rmtree(root)
    root.mkdir(parents=True)

    pkg_module = _load_test_pkg()
    rng = random.Random(args.seed)

    library = root / "Library"
    library.mkdir()
    for name in ("Logs", "History", "Cache", "Images", "Extracted"):
        (root / name).mkdir()

    # A handful of oversized previews force the downsampling path in
    # ThumbnailLoader without generating megabytes of art for every card.
    large_ids = set(rng.sample(range(args.count), k=min(6, args.count)))
    medium_ids = set(rng.sample(range(args.count), k=min(40, args.count)))
    # A few scene cards without a pack exercise the non-extractable card state.
    no_pkg_ids = set(rng.sample(range(args.count), k=max(1, args.count // 25)))

    small_png = _png(320, 180, _neutral_colour(args.seed))
    with tempfile.TemporaryDirectory(prefix="perf-fixture-", dir=root) as scratch:
        scratch_path = Path(scratch)
        base = scratch_path / "base.png"
        base.write_bytes(small_png)

        for index in range(args.count):
            folder = library / str(args.start_id + index)
            folder.mkdir()
            title = TITLE_POOL[index % len(TITLE_POOL)].format(n=index + 1)

            if index in large_ids:
                preview_name = "preview.jpg"
                _upscale(base, folder / preview_name, 2560, 1440)
            elif index in medium_ids:
                preview_name = "preview.jpg"
                _upscale(base, folder / preview_name, 1280, 720)
            else:
                preview_name = "preview.png"
                (folder / preview_name).write_bytes(
                    _png(640, 360, _neutral_colour(args.seed + index))
                )

            project = {
                "title": title,
                "type": "scene",
                "preview": preview_name,
                "contentRating": "Everyone" if index % 7 else "Questionable",
                "tags": ["placeholder", "qa"] if index % 3 else ["placeholder"],
            }
            (folder / "project.json").write_text(
                json.dumps(project, ensure_ascii=False), encoding="utf-8"
            )

            if index not in no_pkg_ids:
                entries = [
                    ("scene.json", b'{"objects":[]}'),
                    ("materials/placeholder.tex", pkg_module.build_tex(64, 64)),
                ]
                if index % 11 == 0:
                    entries.append(("materials/second.tex", pkg_module.build_tex(32, 32)))
                if index % 13 == 0:
                    entries.append(("models/placeholder_puppet.mdl", b"synthetic model"))
                (folder / "scene.pkg").write_bytes(pkg_module.build_pkg(entries))

    summary = {
        "root": str(root),
        "count": args.count,
        "startId": args.start_id,
        "seed": args.seed,
        "largePreviews": sorted(args.start_id + i for i in large_ids),
        "mediumPreviews": sorted(args.start_id + i for i in medium_ids),
        "withoutPackage": sorted(args.start_id + i for i in no_pkg_ids),
    }
    (root / "fixtures.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps({"root": str(root), "count": args.count,
                      "large": len(large_ids), "medium": len(medium_ids),
                      "noPkg": len(no_pkg_ids)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
