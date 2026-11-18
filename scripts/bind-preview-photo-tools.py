#!/usr/bin/env python3
"""Bind the plugins in a staged Debug app to the fixed Preview identity before signing."""

import argparse
import plistlib
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Staged Phosdeck Preview.app")
    app = parser.parse_args().app
    if app.name != "Phosdeck Preview.app":
        parser.error("Use a staged copy named Phosdeck Preview.app")

    production = "dev.cmkk.oh-my-lrc"
    preview = production + ".unratedstars20261021"
    contents = app / "Contents"
    host_info = contents / "Info.plist"
    extensions = contents / "Extensions"
    point_file = extensions / "Phosdeck.appexpt"
    replacements = {}

    def inspect(file):
        data = file.read_bytes()
        value = plistlib.loads(data)
        replacements[file] = (value, plistlib.FMT_BINARY if data.startswith(b"bplist00") else plistlib.FMT_XML)
        return value

    info = inspect(host_info)
    bindings = inspect(point_file)
    current = info.get("CFBundleIdentifier")
    if current not in (production, preview):
        parser.error("The app has an unexpected bundle identifier")
    old_point = current + ".PhotoTool"
    new_point = preview + ".PhotoTool"
    if bindings.get("EXVersion") != 2 or bindings.get(old_point, {}).get("EXExtensionPointName") != "PhotoTool":
        parser.error("The app does not declare the expected PhotoTool extension point")

    for target, tool in (
        ("PhosdeckSoftProof", "soft-proof"),
        ("PhosdeckHighlights", "select-highlights"),
        ("PhosdeckWarmPrint", "warm-print"),
    ):
        extension = inspect(extensions / f"{target}.appex" / "Contents" / "Info.plist")
        attributes = extension.get("EXAppExtensionAttributes", {})
        if (
            extension.get("CFBundleIdentifier") != current + "." + tool
            or extension.get("PhosdeckPluginHost") != current
            or attributes.get("EXExtensionPointIdentifier") != old_point
        ):
            parser.error(f"Unexpected host binding in {target}")
        extension["CFBundleIdentifier"] = preview + "." + tool
        extension["PhosdeckPluginHost"] = preview
        attributes["EXExtensionPointIdentifier"] = new_point

    bindings[new_point] = bindings.pop(old_point)
    info.update(CFBundleIdentifier=preview, CFBundleName="Phosdeck Preview", CFBundleDisplayName="Phosdeck Preview")
    for file, (value, fmt) in replacements.items():
        file.write_bytes(plistlib.dumps(value, fmt=fmt, sort_keys=False))


if __name__ == "__main__":
    main()
