#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Bake the pinned open camera looks into Phosdeck's float16 LUT format.

Requires NumPy and Node.js for offline generation. Pass the pinned Redlamp and
LightCraft assets directory, a new output directory, and --fuji-recipe pointing
at the pinned Fuji Recipe Converter checkout. The app reads only the baked
resources. Upstream revisions and file paths are in docs/references/.
"""
import argparse
import colorsys
import hashlib
import json
import lzma
import math
from pathlib import Path
import struct
import subprocess

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
SRGB_LUMA = np.array([0.2126, 0.7152, 0.0722])
FUJI_TITLES = (
    ("provia", "PROVIA"), ("velvia", "Velvia"), ("astia", "ASTIA"),
    ("classic-chrome", "Classic Chrome"), ("pro-neg-hi", "PRO Neg. Hi"),
    ("pro-neg-std", "PRO Neg. Std"), ("classic-neg", "Classic Neg."),
    ("nostalgic-neg", "Nostalgic Neg."), ("reala-ace", "REALA ACE"),
    ("eterna", "ETERNA"), ("eterna-bleach-bypass", "ETERNA Bleach Bypass"),
    ("acros", "ACROS"), ("acros-ye", "ACROS + Ye"),
    ("acros-r", "ACROS + R"), ("acros-g", "ACROS + G"),
    ("monochrome", "Monochrome"), ("monochrome-ye", "Monochrome + Ye"),
    ("monochrome-r", "Monochrome + R"), ("monochrome-g", "Monochrome + G"),
    ("sepia", "Sepia"),
)
FUJI_ZH_TITLES = {
    "monochrome": "黑白", "monochrome-ye": "黑白 + 黄", "monochrome-r": "黑白 + 红",
    "monochrome-g": "黑白 + 绿", "sepia": "棕褐色",
}
REDLAMP_FILES = {
    "provia": ("standard@2", "33deb7c2e817a168c02fe2918636ab4e983ee48e00382fda4a1389c717fadadf"),
    "velvia": ("vivid-slide@2", "0923f737c0ba849a48ad38cb6eedf4f6199e5d89c461998f524b21f7089ce311"),
    "astia": ("soft-slide", "69342d5a32bca99a8b2c2371705be1472768f71075e3aee19fcc807420584ecc"),
    "classic-chrome": ("chrome@2", "e2ebc08aa271ef3e81ffee2b1543ee4a1a083b82a5b8e917e2e13aadee0f2761"),
    "pro-neg-hi": ("negative-high", "83f902a7116c90c08e784fe57cdd96f045e7daf49e0ca31904c6f86c6db90298"),
    "pro-neg-std": ("negative-standard", "7ac48cf13d459f7ea61c0e14199469074e14bb441eabd0ad50b837a85df95e0c"),
    "classic-neg": ("negative-classic", "39af4e6e692018a774510842ff62e6215dd15a5aa97a1c83a5598503a3dd1b6a"),
    "nostalgic-neg": ("negative-nostalgic", "402ce3c6a0e5df9d59f1f4ab6fbf89e2c1ed36b788675eddbaf3d42d2395991f"),
    "eterna": ("cinema", "9221b670c95b9d2482debbac77349fcaa69ab06c300d8717e6978e572dc360f2"),
    "eterna-bleach-bypass": ("bleach", "4faca244c2f6eb36b87c69ff7baa76a71eb3428be88d8af8d21f906ad2f65568"),
    "monochrome": ("monochrome", "6170ffa0726c3708b19aea7e23cb8340793b55de48f3ee3ea925391d15c0c3ce"),
    "monochrome-ye": ("monochrome-yellow", "a31c3cac909ac86d00c8869969c53c86f4f9065c606948814639670d82993c9f"),
    "monochrome-r": ("monochrome-red", "789c44129fb24c309ae3f7d9793b9303d87fefcb75dc3cb202bf861cfafc8973"),
    "monochrome-g": ("monochrome-green", "0ef798fb5e4000d828dac838e6d4eabc38b3e618fe7738019c911ee7f8fd84fb"),
}
# StarterPackLooks.swift's linear Rec.2020 monochrome mixers.
REDLAMP_MONO_WEIGHTS = {
    "monochrome": (0.2627, 0.6780, 0.0593),
    "monochrome-ye": (0.42, 0.55, 0.03),
    "monochrome-r": (0.8, 0.2, 0),
    "monochrome-g": (0.18, 0.78, 0.04),
}
FUJI_RECIPE_FILES = {
    "js/data.js": "e0b7bb407413da3143c88d57126cc0307df3859450bdea02bd44ad05f72eb5bd",
    "js/engine.js": "4bddd884627a3b4ba1b03f102b01f84480e1c709a79711567e2ae439200b22a8",
}
FUJI_RECIPE_LOOKS = {
    "reala-ace": None,
    "acros": SRGB_LUMA,
    "acros-ye": SRGB_LUMA,
    "acros-r": SRGB_LUMA,
    "acros-g": SRGB_LUMA,
    "sepia": SRGB_LUMA,
}
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


def redlamp_transform(inputs, table, monochrome):
    display = np.clip(inputs @ SRGB_TO_REC2020.T, 0, 1)
    mapped = tetrahedral(table, srgb_encode(display))
    linear = srgb_decode(np.maximum(mapped, 0))
    if monochrome:
        gray = (linear @ (SRGB_LUMA @ REC2020_TO_SRGB))[:, None]
        return np.broadcast_to(gray, inputs.shape)
    return inputs + (linear - display) @ REC2020_TO_SRGB.T


def fuji_recipe_tables(checkout, keys):
    # Sample the upstream LUT exporter from verified source files without its UI
    # or browser dependencies. A finer input grid reduces double resampling.
    dimension = 65
    sources = [checked_bytes(checkout / name, digest).decode() for name, digest in FUJI_RECIPE_FILES.items()]
    payload = json.dumps({"sources": sources, "keys": keys, "dimension": dimension})
    program = """
        const fs = require('node:fs');
        const vm = require('node:vm');
        const { sources, keys, dimension } = JSON.parse(fs.readFileSync(0, 'utf8'));
        const scope = vm.createContext({ window: {} });
        for (const source of sources) vm.runInContext(source, scope);
        const { FR } = scope.window;
        for (const filmSim of keys) {
            if (FR.simById(filmSim).id !== filmSim) throw new Error(`Unknown film simulation: ${filmSim}`);
            const values = FR.buildLut(FR.derive({ filmSim }, { drInCurve: true }), dimension);
            const bytes = Buffer.alloc(values.length * 4);
            for (let i = 0; i < values.length; i++) bytes.writeFloatLE(values[i], i * 4);
            process.stdout.write(bytes);
        }
    """
    result = subprocess.run(["node", "-e", program], input=payload.encode(), stdout=subprocess.PIPE, check=True)
    tables = np.frombuffer(result.stdout, dtype="<f4").reshape((len(keys),) + (dimension,) * 3 + (3,))
    return dict(zip(keys, tables))


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


def pack(transform, headroom_weights=None):
    log_range = math.log1p(UPPER_BOUND / PIVOT)
    levels = PIVOT * np.expm1(np.linspace(0, log_range, DIMENSION))
    blue, green, red = np.meshgrid(levels, levels, levels, indexing="ij")
    inputs = np.column_stack((red.ravel(), green.ravel(), blue.ravel()))
    peak = inputs.max(axis=1, keepdims=True)
    if headroom_weights is None:
        # Fade colour looks near white while allowing highlight recovery.
        weight = np.clip((1 - peak) / 0.25, 0, 1)
        output = inputs + (transform(inputs) - inputs) * weight ** 2 * (3 - 2 * weight)
        white_coordinates = inputs
    else:
        # Keep the upstream grayscale or sepia tint above display white.
        normalized = inputs / np.maximum(1, peak)
        residual = (inputs - normalized) @ headroom_weights
        output = np.clip(transform(normalized), 0, 1) + residual[:, None]
        white_coordinates = peak
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
    below_white = float(np.nextafter(np.float16(1), np.float16(0)))
    output = np.where(white_coordinates < levels[low], np.minimum(output, below_white), output)
    output = np.where(white_coordinates == levels[low], np.minimum(output, half_bound), output)
    return struct.pack("<8sIf", b"PHOSLK01", DIMENSION, UPPER_BOUND) + output.astype("<f2").tobytes()


def write_look(output, group, key, title, translated, data, headroom_weights=None):
    filename = f"{group}-{key}-v1.bin"
    (output / filename).write_bytes(data)
    entry = {
        "id": f"{group}.{key}", "version": 1, "group": group,
        "title": title, "localizedTitles": {"en": title, "zh-Hans": translated},
        "file": filename, "dimension": DIMENSION, "upperBound": UPPER_BOUND,
        "sha256": hashlib.sha256(data).hexdigest(),
    }
    if headroom_weights is not None:
        entry["headroomWeights"] = np.round(headroom_weights, 7).tolist()
    return entry


# Native AsShotMatch.fit on the Apple RAW and same-frame camera JPEG.
# Training and independent check file hashes are pinned in public-raw-samples.json.
# M50: canon_m50_raw / canon_m50_craw; D750: 895 / 898; D850: 1837 / 1840.
def measured_looks(output):
    records = [
        ("canon", "m50-jpeg", "EOS M50 Camera JPEG", "EOS M50 机内 JPEG 近似", [0.40375918, 0.33267322, 0.34767333]),
        ("nikon", "d750-standard", "D750 Standard", "D750 标准近似", [-0.14515176, -0.22239722, -0.20195101]),
        ("nikon", "d850-standard", "D850 Standard", "D850 标准近似", [0.28079522, 0.24904802, 0.633509]),
    ]
    entries = []
    for group, key, title, translated, bend in records:
        def transform(inputs):
            v = np.clip(inputs, 0, 1)
            return inputs + np.asarray(bend) * v * (1 - v)
        entries.append(write_look(output, group, key, title + " (approx.)", translated, pack(transform)))
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("upstream", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--fuji-recipe", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir()
    recipe_tables = fuji_recipe_tables(args.fuji_recipe, list(FUJI_RECIPE_LOOKS))
    entries = []
    for key, title in FUJI_TITLES:
        if key in REDLAMP_FILES:
            slot, digest = REDLAMP_FILES[key]
            table = redlamp_table(checked_bytes(args.upstream / f"base-{slot}.look.lzma", digest))
            monochrome = key in REDLAMP_MONO_WEIGHTS
            weights = np.array(REDLAMP_MONO_WEIGHTS[key]) @ SRGB_TO_REC2020 if monochrome else None
            image = pack(lambda inputs: redlamp_transform(inputs, table, monochrome), weights)
        else:
            table = recipe_tables[key]
            weights = FUJI_RECIPE_LOOKS[key]
            image = pack(lambda inputs: srgb_decode(tetrahedral(table, srgb_encode(np.minimum(inputs, 1)))), weights)
        entries.append(write_look(args.output, "fujifilm", key, title, FUJI_ZH_TITLES.get(key, title), image, weights))
    profile = json.loads(checked_bytes(args.upstream / "ILCE-7RM5.json", SONY_HASH))
    image = pack(lambda inputs: sony_transform(inputs, profile))
    entries.append(write_look(args.output, "sony", "st", "ST Standard Color", "ST 标准色彩", image))
    entries.extend(measured_looks(args.output))
    (args.output / "looks.json").write_text(json.dumps(entries, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
