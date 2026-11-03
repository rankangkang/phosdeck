#!/usr/bin/env python3
"""Run directly on macOS: python3 Tests/test_calibration_paths.py."""
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import struct
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parent.parent


class CalibrationPathTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="phosdeck-calibration-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.cwd = self.root / "working"
        self.cwd.mkdir()

    def run_script(self, executable, script, *arguments, success=True):
        result = subprocess.run([executable, str(REPO / script), *arguments], cwd=self.cwd,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stderr)
        return result

    def test_moved_manifest_and_report(self):
        script = "scripts/lightroom-raster-baseline.swift"
        self.run_script("swift", script, "generate-middle-sweeps", "../original")
        moved = self.root / "moved"
        (self.root / "original").rename(moved)
        manifest = json.loads((moved / "colour-manifest.json").read_text())
        chart = manifest["charts"][0]
        source = chart["metadata"]
        self.assertFalse(os.path.isabs(source["path"]))
        image = moved / source["path"]
        self.assertEqual(hashlib.sha256(image.read_bytes()).hexdigest(), source["sha256"])
        self.run_script("swift", script, "colour-patches", "../moved/colour-manifest.json",
                        chart["name"], f"../moved/{source['path']}",
                        f"../moved/{source['path']}", "../comparison")
        report = json.loads((self.root / "comparison.json").read_text())
        for key in ("source", "left", "right"):
            item = report[key]
            self.assertFalse(os.path.isabs(item["path"]))
            self.assertEqual((self.root / item["path"]).resolve(), image.resolve())
            self.assertEqual(item["sha256"], source["sha256"])
        before = (self.root / "comparison.json").read_bytes()
        self.run_script("swift", script, "colour-patches", "../moved/colour-manifest.json",
                        chart["name"], f"../moved/{source['path']}",
                        f"../moved/{source['path']}", "../comparison", success=False)
        self.assertEqual((self.root / "comparison.json").read_bytes(), before)

    def test_packer_resolves_manifest_rows_and_does_not_overwrite(self):
        inputs = self.root / "inputs"
        inputs.mkdir()
        raw = bytes(65 * 65 * 65 * 6)
        (inputs / "row.bin").write_bytes(raw)
        checksum = hashlib.sha256(raw).hexdigest()
        rows = [{"index": i, "ev": i / 4 - 5, "axis_power": 1 if i <= 20 else 2,
                 "file": "row.bin", "payload_sha256": checksum} for i in range(41)]
        (inputs / "manifest.json").write_text(json.dumps({"version": 2, "dimension": 65, "rows": rows}))
        script = "scripts/lightroom-exposure-colour-pack.swift"
        result = self.run_script("swift", script, "../inputs/manifest.json", "../archive.bin")
        summary_path = json.loads(result.stdout)["path"]
        self.assertFalse(os.path.isabs(summary_path))
        self.assertEqual((self.cwd / summary_path).resolve(), (self.root / "archive.bin").resolve())
        archive = (self.root / "archive.bin").read_bytes()
        self.assertEqual(archive[:8], b"OMLRCEX4")
        length = struct.unpack("<I", archive[8:12])[0]
        self.assertEqual(len(json.loads(archive[12:12 + length])["rows"]), 41)
        self.run_script("swift", script, "../inputs/manifest.json", "../archive.bin", success=False)
        self.assertEqual((self.root / "archive.bin").read_bytes(), archive)
        rows[0]["payload_sha256"] = "0" * 64
        (inputs / "manifest.json").write_text(json.dumps({"version": 2, "dimension": 65, "rows": rows}))
        self.run_script("swift", script, "../inputs/manifest.json", "../invalid.bin", success=False)
        self.assertFalse((self.root / "invalid.bin").exists())

    def test_validation_requests_require_explicit_support_directory(self):
        support = self.root / "support"
        catalog = support / "DefaultCatalog"
        catalog.mkdir(parents=True)
        library, imported = self.root / "library", self.root / "imported"
        library.mkdir()
        imported.mkdir()
        with sqlite3.connect(catalog / "Catalog.sqlite") as db:
            db.execute("CREATE TABLE storageRoot (id TEXT, path TEXT, bookmark BLOB)")
            db.executemany("INSERT INTO storageRoot VALUES (?, ?, ?)",
                           [("library", str(library.resolve()), b"synthetic"),
                            ("imported", str(imported.resolve()), b"synthetic")])
        raw = "scripts/prepare-raw-validation.py"
        scale = "scripts/prepare-scale-validation.py"
        self.run_script(sys.executable, raw, "../library", success=False)
        self.run_script(sys.executable, scale, "../library", "../imported", success=False)
        self.run_script(sys.executable, raw, "../library", "--app-support", "../support")
        self.run_script(sys.executable, scale, "../library", "../imported", "--app-support", "../support")
        for name in ("RawValidation", "ScaleValidation"):
            self.assertTrue((support / name / "request.json").is_file())
        request = support / "RawValidation/request.json"
        before = request.read_bytes()
        self.run_script(sys.executable, raw, "../library", "--app-support", "../support", success=False)
        self.assertEqual(request.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
