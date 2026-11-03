#!/usr/bin/env python3
"""Stage only hash-verified, optional CC0 RAW samples in the XCTest bundle.

Run by the test target before signing. Missing samples are reported by XCTest as
skips. Never searches other Samples subfolders or any photo catalog/container.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil

repo = Path(os.environ["SRCROOT"])
bundle = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["UNLOCALIZED_RESOURCES_FOLDER_PATH"]
if ".xctest/Contents/Resources" not in str(bundle):
    raise SystemExit("Expected an XCTest resources directory")
destination = bundle / "CC0RAWFixtures"
if destination.exists():
    shutil.rmtree(destination)
destination.mkdir(parents=True)
staged = []
manifest = json.loads((repo / "Tests/Fixtures/public-raw-samples.json").read_text())
for sample in manifest["samples"]:
    name = sample["file"]
    if Path(name).name != name or sample["license"] != "CC0-1.0":
        raise SystemExit("Invalid CC0 sample entry")
    source = repo / "Samples/public-cc0" / name
    if not source.exists():
        continue
    if source.is_symlink() or hashlib.sha256(source.read_bytes()).hexdigest() != sample["sha256"]:
        raise SystemExit("Invalid public RAW fixture: " + name)
    shutil.copyfile(source, destination / name)
    staged.append(sample)
(destination / "manifest.json").write_text(json.dumps(staged, indent=2) + "\n")
print("Staged", len(staged), "hash-verified CC0 RAW samples for XCTest")
