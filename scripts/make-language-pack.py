#!/usr/bin/env python3
"""Build a resource-only community language bundle with Xcode's string compiler."""
import argparse
import copy
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile


def translated(value):
    if not isinstance(value, dict) or not value:
        return False
    if "stringUnit" in value:
        unit = value["stringUnit"]
        return unit.get("state") == "translated" and bool(unit.get("value"))
    return all(translated(item) for item in value.values())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("catalog", type=Path, help="Community .xcstrings file copied from the official catalog")
    parser.add_argument("--language", required=True, help="BCP 47 language code, for example ru or zh-Hant")
    parser.add_argument("--name", required=True, help="Language name shown in the app")
    parser.add_argument("--author", required=True)
    parser.add_argument("--identifier", required=True, help="Community-owned package identifier")
    parser.add_argument("--version", default="1")
    parser.add_argument("--output", required=True, type=Path, help="New .bundle path; existing paths are never overwritten")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*", args.language) or args.language in ["en", "zh-Hans"] or args.language.startswith("en-"):
        parser.error("Choose a community language; official English and Simplified Chinese cannot be replaced")
    for value in [args.name, args.author, args.identifier, args.version]:
        if not value.strip() or len(value) > 200 or any(ord(c) < 32 or ord(c) == 127 for c in value):
            parser.error("Metadata must contain 1–200 printable characters")
    destination = args.output.absolute()
    if destination.suffix != ".bundle" or destination.exists() or destination.is_symlink():
        parser.error("The output must be a new .bundle path")
    if not destination.parent.is_dir():
        parser.error("The output parent folder must exist")
    catalog = json.loads(args.catalog.read_text(encoding="utf-8"))
    if catalog.get("sourceLanguage") != "en" or catalog.get("version") != "1.0":
        parser.error("Use the current official English-source String Catalog")
    strings = {}
    for key, item in catalog["strings"].items():
        localization = item.get("localizations", {}).get(args.language)
        if not translated(localization):
            continue
        record = copy.deepcopy(item)
        record["extractionState"] = "manual"
        record["localizations"] = {k: v for k, v in record["localizations"].items() if k in ["en", args.language]}
        strings[key] = record
    if not strings:
        parser.error("No complete translations marked 'translated' for this language")
    with tempfile.TemporaryDirectory(prefix=".phosdeck-language-", dir=destination.parent) as temporary:
        staging = Path(temporary) / "Language.bundle"
        resources = staging / "Contents" / "Resources"
        resources.mkdir(parents=True)
        source = Path(temporary) / "Localizable.xcstrings"
        source.write_text(json.dumps({"sourceLanguage": "en", "version": "1.0", "strings": strings}, ensure_ascii=False), encoding="utf-8")
        subprocess.run(["xcrun", "xcstringstool", "compile", str(source), "--language", args.language, "--output-directory", str(resources)], check=True)
        info = {"CFBundlePackageType": "BNDL", "CFBundleIdentifier": args.identifier,
                "CFBundleDevelopmentRegion": args.language, "CFBundleVersion": args.version,
                "OMLRCFormatVersion": 1, "OMLRCPackIdentifier": args.identifier,
                "OMLRCLanguage": args.language, "OMLRCName": args.name, "OMLRCAuthor": args.author}
        (staging / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))
        digests = {}
        for file in staging.rglob("*"):
            if file.is_file():
                digests[file.relative_to(staging)] = hashlib.sha256(file.read_bytes()).digest()
                with file.open("rb") as stream:
                    os.fsync(stream.fileno())
        # Darwin RENAME_EXCL publishes the directory without an overwrite race.
        libc = ctypes.CDLL(None, use_errno=True)
        rename = libc.renamex_np
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        if rename(os.fsencode(staging), os.fsencode(destination), 0x00000004) != 0:
            number = ctypes.get_errno()
            raise OSError(number, os.strerror(number), str(destination))
        published = plistlib.loads((destination / "Contents" / "Info.plist").read_bytes())
        if published != info:
            raise RuntimeError("Published metadata did not match; inspect the output before using it")
        for relative, expected in digests.items():
            if hashlib.sha256((destination / relative).read_bytes()).digest() != expected:
                raise RuntimeError(f"Published resource verification failed: {relative}")
    print(f"Built {destination} with {len(strings)} translated entries")


if __name__ == "__main__":
    main()
