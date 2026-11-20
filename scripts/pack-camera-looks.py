#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Bake the pinned open camera looks into Phosdeck's float16 LUT format.

Requires NumPy for offline generation. Pass a directory containing the four
upstream assets named below and a new output directory. The App reads only
the baked resources. Upstream revisions and links are in docs/references/.
"""
import argparse
import colorsys
import hashlib
import json
import lzma
import math
from pathlib import Path
import struct

import numpy as np


DIMENSION = 33
UPPER_BOUND = 4.0
PIVOT = 0.18
SRGB_TO_REC2020 = np.array([
    [0.62740390, 0.32928304, 0.04331307],
    [0.06909729, 0.91954040, 0.01136232],
    [0.01639144, 0.08801331, 0.89559525],
])
# D65 sRGB to D50 ROMM RGB, Bradford adapted, as in DevelopKernels.metal.
SRGB_TO_ROMM = np.array([
    [0.5292907577680172, 0.33015660364785177, 0.14055263858413108],
    [0.09836164805996374, 0.8734849381186465, 0.028153413821389802],
    [0.016866088436003183, 0.11765576165553973, 0.8654781499084571],
])
REC2020_TO_SRGB = np.linalg.inv(SRGB_TO_REC2020)
ROMM_TO_SRGB = np.linalg.inv(SRGB_TO_ROMM)
FUJI = (
    ("provia", "PROVIA", "standard", "33deb7c2e817a168c02fe2918636ab4e983ee48e00382fda4a1389c717fadadf"),
    ("velvia", "Velvia", "vivid-slide", "0923f737c0ba849a48ad38cb6eedf4f6199e5d89c461998f524b21f7089ce311"),
    ("classic-chrome", "Classic Chrome", "chrome", "e2ebc08aa271ef3e81ffee2b1543ee4a1a083b82a5b8e917e2e13aadee0f2761"),
)
SONY_HASH = "455861b461eef57961bef49ed6c6045714f8c7f1f5954dd03c2de1c35012a95a"


def checked_bytes(path, digest):
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != digest:
        raise ValueError(f"Unexpected upstream resource: {path.name}")
    return data


def redlamp_table(data):
    payload = lzma.decompress(data)
    magic, size = struct.unpack_from("<4sI", payload)
    if magic != b"RLLK":
        raise ValueError("Expected a Redlamp bundled look")
    table = json.loads(payload[8:8 + size])["table"]
    dimension = table["size"]
    if table["space"] != "displayRec2020":
        raise ValueError("Expected a display Rec.2020 table")
    differences = np.frombuffer(payload[8 + size:], dtype="<u2").reshape(3, dimension ** 3)
    values = np.cumsum(differences, axis=1, dtype=np.uint64).T.astype("<u2").tobytes()
    identity = b"redlamp.looktable.v1\0displayRec2020\0" + struct.pack("<I", dimension) + values
    if hashlib.sha256(identity).hexdigest() != table["sha256"]:
        raise ValueError("Redlamp table hash mismatch")
    return np.frombuffer(values, dtype="<f2").astype(np.float64).reshape((dimension,) * 3 + (3,))


def srgb_encode(linear):
    return np.where(linear <= 0.0031308, 12.92 * linear, 1.055 * linear ** (1 / 2.4) - 0.055)


def srgb_decode(encoded):
    return np.where(encoded <= 0.04045, encoded / 12.92, ((encoded + 0.055) / 1.055) ** 2.4)


def tetrahedral(table, inputs):
    dimension = table.shape[0]
    coords = np.clip(inputs, 0, 1) * (dimension - 1)
    corners = np.minimum(np.floor(coords).astype(np.intp), dimension - 2)
    fractions = coords - corners
    order = np.argsort(-fractions, axis=1, kind="stable")
    indices = np.arange(len(inputs))
    last = table[corners[:, 2], corners[:, 1], corners[:, 0]]
    result = last.copy()
    for axis_index in range(3):
        axis = order[:, axis_index]
        corners[indices, axis] += 1
        following = table[corners[:, 2], corners[:, 1], corners[:, 0]]
        result += fractions[indices, axis, None] * (following - last)
        last = following
    return result


def fuji_transform(inputs, table):
    display = np.clip(inputs @ SRGB_TO_REC2020.T, 0, 1)
    mapped = tetrahedral(table, srgb_encode(display))
    delta = srgb_decode(np.maximum(mapped, 0)) - display
    return inputs + delta @ REC2020_TO_SRGB.T


def sony_transform(inputs, profile):
    # LightCraft's fitted matrix uses white-balanced sensor RGB. Phosdeck
    # applies its subsequent ROMM HSV table to the colour-managed decode.
    metadata = profile["hue_sat"]
    hues = metadata["hue_divisions"]
    sats = metadata["sat_divisions"]
    values = metadata["val_divisions"]
    table = np.array(metadata["data"]).reshape(values, hues, sats, 3)
    transform_value = metadata["srgb_value"]
    romm = inputs @ SRGB_TO_ROMM.T
    hsv = np.array([colorsys.rgb_to_hsv(*row) for row in romm])
    hue, sat, value = hsv.T
    encoded = srgb_encode(np.minimum(value, 1)) if transform_value else value
    hue_pos = hue * hues
    sat_pos = np.clip(sat, 0, 1) * (sats - 1)
    val_pos = np.clip(encoded, 0, 1) * (values - 1)
    h0 = hue_pos.astype(np.intp)
    h1 = (h0 + 1) % hues
    s0, v0 = sat_pos.astype(np.intp), val_pos.astype(np.intp)
    s1, v1 = np.minimum(s0 + 1, sats - 1), np.minimum(v0 + 1, values - 1)

    def mix(a, b, weight):
        return a + (b - a) * weight[:, None]

    def hue_and_saturation(level):
        first = mix(table[level, h0, s0], table[level, h0, s1], sat_pos - s0)
        second = mix(table[level, h1, s0], table[level, h1, s1], sat_pos - s0)
        return mix(first, second, hue_pos - h0)

    shift, sat_scale, value_scale = mix(hue_and_saturation(v0), hue_and_saturation(v1), val_pos - v0).T
    shifted = (hue + shift / 360) % 1
    scaled_sat = np.minimum(sat * sat_scale, np.maximum(sat, 1))
    if transform_value:
        scaled_value = np.where(value <= 1, srgb_decode(np.minimum(encoded * value_scale, 1)),
                                value * srgb_decode(np.minimum(value_scale, 1)))
    else:
        scaled_value = np.minimum(value * value_scale, np.maximum(value, 1))
    mapped = np.array([colorsys.hsv_to_rgb(*row) for row in zip(shifted, scaled_sat, scaled_value)])
    return inputs + (mapped - romm) @ ROMM_TO_SRGB.T


def pack(transform):
    log_range = math.log1p(UPPER_BOUND / PIVOT)
    levels = PIVOT * np.expm1(np.linspace(0, log_range, DIMENSION))
    blue, green, red = np.meshgrid(levels, levels, levels, indexing="ij")
    inputs = np.column_stack((red.ravel(), green.ravel(), blue.ravel()))
    mapped = transform(inputs)
    # Fade the display look near SDR white so the RAW renderer keeps headroom
    # for exposure and highlight recovery. Leave the signed residual to Metal.
    weight = np.clip((1 - inputs.max(axis=1, keepdims=True)) / 0.25, 0, 1)
    output = inputs + (mapped - inputs) * weight ** 2 * (3 - 2 * weight)
    if not np.isfinite(output).all() or np.min(output) < -1 or np.max(output) > UPPER_BOUND + 1:
        raise ValueError("Baked camera look is outside Phosdeck's float range")

    # Bound interpolation just below SDR white, including float16 rounding.
    white = math.log1p(1 / PIVOT) * (DIMENSION - 1) / log_range
    low, fraction = int(white), white % 1
    upper_plane = float(np.float16(levels[low + 1]))
    white_bound = (1 - 2e-6 - fraction * upper_plane) / (1 - fraction)
    half_bound = np.float16(white_bound)
    if half_bound > white_bound:
        half_bound = np.nextafter(half_bound, np.float16(-np.inf))
    below = inputs < levels[low]
    output = np.where(below, np.minimum(output, float(np.nextafter(np.float16(1), np.float16(0)))), output)
    packed = output.astype("<f2").reshape((DIMENSION,) * 3 + (3,))
    for channel, axis in enumerate((2, 1, 0)):
        plane = np.moveaxis(packed[..., channel], axis, 0)
        plane[low] = np.minimum(plane[low], half_bound)
    return struct.pack("<8sIf", b"PHOSLK01", DIMENSION, UPPER_BOUND) + packed.tobytes()


def write_look(output, group, key, title, translated, data):
    filename = f"{group}-{key}-v1.bin"
    (output / filename).write_bytes(data)
    return {
        "id": f"{group}.{key}", "version": 1, "group": group,
        "title": title, "localizedTitles": {"en": title, "zh-Hans": translated},
        "file": filename, "dimension": DIMENSION, "upperBound": UPPER_BOUND,
        "sha256": hashlib.sha256(data).hexdigest(),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("upstream", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir()
    entries = []
    for key, title, slot, digest in FUJI:
        source = checked_bytes(args.upstream / f"base-{slot}@2.look.lzma", digest)
        table = redlamp_table(source)
        image = pack(lambda inputs: fuji_transform(inputs, table))
        entries.append(write_look(args.output, "fujifilm", key, title, title, image))
    profile = json.loads(checked_bytes(args.upstream / "ILCE-7RM5.json", SONY_HASH))
    image = pack(lambda inputs: sony_transform(inputs, profile))
    entries.append(write_look(args.output, "sony", "st", "ST Standard Color", "ST 标准色彩", image))
    (args.output / "looks.json").write_text(json.dumps(entries, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
