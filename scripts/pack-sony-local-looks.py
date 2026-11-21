#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Convert Sony Look Bridge v4.0.0's α7R V photo LUTs for local use.

Requires NumPy. Pass Sony-A7R-V-Creative-Looks.zip from the upstream release
and a new output directory. See docs/getting-started.md for the source terms.
"""
import argparse
import hashlib
import json
from pathlib import Path
import runpy
from zipfile import ZipFile

import numpy as np


SOURCE_SHA256 = "75e067af37720cf92853df73a5b9e96facb813db20a072bc79df6f52738a083e"
SOURCE_DIMENSION = 64
SOURCE_GAMMA = 1.8
LOOKS = (
    ("PT", "Portrait", "人像"),
    ("NT", "Neutral", "中性"),
    ("VV", "Vivid", "鲜明"),
    ("VV2", "Vivid 2", "鲜明 2"),
    ("FL", "Film", "胶片"),
    ("IN", "Instant", "即时"),
    ("SH", "Soft Highkey", "柔和高调"),
    ("BW", "Black & White", "黑白"),
    ("SE", "Sepia", "棕褐色"),
)


def read_daylight_table(archive, code):
    title = f"SonyA7RM5 Look {code}"
    with archive.open(f"Sony-A7R-V-Creative-Looks/DxO PhotoLab/{title}.cube") as source:
        header = [source.readline().decode("ascii").strip() for _ in range(4)]
        if header != [f'TITLE "{title}"', f"LUT_3D_SIZE {SOURCE_DIMENSION}",
                      "DOMAIN_MIN 0.0 0.0 0.0", "DOMAIN_MAX 1.0 1.0 1.0"]:
            raise ValueError(f"Unexpected LUT header: {title}")
        values = np.loadtxt(source)
    if (values.shape != (SOURCE_DIMENSION ** 3, 3) or not np.isfinite(values).all()
            or np.min(values) < 0 or np.max(values) > 1):
        raise ValueError(f"Unexpected LUT values: {title}")
    # The CUBE stores red as the fastest-moving input coordinate.
    return values.reshape((SOURCE_DIMENSION,) * 3 + (3,))


def bake_looks(archive, baker):
    tetrahedral = baker["tetrahedral"]
    to_romm = baker["SRGB_TO_ROMM"].T
    to_srgb = baker["ROMM_TO_SRGB"].T
    luma = baker["SRGB_LUMA"]

    # The DxO tables expect a linear RAW base encoded as ProPhoto gamma 1.8.
    # Core Image already applies a base tone curve. Invert the upstream ST
    # neutral ramp as a shared input shaper to avoid applying that tone twice.
    ramp = np.linspace(0, 1, 1025)
    neutral = np.broadcast_to(ramp[:, None], (ramp.size, 3))
    standard = read_daylight_table(archive, "ST")
    gray = (tetrahedral(standard, neutral) ** SOURCE_GAMMA @ to_srgb) @ luma
    gray_levels, indices = np.unique(gray, return_index=True)
    encoded_levels = ramp[indices]

    for code, title, translated in LOOKS:
        table = read_daylight_table(archive, code)

        def transform(inputs):
            encoded = np.interp(inputs @ to_romm, gray_levels, encoded_levels)
            return tetrahedral(table, encoded) ** SOURCE_GAMMA @ to_srgb

        headroom_weights = luma if code in ("BW", "SE") else None
        data = baker["pack"](transform, headroom_weights)
        yield code, title, translated, data, headroom_weights


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    baker = runpy.run_path(str(Path(__file__).with_name("pack-camera-looks.py")))
    with args.archive.open("rb") as source:
        if hashlib.file_digest(source, "sha256").hexdigest() != SOURCE_SHA256:
            parser.error("Expected Sony-A7R-V-Creative-Looks.zip from the Sony Look Bridge v4.0.0 release")
        with ZipFile(source) as archive:
            looks = list(bake_looks(archive, baker))

    args.output.mkdir()
    entries = []
    for code, title, translated, data, weights in looks:
        entry = baker["write_look"](args.output, "sony-look-bridge.a7rv", code.lower(),
                                    f"{code} {title}", f"{code} {translated}", data, weights)
        entry["group"] = "sony"
        entries.append(entry)
    manifest = {"formatVersion": 1, "looks": entries}
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
