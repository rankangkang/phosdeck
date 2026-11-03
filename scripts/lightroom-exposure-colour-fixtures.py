#!/usr/bin/env python3
"""Reproduce H/I calibration cubes and independent J; numpy is analysis-only.

Supply an explicitly authorized, opaque sRGB TIFF as the ICC template. No Adobe
profile, image, catalog or executable is embedded or discovered by this script.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct

import numpy as np


def sha(data):
    return hashlib.sha256(data).hexdigest()


def profile(path, expected):
    data = path.read_bytes()
    if sha(data) != expected or data[:2] not in (b"II", b"MM"):
        raise ValueError("Template hash/TIFF mismatch")
    endian = "<" if data[:2] == b"II" else ">"
    if struct.unpack_from(endian + "H", data, 2)[0] != 42:
        raise ValueError("Expected classic TIFF")
    start = struct.unpack_from(endian + "I", data, 4)[0]
    count = struct.unpack_from(endian + "H", data, start)[0]
    for i in range(count):
        tag, kind, size, offset = struct.unpack_from(endian + "HHII", data, start + 2 + i * 12)
        if tag == 34675:
            if kind != 7 or size <= 4 or offset + size > len(data):
                raise ValueError("Invalid template ICC")
            icc = data[offset:offset + size]
            if sha(icc) != "3f6d674174f3804eb0dabdac90ae17486e898c5063a66f861c116ea033da8301":
                raise ValueError("Expected the recorded SDK sRGB profile")
            return icc
    raise ValueError("Missing template ICC")


def write_tiff(directory, name, image, icc, extra):
    h, w, _ = image.shape
    pixels = image.astype("<u2").tobytes()
    start = 8 + 2 + 14 * 12 + 4
    icc_start = start + 6
    pixel_start = (icc_start + len(icc) + 3) // 4 * 4
    entries = [(256, 4, 1, w), (257, 4, 1, h), (258, 3, 3, start),
               (259, 3, 1, 1), (262, 3, 1, 2), (273, 4, 1, pixel_start),
               (274, 3, 1, 1), (277, 3, 1, 3), (278, 4, 1, h),
               (279, 4, 1, len(pixels)), (284, 3, 1, 1), (296, 3, 1, 1),
               (339, 3, 1, 1), (34675, 7, len(icc), icc_start)]
    data = bytearray(b"II" + struct.pack("<HIH", 42, 8, len(entries)))
    for tag, kind, count, value in entries:
        data.extend(struct.pack("<HHI", tag, kind, count))
        data.extend(struct.pack("<H", value) + b"\0\0" if kind == 3 and count == 1
                    else struct.pack("<I", value))
    data.extend(struct.pack("<IHHH", 0, 16, 16, 16))
    data.extend(icc)
    data.extend(bytes(pixel_start - len(data)))
    data.extend(pixels)
    path = directory / name
    with path.open("xb") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    saved = path.read_bytes()
    if saved != data or not np.array_equal(
            np.frombuffer(saved, "<u2", offset=pixel_start).reshape(h, w, 3), image):
        raise ValueError("Fixture readback mismatch")
    return {"path": name, "sha256": sha(saved), "bytes": len(saved),
            "size": [w, h], **extra}


def generate(template, digest, directory):
    icc = profile(template, digest)
    directory.mkdir(exist_ok=False)
    records = []
    for power, name in [(1, "h-rgb-response-cube65.tif"), (2, "i-shadow-response-cube65.tif")]:
        n, columns = 65, 520
        levels = np.rint(np.linspace(0, 1, n) ** power * 65535).astype("<u2")
        i = np.arange(n ** 3)
        nodes = np.column_stack((levels[i % n], levels[i // n % n], levels[i // (n * n)]))
        rows = (len(i) + columns - 1) // columns
        tiles = np.zeros((rows * columns, 3), dtype="<u2")
        tiles[:len(i)] = nodes
        image = np.repeat(np.repeat(tiles.reshape(rows, columns, 3), 4, 0), 4, 1)
        records.append(write_tiff(directory, name, image, icc, {
            "role": "calibration", "dimension": n, "axis_power": power,
            "levels16": levels.tolist(), "node_order": "R fastest,G next,B slowest",
            "cell": 4, "columns": columns, "node_count": n ** 3}))
    rng = np.random.default_rng(2026102001)
    a = rng.integers(0, 65536, size=(4096, 3), dtype=np.uint16)
    a[2048:3072] = np.rint(rng.random((1024, 3)) ** 3 * 65535).astype("<u2")
    for c in range(3):
        a[3072 + c * 256:3072 + (c + 1) * 256] = rng.integers(0, 1024, size=(256, 3), dtype=np.uint16)
        a[3072 + c * 256:3072 + (c + 1) * 256, c] = rng.integers(0, 65536, size=256, dtype=np.uint16)
    a[3840:] = np.column_stack([rng.integers(64000, 65536, size=256, dtype=np.uint16)] * 3)
    records.append(write_tiff(directory, "j-seeded-colour-holdout.tif",
                             np.repeat(np.repeat(a.reshape(64, 64, 3), 4, 0), 4, 1), icc,
                             {"role": "independent holdout, never calibration", "seed": 2026102001,
                              "cell": 4, "columns": 64, "node_count": 4096}))
    manifest = {"icc_sha256": sha(icc), "template_sha256": digest, "files": records}
    with (directory / "manifest.json").open("x") as handle:
        json.dump(manifest, handle, indent=2)
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("template", type=Path)
    parser.add_argument("template_sha256")
    parser.add_argument("new_directory", type=Path)
    args = parser.parse_args()
    result = generate(args.template, args.template_sha256, args.new_directory)
    print(json.dumps([{k: v for k, v in r.items() if k != "levels16"} for r in result["files"]], indent=2))
