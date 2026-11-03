#!/usr/bin/env python3
"""Reproduce the dense EV grey response from explicitly named Lightroom TIFFs.

Offline analysis only: Python standard library and the already used NumPy.
Each source, output and saved develop state must have a supplied SHA-256.
The old half-stop rows are checked exactly, not re-fitted or migrated.
Command-line paths are relative to the working directory; paths inside each
input or output JSON file are relative to that JSON file's directory.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import pathlib
import re

import numpy as np


def reader():
    path = pathlib.Path(__file__).with_name("lightroom-exposure-colour-calibrate.py")
    spec = importlib.util.spec_from_file_location("exposure_colour_calibrator", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def build(spec_path: pathlib.Path, output: pathlib.Path) -> dict:
    cal = reader()
    spec_path = spec_path.resolve()
    output = output.resolve()
    input_dir = spec_path.parent
    spec = json.loads(spec_path.read_text())
    if spec.get("version") != 1 or output.exists():
        raise ValueError("expected input version 1 and a new output directory")

    def verified(item: dict) -> pathlib.Path:
        path = cal.resolve_input(item["path"], input_dir)
        cal.require_hash(path, item["sha256"], str(path))
        return path

    source = verified(spec["source"])
    source_rgb, source_icc = cal.read_tiff(source)
    if source_rgb.shape != (480, 640, 3):
        raise ValueError("expected the recorded 640x480 C calibration chart")
    source_grey = source_rgb[10::20, 10::20].reshape(-1, 3)[:256]
    expected = np.arange(256, dtype=np.uint16) * 257
    if not np.array_equal(source_grey, np.repeat(expected[:, None], 3, axis=1)):
        raise ValueError("source first 256 tiles must be the complete encoded grey axis")
    legacy_path = verified(spec["half_stop_calibration"])
    legacy = json.loads(legacy_path.read_text())["table_code16"]
    rows = spec["rows"]
    if len(rows) != 101 or any(abs(float(r["ev"]) - (i - 50) / 10) > 1e-12 for i, r in enumerate(rows)):
        raise ValueError("expected 101 ordered EV rows, -5..+5 in 0.1 steps")
    values, provenance = [], []
    expected_icc = spec["output_icc_sha256"]
    for index, row in enumerate(rows):
        path = verified(row)
        settings_path = verified(row["settings"])
        settings = json.loads(settings_path.read_text())[source.stem]
        match = re.search(r"Exposure2012 = ([^,]+)", settings)
        if match is None or abs(float(match.group(1)) - float(row["ev"])) > 1e-12:
            raise ValueError("saved Lightroom exposure does not match the declared EV")
        rgb, icc = cal.read_tiff(path)
        if rgb.shape != source_rgb.shape or cal.sha256(icc) != expected_icc:
            raise ValueError("Lightroom dimensions or output ICC changed")
        tiles = rgb[:160].reshape(8, 20, 32, 20, 3)
        if np.any(tiles.min(axis=(1, 3)) != tiles.max(axis=(1, 3))):
            raise ValueError("grey calibration tiles must be spatially constant")
        grey = rgb[10::20, 10::20].reshape(-1, 3)[:256].mean(axis=1)
        curve = np.rint(np.interp(np.linspace(0, 255, 65), np.arange(256), grey)).astype(np.int64)
        if index == 50:
            # The product's neutral start remains exactly the source identity.
            curve = np.asarray(legacy[10], dtype=np.int64)
        elif index % 5 == 0 and not np.array_equal(curve, legacy[index // 5]):
            raise ValueError(f"half-stop response changed at {row['ev']}; investigate before adopting")
        if curve[0] != 0 or np.any(np.diff(curve) < 0):
            raise ValueError("grey response must be black-preserving and input-monotone")
        values.append(curve.tolist())
        provenance.append({"ev": row["ev"], "path": cal.relative_path(path, output),
                           "sha256": cal.sha256(path), "settings": {
                               **row["settings"], "path": cal.relative_path(settings_path, output)}})
    if np.any(np.diff(np.asarray(values), axis=0) < 0):
        raise ValueError("measured responses are not monotone in EV")
    result = {"format": "oh-my-lrc.own-exposure-grey-response", "version": 4,
              "ev_grid": {"minimum": -5, "maximum": 5, "step": 0.1, "count": 101},
              "input_grid": {"space": "encoded sRGB", "count": 65},
              "zero": "strict source identity; row 50 evaluated as i/64 without integer rounding",
              "half_stop_rows": "all 20 nonzero half-stop rows reproduced exactly",
              "source": {**spec["source"], "path": cal.relative_path(source, output)},
              "source_icc_sha256": cal.sha256(source_icc), "output_icc_sha256": expected_icc,
              "half_stop_calibration": {**spec["half_stop_calibration"], "path": cal.relative_path(legacy_path, output)},
              "rows": provenance, "table_code16": values}
    output.mkdir(exist_ok=False)
    with (output / "table.json").open("x") as handle:
        json.dump(result, handle, indent=2)
    with (output / "measured.swift.inc").open("x") as handle:
        for index, curve in enumerate(values):
            handle.write("        [" + ",".join(map(str, curve)) + f"], // {(index - 50) / 10:.1f} EV\n")
    return {"table": cal.relative_path(output / "table.json", pathlib.Path.cwd()),
            "table_sha256": cal.sha256(output / "table.json"), "rows": len(values)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("new_output", type=pathlib.Path)
    args = parser.parse_args()
    print(json.dumps(build(args.input, args.new_output), indent=2))
