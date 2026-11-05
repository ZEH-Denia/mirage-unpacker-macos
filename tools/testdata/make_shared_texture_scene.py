#!/usr/bin/env python3
"""Two visible image objects share one texture; preflight must inspect the scene."""
import importlib.util
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("pkg", Path(__file__).with_name("make_test_pkg.py"))
pkg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pkg)
target = Path(sys.argv[1])
target.mkdir(parents=True, exist_ok=True)
scene = {"general": {"orthogonalprojection": {"width": 100, "height": 80}, "clearcolor": "0 0 0"},
         "objects": [{"image": "models/layer.json", "origin": f"{x} 40 0", "size": "50 80"} for x in (25, 75)]}
entries = [("scene.json", json.dumps(scene).encode()),
           ("models/layer.json", json.dumps({"material": "materials/layer.json"}).encode()),
           ("materials/layer.json", json.dumps({"passes": [{"shader": "genericimage4", "blending": "translucent", "textures": ["shared"]}]}).encode()),
           ("materials/shared.tex", pkg.build_tex(64, 64))]
(target / "scene.pkg").write_bytes(pkg.build_pkg(entries))
print(target / "scene.pkg")
