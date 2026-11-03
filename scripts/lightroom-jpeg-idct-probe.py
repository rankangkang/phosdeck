#!/usr/bin/env python3
"""Offline 4:4:4 JPEG decode-stage ablation from explicitly hashed inputs.

jpeg-coefficients.c uses an already installed libjpeg only as an analysis tool.
This probe applies its own double orthonormal inverse DCT and standard YCbCr
conversion. It neither adopts a product decoder nor recovers an Adobe algorithm.
Command-line paths are relative to the working directory; paths inside each
input or output JSON file are relative to that JSON file's directory.
"""
import argparse
import hashlib
import importlib.util
import itertools
import json
from pathlib import Path

import numpy as np


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verified(item, input_dir):
    path = (input_dir / item["path"]).resolve()
    if digest(path) != item["sha256"]:
        raise ValueError(f"Explicit input digest differs: {path}")
    return path


def build(spec_path, output):
    spec_path = spec_path.resolve()
    output = output.resolve()
    input_dir = spec_path.parent
    spec = json.loads(spec_path.read_text())
    if spec.get("version") != 1 or output.exists():
        raise ValueError("Expected current input version 1 and a new output directory")
    loader = importlib.util.spec_from_file_location(
        "tiff_reader", Path(__file__).with_name("lightroom-exposure-colour-calibrate.py"))
    cal = importlib.util.module_from_spec(loader)
    loader.loader.exec_module(cal)
    x, u = np.arange(8), np.arange(8)
    basis = np.cos((2 * x[:, None] + 1) * u[None, :] * np.pi / 16) * np.where(
        u[None, :] == 0, np.sqrt(1 / 8), .5)
    output.mkdir(exist_ok=False)
    rows, checks, provenance = [], [], []
    for entry in spec["specimens"]:
        name = entry["name"]
        if not name.isalnum() or any(x["name"] == name for x in provenance):
            raise ValueError("Specimen names must be unique alphanumeric labels")
        source = verified(entry["source"], input_dir)
        meta_path = verified(entry["metadata"], input_dir)
        meta = json.loads(meta_path.read_text())
        width, height = int(meta["width"]), int(meta["height"])
        if meta["precision"] != 8 or len(meta["components"]) != 3 or len(entry["coefficients"]) != 3:
            raise ValueError("Only the measured 8-bit YCbCr family is admitted")
        planes = []
        for component, data in zip(meta["components"], entry["coefficients"]):
            if component["h_sampling"] != 1 or component["v_sampling"] != 1:
                raise ValueError("This probe has no chroma subsampling reconstruction")
            h, w = component["block_height"], component["block_width"]
            if h != (height + 7) // 8 or w != (width + 7) // 8:
                raise ValueError("Block layout does not match the source dimensions")
            q = np.asarray(component["quant"], dtype=np.float64)
            if q.shape != (64,) or np.any(q <= 0) or np.any(q > 65535):
                raise ValueError("Invalid natural-order quantization table")
            raw = verified(data, input_dir).read_bytes()
            if len(raw) != h * w * 64 * 2:
                raise ValueError("Incomplete signed coefficient plane")
            coefficients = np.frombuffer(raw, "<i2").reshape(h, w, 8, 8).astype(np.float64)
            blocks = basis @ (coefficients * q.reshape(8, 8)) @ basis.T + 128
            planes.append(blocks.transpose(0, 2, 1, 3).reshape(h * 8, w * 8)[:height, :width])
        ycc = np.stack(planes, axis=-1)
        with (output / (name + ".ycc-f64le")).open("xb") as handle:
            handle.write(ycc.astype("<f8").tobytes())
        reference = verified(entry["ycc_reference"], input_dir).read_bytes()
        if len(reference) != height * width * 3:
            raise ValueError("Incomplete independent YCbCr readback")
        reference = np.frombuffer(reference, np.uint8).reshape(height, width, 3)
        error = np.abs(np.floor(np.clip(ycc, 0, 255) + .5) - reference)
        check = {"name": name, "stage": "IDCT YCbCr before colour conversion",
                 "max8": float(error.max()), "nonzero": int(np.count_nonzero(error)),
                 "gt1": int((error > 1).sum())}
        checks.append(check)
        if check["gt1"]:
            raise ValueError("Double IDCT stage differs from the library readback by more than one sample")
        target_path = verified(entry["lr_zero"], input_dir)
        target, _ = cal.read_tiff(target_path)
        if target.shape != (height, width, 3):
            raise ValueError("Actual Lightroom target dimensions differ")
        target = target / 257.0
        for samples, clamp_samples, quantize_rgb in itertools.product(
                ["float", "round", "floor"], [False, True], ["float", "round", "floor"]):
            values = ycc.copy()
            if samples == "round":
                values = np.floor(values + .5)
            elif samples == "floor":
                values = np.floor(values)
            if clamp_samples:
                values = np.clip(values, 0, 255)
            yy, cb, cr = values[:, :, 0], values[:, :, 1] - 128, values[:, :, 2] - 128
            rgb = np.stack([yy + 1.402 * cr,
                            yy - (.114 * 1.772 / .587) * cb - (.299 * 1.402 / .587) * cr,
                            yy + 1.772 * cb], axis=-1)
            if quantize_rgb == "round":
                rgb = np.floor(rgb + .5)
            elif quantize_rgb == "floor":
                rgb = np.floor(rgb)
            rgb = np.clip(rgb, 0, 255)
            error = np.abs(rgb - target)
            rows.append({"sample": name, "samples": samples, "clamp_samples": clamp_samples,
                         "quantize_rgb": quantize_rgb, "mae8": float(error.mean()),
                         "p99": float(np.quantile(error, .99)), "max8": float(error.max()),
                         "mean_signed": (rgb - target).mean(axis=(0, 1)).tolist()})
        if digest(source) != entry["source"]["sha256"]:
            raise ValueError("Source changed during measurement")
        def output_item(item):
            return {**item, "path": cal.relative_path((input_dir / item["path"]).resolve(), output)}
        provenance.append({**entry,
                           **{key: output_item(entry[key]) for key in ("source", "metadata", "ycc_reference", "lr_zero")},
                           "coefficients": [output_item(item) for item in entry["coefficients"]]})
    result = {"definition": "Own double IDCT and standard YCbCr; 18 fixed stage choices per input; no fitted coefficients, product change or Adobe decoder identity claim",
              "input": {"path": cal.relative_path(spec_path, output), "sha256": digest(spec_path)},
              "specimens": provenance, "checks": checks, "rows": rows,
              "limits": ["4:4:4 8-bit YCbCr only; no subsampling, ICC transform or product image processing",
                         "Library YCbCr readback verifies the IDCT stage; RGB conversion combines component errors and has no one-code bound",
                         "All variants and local maxima are retained; the lowest MAE is not user acceptance"]}
    with (output / "results.json").open("x") as handle:
        json.dump(result, handle, indent=2)
        handle.write("\n")
    return {"output": cal.relative_path(output / "results.json", Path.cwd()), "specimens": len(provenance), "variants": len(rows)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("new_output", type=Path)
    args = parser.parse_args()
    print(json.dumps(build(args.input, args.new_output), indent=2))
