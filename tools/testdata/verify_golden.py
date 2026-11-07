#!/usr/bin/env python3
"""用独立的解析预期校验 PKD 的静态场景组合输出。

预期值由场景 JSON 的语义手算（纯色叠加、45° 旋转的几何边界、父子变换的坐标换算、
不透明度百分比），不读取 PKD 的实现结果，因此不是"拿实现输出当基线"。

安全目录策略（渲染审查问题 5）：不再对调用者传入的目录做 ``shutil.rmtree``。每次运行都在
``<base>/golden-verify-<时间>-<随机>`` 这一专属子目录里生成场景，目录带归属标记；默认保留
运行目录便于取证，只有显式 ``--clean`` 才清理本工具留下的旧运行目录（校验标记后才删）。

用法：
    python3 tools/testdata/verify_golden.py [base 目录] [--clean] [--keep-run]
需要先构建 app/.build/debug/pkd-selftest。
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))

import evidence_tool_safety as safety  # noqa: E402

SELFTEST = REPO / "app/.build/debug/pkd-selftest"
GENERATOR = REPO / "tools/testdata/make_golden_scenes.py"
DEFAULT_BASE = REPO / "app/.build/golden-verify"
TOOL = "golden-verify"
CANVAS = (800, 640)
SCALE = 4  # 小画布放大 4 倍：4096/800 > 4

failures = []
checks = 0


def check(condition, message):
    global checks
    checks += 1
    if not condition:
        failures.append(message)


def pixel(px, cx, cy):
    """场景坐标（左下原点）→ 图像坐标。"""
    x = int(cx * SCALE)
    y = int((CANVAS[1] - cy) * SCALE)
    return px[x, y]


def expected_report(label, note):
    print(f"  · {label}: {note}")


def prepare_run_dir(base: Path, *, clean: bool) -> safety.OwnedRunDir:
    """校验 base、按需清理自己的旧 run、创建本次专属 run 目录。"""
    base = safety.ensure_directory(base, what="金标准输出基准目录", create=True)
    if clean:
        removed = safety.clean_owned_runs(base, TOOL)
        for path in removed:
            print(f"已清理本工具旧运行目录：{path}")
    return safety.OwnedRunDir(base, TOOL, purpose="合成金标准像素回归")


def run_checks(workdir: Path) -> int:
    import subprocess

    subprocess.run([sys.executable, str(GENERATOR), str(workdir)], check=True,
                   stdout=subprocess.DEVNULL)
    if not SELFTEST.is_file():
        raise SystemExit(f"缺少 {SELFTEST}，请先构建")

    def render(name):
        scene_dir = workdir / name
        proc = subprocess.run([str(SELFTEST), "--render-directory", str(scene_dir)],
                              capture_output=True, text=True)
        check(proc.returncode == 0, f"{name}: 渲染应成功（{proc.stdout.strip()[:80]}）")
        output = scene_dir / "场景预览-实验.png"
        check(output.is_file(), f"{name}: 应生成预览文件")
        if not output.is_file():
            return None
        image = Image.open(output).convert("RGB")
        check(image.size == (CANVAS[0] * SCALE, CANVAS[1] * SCALE),
              f"{name}: 输出尺寸应为 {CANVAS[0] * SCALE}x{CANVAS[1] * SCALE}，实际 {image.size}")
        return image.load()

    def near(actual, expected, message, tolerance=8):
        check(all(abs(a - e) <= tolerance for a, e in zip(actual, expected)),
              f"{message}（期望 {expected}，实际 {actual}）")

    # 1) 内建纯色层：flat 语义 = vec4(color, alpha) 叠加在灰色背景上
    px = render("solid")
    if px:
        near(pixel(px, 400, 320), (160, 32, 32), "solid: 红色纯色层 50% 叠加灰底")
        near(pixel(px, 100, 100), (64, 64, 64), "solid: 纯色层外仍为背景")
        expected_report("solid", "g_Color=(1,0,0), g_Alpha=0.5 over (64,64,64)")

    # 2) 45°（0.78540 弧度）+ 绿色色调 + 50% 不透明度
    px = render("flat")
    if px:
        near(pixel(px, 400, 320), (0, 127, 0), "flat: 中心应为 50% 绿色")
        near(pixel(px, 520, 320), (0, 127, 0), "flat: +X 120 仍在 45° 方形内")
        near(pixel(px, 400, 440), (0, 127, 0), "flat: +Y 120 仍在 45° 方形内")
        near(pixel(px, 580, 500), (0, 0, 0), "flat: 对角外侧应为背景")
        expected_report("flat", "half=100, 45° → 轴向外沿 141.4")

    # 3) 父子变换：父 (300,300) 90°/0.5 缩放，子偏移 (100,0)
    px = render("parent")
    if px:
        near(pixel(px, 300, 350), (255, 255, 255), "parent: 子层中心应在 (300,350)")
        near(pixel(px, 320, 350), (255, 255, 255), "parent: 子层 50×50 范围内")
        near(pixel(px, 300, 320), (0, 0, 0), "parent: 子层上方 30px 应为背景")
        near(pixel(px, 300, 400), (0, 0, 0), "parent: 子层下方 50px 应为背景")
        expected_report("parent", "world = parent + R90·(S0.5·childOffset)")

    # 4) puppet 网格静态姿态
    px = render("puppet")
    if px:
        near(pixel(px, 400, 320), (255, 0, 0), "puppet: 网格中心应为红色")
        near(pixel(px, 400, 200), (0, 0, 255), "puppet: 网格外 120px 应为背景")
        expected_report("puppet", "200×200 MDLV 四边形")

    # 5) 百分比与小数不透明度
    px = render("alpha")
    if px:
        near(pixel(px, 300, 320), (127, 127, 127), "alpha: 50% 白色叠加黑底")
        near(pixel(px, 500, 320), (64, 64, 64), "alpha: 25% 白色叠加黑底")
        near(pixel(px, 150, 320), (0, 0, 0), "alpha: 两层之外应为背景")
        expected_report("alpha", "alpha 50 → 0.5；alpha 0.25")

    print(f"{'✅ 全部通过' if not failures else '❌ 有失败'}（{checks} 项断言）")
    for failure in failures:
        print("  FAIL", failure)
    return 1 if failures else 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="合成金标准像素回归（安全专属目录）")
    parser.add_argument("base", nargs="?", default=str(DEFAULT_BASE),
                        help="输出基准目录（默认 app/.build/golden-verify；每次运行在其下建专属子目录）")
    parser.add_argument("--clean", action="store_true", help="先清理本工具自己的旧运行目录（校验归属标记）")
    parser.add_argument("--discard-run", action="store_true",
                        help="结束后删除本次运行目录（默认保留便于取证）")
    args = parser.parse_args(argv)

    try:
        owner = prepare_run_dir(Path(args.base).resolve(), clean=args.clean)
    except safety.ToolSafetyError as error:
        print(f"安全拒绝：{error}", file=sys.stderr)
        return safety.EXIT_UNSAFE

    workdir = owner.path
    print(f"本次运行目录：{workdir}")
    try:
        code = run_checks(workdir)
    except SystemExit as error:
        print(error, file=sys.stderr)
        code = 1
    except Exception as error:  # 保留目录供取证，不掩盖失败
        print(f"运行异常：{type(error).__name__}: {error}", file=sys.stderr)
        code = 1
    if args.discard_run:
        owner.cleanup()
        print("已清理本次运行目录")
    return code


if __name__ == "__main__":
    sys.exit(main())
