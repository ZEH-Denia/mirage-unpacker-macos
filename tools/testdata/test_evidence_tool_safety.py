#!/usr/bin/env python3
"""证据/测试工具的安全目录策略回归（独立 fixtures，不碰真实素材）。

覆盖：
* 受保护路径（根、家目录、仓库、/Users、/tmp）与相对路径拒绝；
* 专属 run 目录唯一、带归属标记；清理只删本次 run，且拒绝无标记/篡改标记/符号链接/越界；
* --clean 只清理本工具自己的历史 run，跳过其它目录与符号链接；
* 非空调用者目录拒绝混入且哨兵文件保持不变；
* 命令行工具的失败返回码：危险目标返回 3，非法混入返回 2，且哨兵仍在；
* 工具源码里不再直接 ``shutil.rmtree`` 调用者目录；
* 矩阵分类与 bake 视图推导的纯函数断言。
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))

import evidence_tool_safety as safety  # noqa: E402
import pkg_ablate  # noqa: E402
import scene_matrix_report  # noqa: E402


def _sentinel(root: Path, name: str = "sentinel", content: str = "do not delete") -> Path:
    path = root / name
    path.mkdir(parents=True, exist_ok=True)
    (path / "keep.txt").write_text(content)
    return path


class SafetyModuleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="evidence-tool-safety-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.base = self.tmp / "base"
        self.base.mkdir()

    def test_protected_paths_are_rejected(self):
        cases = [Path("/"), Path.home(), REPO, Path("/Users"), Path("/tmp"), Path("/Applications")]
        for path in cases:
            with self.subTest(path=str(path)):
                with self.assertRaises(safety.ToolSafetyError):
                    safety.ensure_directory(path, what="测试", create=False)

    def test_relative_path_is_rejected(self):
        with self.assertRaises(safety.ToolSafetyError):
            safety.ensure_directory(Path("relative/dir"), what="测试", create=True)

    def test_repo_source_tree_is_rejected(self):
        with self.assertRaises(safety.ToolSafetyError):
            safety.ensure_directory(REPO / "tools" / "testdata", what="测试", create=False)

    def test_run_dir_is_unique_and_marked(self):
        first = safety.OwnedRunDir(self.base, "unit-tool", purpose="one")
        second = safety.OwnedRunDir(self.base, "unit-tool", purpose="two")
        self.assertNotEqual(first.path, second.path)
        for owner in (first, second):
            marker = safety.read_marker(owner.path)
            self.assertIsNotNone(marker)
            self.assertEqual(marker["tool"], "unit-tool")
            self.assertEqual(Path(marker["realpath"]), Path(os.path.realpath(owner.path)))
            self.assertTrue(safety.has_owned_marker(owner.path, tool="unit-tool"))
        first.cleanup()
        self.assertFalse(first.path.exists())
        self.assertTrue(second.path.exists())
        second.cleanup()

    def test_cleanup_refuses_unowned_directory(self):
        foreign = self.base / "foreign"
        foreign.mkdir()
        (foreign / "keep.txt").write_text("keep")
        with self.assertRaises(safety.ToolSafetyError):
            safety.remove_owned_run_dir(foreign, run_id="x", tool="unit-tool")
        self.assertTrue((foreign / "keep.txt").is_file())

    def test_cleanup_refuses_tampered_marker(self):
        owner = safety.OwnedRunDir(self.base, "unit-tool")
        marker_path = owner.path / safety.MARKER_NAME
        marker = json.loads(marker_path.read_text())
        marker["run_id"] = "other-run"
        marker_path.write_text(json.dumps(marker))
        with self.assertRaises(safety.ToolSafetyError):
            owner.cleanup()
        self.assertTrue(owner.path.exists())
        marker["run_id"] = owner.run_id
        marker["tool"] = "other-tool"
        marker_path.write_text(json.dumps(marker))
        with self.assertRaises(safety.ToolSafetyError):
            owner.cleanup()
        self.assertTrue(owner.path.exists())

    def test_cleanup_refuses_symlink_escape(self):
        sentinel = _sentinel(self.tmp, "sentinels")
        owner = safety.OwnedRunDir(self.base, "unit-tool")
        shutil.rmtree(owner.path)
        os.symlink(sentinel, owner.path)
        with self.assertRaises(safety.ToolSafetyError):
            safety.remove_owned_run_dir(owner.path, run_id=owner.run_id, tool="unit-tool")
        self.assertTrue((sentinel / "keep.txt").is_file())

    def test_cleanup_refuses_outside_path(self):
        sentinel = _sentinel(self.tmp, "outside")
        with self.assertRaises(safety.ToolSafetyError):
            safety.remove_owned_run_dir(self.base / ".." / "outside", run_id="x", tool="unit-tool")
        self.assertTrue((sentinel / "keep.txt").is_file())

    def test_clean_owned_runs_only_removes_marked(self):
        first = safety.OwnedRunDir(self.base, "unit-tool")
        second = safety.OwnedRunDir(self.base, "unit-tool")
        foreign = self.base / "unit-tool-not-owned"
        foreign.mkdir()
        (foreign / "keep.txt").write_text("keep")
        link = self.base / "unit-tool-symlink"
        os.symlink(foreign, link)
        removed = safety.clean_owned_runs(self.base, "unit-tool")
        self.assertEqual(sorted(path.name for path in removed),
                         sorted([first.path.name, second.path.name]))
        self.assertTrue((foreign / "keep.txt").is_file())
        self.assertTrue(link.is_symlink())

    def test_ensure_empty_or_new_rejects_nonempty(self):
        sentinel = _sentinel(self.tmp, "nonempty")
        with self.assertRaises(safety.ToolSafetyError):
            safety.ensure_empty_or_new(sentinel, what="输出目录")
        self.assertTrue((sentinel / "keep.txt").is_file())

    def test_marker_writer_refuses_existing_marker(self):
        target = self.tmp / "evidence"
        target.mkdir()
        safety.write_owner_marker(target, "unit-tool")
        with self.assertRaises(safety.ToolSafetyError):
            safety.write_owner_marker(target, "unit-tool")


class ToolSourceTests(unittest.TestCase):
    def test_tools_do_not_rmtree_caller_directories(self):
        for name in ("verify_golden.py", "pkg_ablate.py", "scene_matrix_report.py",
                     "bake_reference.py"):
            source = (HERE / name).read_text()
            self.assertNotIn("shutil.rmtree(", source,
                             f"{name} 不应直接删除目录；清理必须经 evidence_tool_safety")
            self.assertNotIn("rm -rf", source)

    def test_matrix_classification(self):
        ok_row = {"extract": {"status": "ok", "scene_json_present": True},
                  "render": {"ok": True, "output_present": True},
                  "reference": {"status": "ok"},
                  "compare": {"status": "comparable", "comparable": True}}
        self.assertEqual(scene_matrix_report.classify(ok_row), ("ok", True))

        parity_row = json.loads(json.dumps(ok_row))
        parity_row["reference"]["parity_adjusted"] = {"height": 1}
        self.assertEqual(scene_matrix_report.classify(parity_row), ("ok_parity_adjusted", True))

        texture_row = {"extract": {"status": "ok", "scene_json_present": True,
                                   "tex_without_image": {"count": 1}},
                       "render": {"ok": False, "output_present": True,
                                  "report": "❌ 静态场景预览失败"},
                       "reference": {"status": "skipped", "reason": "render_failed"},
                       "compare": {"status": "not_applicable"}}
        self.assertEqual(scene_matrix_report.classify(texture_row),
                         ("render_fallback_texture_missing", True))

        unknown_row = json.loads(json.dumps(texture_row))
        unknown_row["extract"]["tex_without_image"]["count"] = 0
        unknown_row["render"]["report"] = "❌ 静态场景预览失败"
        self.assertEqual(scene_matrix_report.classify(unknown_row), ("render_failed_other", False))

        failed_no_output = {"extract": {"status": "ok", "scene_json_present": True,
                                        "tex_without_image": {"count": 1}},
                            "render": {"ok": False, "output_present": False, "returncode": 1,
                                       "report": "❌ 静态场景预览失败：图集不存在或尺寸不匹配"},
                            "reference": {"status": "skipped", "reason": "render_failed"},
                            "compare": {"status": "not_applicable"}}
        self.assertEqual(scene_matrix_report.classify(failed_no_output),
                         ("render_fallback_texture_missing", True))

        video_texture_row = {"extract": {"status": "ok", "scene_json_present": True,
                                          "tex_without_image": {"count": 1},
                                          "video_texture_without_image": {"count": 1}},
                              "render": {"ok": False, "output_present": False, "returncode": 1,
                                        "report": "❌ 静态场景预览失败：图集不存在或尺寸不匹配"},
                              "reference": {"status": "skipped", "reason": "render_failed"},
                              "compare": {"status": "not_applicable"}}
        self.assertEqual(scene_matrix_report.classify(video_texture_row),
                         ("render_fallback_video_texture", True))

        success_but_no_output = {"extract": {"status": "ok", "scene_json_present": True},
                                 "render": {"ok": False, "output_present": False, "returncode": 0,
                                            "report": "✅ 静态场景预览已生成"},
                                 "reference": {"status": "skipped", "reason": "render_failed"},
                                 "compare": {"status": "not_applicable"}}
        self.assertEqual(scene_matrix_report.classify(success_but_no_output),
                         ("missing_render_output", False))

        shape_row = json.loads(json.dumps(ok_row))
        shape_row["compare"] = {"status": "incomparable", "comparable": False,
                                "reason": "shape_mismatch"}
        self.assertEqual(scene_matrix_report.classify(shape_row), ("incomparable_shape", False))

    def test_evaluate_only_requires_owner_marker_and_no_workshop(self):
        import contextlib
        import io

        tmp = Path(tempfile.mkdtemp(prefix="matrix-eval-owner-"))
        self.addCleanup(shutil.rmtree, tmp, True)
        (tmp / "matrix.json").write_text("[]")
        (tmp / "run-meta.json").write_text('{"started_at": "-", "workshop": "-", "keep_references": true}')
        # 有 matrix.json 但没有归属标记：必须安全拒绝（退出码 3），且不依赖 --workshop。
        proc = subprocess.run(
            [sys.executable, str(HERE / "scene_matrix_report.py"), "--out", str(tmp), "--evaluate-only"],
            capture_output=True, text=True, timeout=120)
        self.assertEqual(proc.returncode, safety.EXIT_UNSAFE, proc.stderr)
        self.assertNotIn("Traceback", proc.stderr)

    def test_extract_reuse_requires_matching_source_provenance(self):
        tmp = Path(tempfile.mkdtemp(prefix="reuse-provenance-"))
        self.addCleanup(shutil.rmtree, tmp, True)
        target = tmp / "sceneA"
        target.mkdir()
        package = HERE / "test_scene.pkg"
        _, entries = pkg_ablate.read_pkg(package)
        (target / "scene.json").write_bytes(dict(entries)["scene.json"])
        log = tmp / "repkg.log"
        pkg_sha = scene_matrix_report.sha256(package)
        missing = scene_matrix_report.extract(package, target, reuse=True, log_path=log,
                                              pkg_sha256=pkg_sha)
        self.assertEqual(missing["status"], "reuse_provenance_missing")
        (target / ".source.json").write_text(json.dumps({"package_sha256": "0" * 64}))
        mismatch = scene_matrix_report.extract(package, target, reuse=True, log_path=log,
                                               pkg_sha256=pkg_sha)
        self.assertEqual(mismatch["status"], "reuse_input_mismatch")
        (target / ".source.json").write_text(json.dumps({"package_sha256": pkg_sha}))
        reused = scene_matrix_report.extract(package, target, reuse=True, log_path=log,
                                             pkg_sha256=pkg_sha)
        self.assertEqual(reused["status"], "reused")
        self.assertTrue(reused.get("provenance_verified"))
        # 分类：无法证明来源的复用必须算未预期，不能给全绿。
        row = {"extract": {"status": "reuse_input_mismatch", "scene_json_present": True},
               "render": {"ok": True, "output_present": True},
               "reference": {"status": "ok"}, "compare": {"status": "comparable",
                                                          "comparable": True}}
        self.assertEqual(scene_matrix_report.classify(row), ("reuse_input_unverified", False))

    def test_bake_refuses_repo_source_output(self):
        import bake_reference

        with self.assertRaises(safety.ToolSafetyError):
            bake_reference.bake(HERE / "test_scene.pkg",
                                REPO / "tools" / "testdata" / "should-not-exist.png", 800, 640)
        self.assertFalse((REPO / "tools" / "testdata" / "should-not-exist.png").exists())

    def test_evaluate_only_exit_codes(self):
        import contextlib
        import io

        tmp = Path(tempfile.mkdtemp(prefix="matrix-eval-test-"))
        self.addCleanup(shutil.rmtree, tmp, True)
        (tmp / "matrix.json").write_text(json.dumps([
            {"scene": "a", "extract": {"status": "ok", "scene_json_present": True},
             "render": {"ok": True, "output_present": True},
             "reference": {"status": "ok"},
             "compare": {"status": "comparable", "comparable": True}},
            {"scene": "b", "extract": {"status": "ok", "scene_json_present": True},
             "render": {"ok": False, "output_present": False, "returncode": 1,
                        "report": "❌ 静态场景预览失败"},
             "reference": {"status": "skipped", "reason": "render_failed"},
             "compare": {"status": "not_applicable"}},
        ]))
        (tmp / "run-meta.json").write_text(json.dumps({"started_at": "-", "workshop": "-",
                                                       "keep_references": True}))
        safety.write_owner_marker(tmp, scene_matrix_report.TOOL)
        args = type("Args", (), {"mode": "report", "allow_class": [], "evaluate_only": True})
        with contextlib.redirect_stdout(io.StringIO()):
            code = scene_matrix_report._evaluate_existing(tmp, args)
        self.assertEqual(code, scene_matrix_report.EXIT_UNEXPECTED)
        args.mode = "accept"
        with contextlib.redirect_stdout(io.StringIO()):
            code = scene_matrix_report._evaluate_existing(tmp, args)
        self.assertEqual(code, scene_matrix_report.EXIT_ACCEPT_FAILED)
        args.allow_class = ["render_failed_other"]
        with contextlib.redirect_stdout(io.StringIO()):
            code = scene_matrix_report._evaluate_existing(tmp, args)
        self.assertEqual(code, scene_matrix_report.EXIT_OK)

    def test_summary_counts_unexpected(self):
        rows = [
            {"scene": "a", "classification": "ok", "expected": True,
             "render": {"ok": True}, "compare": {"comparable": True, "status": "comparable"},
             "reference": {"status": "ok"}},
            {"scene": "b", "classification": "render_failed_other", "expected": False,
             "render": {"ok": False}, "compare": {"status": "not_applicable"},
             "reference": {"status": "skipped"}},
        ]
        summary = scene_matrix_report._summary(rows)
        self.assertEqual(summary["scenes"], 2)
        self.assertEqual(summary["unexpected_count"], 1)
        self.assertEqual(summary["unexpected"][0]["scene"], "b")


class BakeReferencePureTests(unittest.TestCase):
    def test_viewport_derivation_and_parity(self):
        import bake_reference

        self.assertEqual(bake_reference.derived_viewport((3840, 2160))[:2], (4096, 2304))
        self.assertEqual(bake_reference.derived_viewport((5262, 3898))[:2], (4096, 3034))
        self.assertEqual(bake_reference._bake_viewport(4096, 2303), (4096, 2304, {"height": 1}))
        self.assertEqual(bake_reference._bake_viewport(3015, 4096), (3016, 4096, {"width": 1}))
        self.assertEqual(bake_reference._bake_viewport(4096, 2304), (4096, 2304, None))
        with self.assertRaises(SystemExit):
            bake_reference._bake_viewport(100, 200)

    def test_scene_canvas_validation(self):
        import bake_reference

        self.assertEqual(bake_reference.scene_canvas(
            {"general": {"orthogonalprojection": {"width": 800, "height": 640}}}), (800, 640))
        with self.assertRaises(SystemExit):
            bake_reference.scene_canvas({"general": {}})
        with self.assertRaises(SystemExit):
            bake_reference.scene_canvas(
                {"general": {"orthogonalprojection": {"width": 0, "height": 640}}})

    def test_ppm_parser_rejects_bad_input(self):
        import bake_reference

        tmp = Path(tempfile.mkdtemp(prefix="ppm-test-"))
        self.addCleanup(shutil.rmtree, tmp, True)
        bad = tmp / "bad.ppm"
        bad.write_bytes(b"P6\n2 2\n255\n" + b"\0" * 3)
        with self.assertRaises(SystemExit):
            bake_reference._parse_ppm(bad)
        good = tmp / "good.ppm"
        good.write_bytes(b"P6\n2 2\n255\n" + b"\1" * 12)
        self.assertEqual(bake_reference._parse_ppm(good)[:2], (2, 2))

    def test_bake_refuses_overwrite_without_force(self):
        import bake_reference

        tmp = Path(tempfile.mkdtemp(prefix="bake-test-"))
        self.addCleanup(shutil.rmtree, tmp, True)
        existing = tmp / "ref.png"
        existing.write_bytes(b"existing")
        with self.assertRaises(SystemExit):
            bake_reference.bake(HERE / "test_scene.pkg", existing, 800, 640)
        self.assertEqual(existing.read_bytes(), b"existing")


class CommandIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="evidence-tool-cli-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def _run(self, *args):
        return subprocess.run([sys.executable] + [str(arg) for arg in args],
                              capture_output=True, text=True, timeout=600)

    def test_verify_golden_refuses_protected_base(self):
        proc = self._run(HERE / "verify_golden.py", REPO)
        self.assertEqual(proc.returncode, safety.EXIT_UNSAFE, proc.stderr)
        proc = self._run(HERE / "verify_golden.py", Path("/"))
        self.assertEqual(proc.returncode, safety.EXIT_UNSAFE, proc.stderr)

    def test_verify_golden_refuses_symlink_to_protected(self):
        link = self.tmp / "link-to-repo"
        os.symlink(REPO, link)
        proc = self._run(HERE / "verify_golden.py", link)
        self.assertEqual(proc.returncode, safety.EXIT_UNSAFE, proc.stderr)

    def test_verify_golden_keeps_caller_sentinel(self):
        base = _sentinel(self.tmp, "golden-base")
        if not (REPO / "app/.build/debug/pkd-selftest").is_file():
            self.skipTest("缺少 pkd-selftest")
        proc = self._run(HERE / "verify_golden.py", base)
        self.assertIn(proc.returncode, (0, 1), proc.stderr)
        self.assertTrue((base / "keep.txt").is_file(), "调用者哨兵文件必须保留")
        runs = [entry for entry in base.iterdir() if entry.name.startswith("golden-verify-")]
        self.assertEqual(len(runs), 1, f"应在 base 下创建专属运行目录：{list(base.iterdir())}")
        self.assertTrue((runs[0] / safety.MARKER_NAME).is_file())
        self.assertTrue((runs[0] / "solid" / "scene.pkg").is_file())

    def test_pkg_ablate_refuses_symlink_to_protected(self):
        link = self.tmp / "link-to-repo"
        os.symlink(REPO, link)
        extracted = self.tmp / "extracted"
        extracted.mkdir()
        _, entries = pkg_ablate.read_pkg(HERE / "test_scene.pkg")
        scene = dict(entries)["scene.json"]
        (extracted / "scene.json").write_bytes(scene)
        proc = self._run(HERE / "pkg_ablate.py", HERE / "test_scene.pkg", extracted, link)
        self.assertEqual(proc.returncode, safety.EXIT_UNSAFE, proc.stderr)

    def test_pkg_ablate_writes_owned_run_and_keeps_sentinel(self):
        base = _sentinel(self.tmp, "ablate-base")
        extracted = self.tmp / "extracted2"
        extracted.mkdir()
        _, entries = pkg_ablate.read_pkg(HERE / "test_scene.pkg")
        (extracted / "scene.json").write_bytes(dict(entries)["scene.json"])
        proc = self._run(HERE / "pkg_ablate.py", HERE / "test_scene.pkg", extracted, base)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue((base / "keep.txt").is_file())
        runs = [entry for entry in base.iterdir() if entry.name.startswith("pkg-ablate-")]
        self.assertEqual(len(runs), 1)
        manifest = json.loads((runs[0] / "ablate-manifest.json").read_text())
        self.assertEqual(len(manifest["variants"]), 10)
        self.assertTrue(manifest["roundtrip_byte_identical"])

    def test_scene_matrix_refuses_mixed_output(self):
        workshop = self.tmp / "workshop"
        (workshop / "sceneA").mkdir(parents=True)
        shutil.copy(HERE / "test_scene.pkg", workshop / "sceneA" / "scene.pkg")
        out = _sentinel(self.tmp, "matrix-out")
        proc = self._run(HERE / "scene_matrix_report.py", "--workshop", workshop, "--out", out)
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertTrue((out / "keep.txt").is_file())

    def test_scene_matrix_refuses_protected_output(self):
        workshop = self.tmp / "workshop2"
        (workshop / "sceneA").mkdir(parents=True)
        shutil.copy(HERE / "test_scene.pkg", workshop / "sceneA" / "scene.pkg")
        proc = self._run(HERE / "scene_matrix_report.py", "--workshop", workshop, "--out", REPO)
        self.assertEqual(proc.returncode, safety.EXIT_UNSAFE, proc.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
