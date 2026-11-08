#!/usr/bin/env python3
"""Stage only optional, manifest-listed public merge sequences; never download."""
import hashlib
import json
import os
from pathlib import Path
import shutil

repo = Path(os.environ["SRCROOT"])
bundle = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["UNLOCALIZED_RESOURCES_FOLDER_PATH"]
if ".xctest/Contents/Resources" not in str(bundle):
    raise SystemExit("Expected an XCTest resources directory")
destination = bundle / "PublicMergeFixtures"
if destination.exists():
    shutil.rmtree(destination)
destination.mkdir(parents=True)
manifest = json.loads((repo / "Tests/Fixtures/public-merge-samples.json").read_text())
staged = []
for dataset in manifest["datasets"]:
    name = dataset["id"]
    if Path(name).name != name or name.startswith("."):
        raise SystemExit("Invalid dataset name")
    directory = repo / "Samples/public-merge" / name
    if directory.is_symlink() or directory.parent.is_symlink():
        raise SystemExit("Public merge directories must not be symlinks")
    files = dataset["files"]
    # An incomplete optional sequence remains unavailable as a whole.
    if not all((directory / item["file"]).is_file() for item in files):
        continue
    for item in files:
        filename = item["file"]
        if Path(filename).name != filename or filename.startswith("."):
            raise SystemExit("Invalid public merge filename")
        source = directory / filename
        if source.is_symlink() or hashlib.sha256(source.read_bytes()).hexdigest() != item["sha256"]:
            raise SystemExit("Invalid public merge fixture: " + str(source))
    target = destination / name
    target.mkdir()
    for item in files:
        shutil.copyfile(directory / item["file"], target / item["file"])
    staged.append(dataset)
(destination / "manifest.json").write_text(json.dumps({"datasets": staged}, indent=2) + "\n")
print("Staged", len(staged), "hash-verified public merge sequences for XCTest")
