#!/usr/bin/env python3
"""Opt in once to real RAW tests using an already user-authorized app root.

Usage: python3 scripts/prepare-raw-validation.py SAMPLE_ROOT --app-support APP_SUPPORT
Only copies the app's existing bookmark into its private validation request.
Never discovers additional photo roots or changes originals.
APP_SUPPORT is the XCTest host application's OhMyLRC Application Support directory.
"""
import argparse
import base64
import json
from pathlib import Path
import sqlite3

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("sample_root", type=Path)
parser.add_argument("--app-support", type=Path, required=True,
                    help="explicitly authorized App Application Support directory")
parser.add_argument("--catalog-folder", default="DefaultCatalog")
parser.add_argument("--count", type=int, default=19)
args = parser.parse_args()
if not 1 <= args.count <= 50:
    parser.error("--count must be 1...50")
if Path(args.catalog_folder).name != args.catalog_folder:
    parser.error("--catalog-folder must be a single directory name")
support = args.app_support.resolve()
database = support / args.catalog_folder / "Catalog.sqlite"
with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as connection:
    connection.row_factory = sqlite3.Row
    row = connection.execute("SELECT * FROM storageRoot WHERE path=?", (str(args.sample_root.resolve()),)).fetchone()
if row is None:
    parser.error("First select this exact sample root through the application's Add Existing Photos panel")
root = dict(row)
root["bookmark"] = base64.b64encode(root["bookmark"]).decode("ascii")
folder = support / "RawValidation"
folder.mkdir(exist_ok=True)
with (folder / "request.json").open("x", encoding="utf-8") as stream:
    json.dump({"root": root, "maxSamples": args.count}, stream)
print("Private one-shot RAW test request prepared. Run AuthorizedRAWTests with xcodebuild.")
