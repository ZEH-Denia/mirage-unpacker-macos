#!/usr/bin/env python3
"""Run two real development-app processes against a fresh synthetic library."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", required=True, type=Path, help="Current signed PKD Development.app")
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
app = args.app.resolve()
with (app / "Contents/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
if info.get("CFBundleIdentifier") != "com.zeh.pkd.development":
    raise SystemExit("Refusing to launch a non-development application")
root = Path(tempfile.mkdtemp(prefix="library-lifecycle-", dir=repo / "app/.build"))
subprocess.run(["python3", str(repo / "tools/dev/make_fixtures.py"), str(root)], check=True)
reports = []
for scenario in ["library-seed", "library-verify"]:
    env = os.environ.copy()
    env.update(PKD_DEVELOPMENT_ROOT=str(root), PKD_DEVELOPMENT_SCENARIO=scenario)
    report_path = root / f"{scenario}.json"
    with (root / f"{scenario}.log").open("w") as log:
        process = subprocess.Popen([str(app / "Contents/MacOS/PKD")], env=env,
                                   stdout=log, stderr=log, start_new_session=True)
        try:
            deadline = time.monotonic() + 60
            while not report_path.exists():
                if process.poll() is not None:
                    raise RuntimeError(f"{scenario} exited early; inspect {root}")
                if time.monotonic() >= deadline:
                    raise RuntimeError(f"{scenario} timed out; inspect {root}")
                time.sleep(0.1)
            report = json.loads(report_path.read_text())
            if report.get("pid") != process.pid or not report.get("passed"):
                raise RuntimeError(f"{scenario} failed: {report}")
            reports.append(report)
        finally:
            # Only stop the exact disposable process created above.
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
assert reports[0]["pid"] != reports[1]["pid"], "Restart must use a distinct process"
summary = {"passed": True, "app": str(app), "reports": reports}
(root / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
print(f"Passed {sum(len(r['checks']) for r in reports)} lifecycle checks across two processes")
print(f"Evidence: {root / 'summary.json'}")
