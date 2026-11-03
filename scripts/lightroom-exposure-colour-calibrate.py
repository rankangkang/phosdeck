#!/usr/bin/env python3
"""Build the measured Lightroom exposure-colour residual pack.

This is a standalone offline calibrator.  It has no product or Lightroom
paths as defaults and only depends on Python's standard library plus NumPy.
The input JSON names every source/output TIFF, ICC SHA, calibration table and
Swift table. The output is a packer-compatible 41-row int16 manifest.
Command-line paths are relative to the working directory; paths inside each
input or output JSON file are relative to that JSON file's directory.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import struct
from typing import Any

import numpy as np

_TYPE_SIZE = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1}
_TYPE_FMT = {1: "B", 3: "H", 4: "I"}


def _ifd(data: bytes) -> tuple[str, dict[int, tuple[int, int, bytes, tuple[int, ...]]]]:
    if data[:2] == b"II":
        endian = "<"
    elif data[:2] == b"MM":
        endian = ">"
    else:
        raise ValueError("not a TIFF")
    if len(data) < 8 or struct.unpack_from(endian + "H", data, 2)[0] != 42:
        raise ValueError("only classic TIFF magic 42 is supported")
    offset = struct.unpack_from(endian + "I", data, 4)[0]
    if offset + 2 > len(data):
        raise ValueError("IFD outside TIFF")
    count = struct.unpack_from(endian + "H", data, offset)[0]
    end = offset + 2 + count * 12
    if end + 4 > len(data) or struct.unpack_from(endian + "I", data, end)[0] != 0:
        raise ValueError("expected one complete TIFF IFD")
    entries: dict[int, tuple[int, int, bytes, tuple[int, ...]]] = {}
    for i in range(count):
        pos = offset + 2 + i * 12
        if pos + 12 > len(data):
            raise ValueError("truncated TIFF IFD")
        tag, typ, n, value = struct.unpack_from(endian + "HHII", data, pos)
        if tag in entries:
            raise ValueError("duplicate TIFF tag")
        size = _TYPE_SIZE.get(typ)
        if size is None:
            continue
        total = n * size
        if total <= 4:
            payload = data[pos + 8 : pos + 8 + total]
        else:
            if value + total > len(data):
                raise ValueError(f"TIFF tag {tag} outside file")
            payload = data[value : value + total]
        if typ in _TYPE_FMT:
            values = struct.unpack(endian + _TYPE_FMT[typ] * n, payload)
        else:
            values = tuple(payload)
        entries[tag] = (typ, n, payload, tuple(int(v) for v in values))
    return endian, entries


def read_tiff(path: str | pathlib.Path) -> tuple[np.ndarray, bytes]:
    """Read an uncompressed chunky RGB16 TIFF and return ``(RGB16, ICC)``.

    The returned image is native ``np.uint16`` with shape H×W×3.  Compression,
    tiled/planar data, non-RGB photometric data, orientation transforms and
    non-16-bit samples are rejected deliberately so a calibration cannot pass
    through an implicit decoder or orientation change.
    """
    p = pathlib.Path(path)
    raw = p.read_bytes()
    endian, tags = _ifd(raw)

    def one(tag: int) -> int:
        if tag not in tags or not tags[tag][3]:
            raise ValueError(f"{p}: missing TIFF tag {tag}")
        return tags[tag][3][0]

    width, height = one(256), one(257)
    bits = tags.get(258, (0, 0, b"", (0,)))[3]
    samples = one(277)
    if width <= 0 or height <= 0 or samples not in (3, 4) or bits != (16,) * samples:
        raise ValueError(f"{p}: expected RGB16, got {width}x{height}, samples={samples}, bits={bits}")
    if one(259) != 1 or one(262) != 2 or one(284) != 1:
        raise ValueError(f"{p}: expected uncompressed chunky RGB TIFF")
    if 274 in tags and one(274) != 1:
        raise ValueError(f"{p}: orientation transforms are not accepted")
    if 339 in tags and not all(v == 1 for v in tags[339][3]):
        raise ValueError(f"{p}: non-unsigned sample format")
    offsets, counts = tags.get(273, (0, 0, b"", ())), tags.get(279, (0, 0, b"", ()))
    if not offsets[3] or not counts[3] or len(offsets[3]) != len(counts[3]):
        raise ValueError(f"{p}: invalid strip table")
    rows_per_strip = one(278)
    dtype = np.dtype(endian + "u2")
    rows: list[np.ndarray] = []
    seen_rows = 0
    for off, count in zip(offsets[3], counts[3]):
        row_count = min(rows_per_strip, height - seen_rows)
        if row_count <= 0:
            raise ValueError(f"{p}: too many strips")
        expected = row_count * width * samples * 2
        if count != expected or off + count > len(raw):
            raise ValueError(f"{p}: strip size {count} != expected {expected}")
        a = np.frombuffer(raw, dtype=dtype, count=expected // 2, offset=off).reshape(row_count, width, samples)
        if samples == 4 and np.any(a[:, :, 3] != 65535):
            raise ValueError(f"{p}: calibration requires opaque alpha")
        rows.append(a[:, :, :3].astype(np.uint16, copy=False))
        seen_rows += row_count
    if seen_rows != height:
        raise ValueError(f"{p}: strips cover {seen_rows} rows, expected {height}")
    if 34675 not in tags:
        raise ValueError(f"{p}: missing embedded ICC profile")
    return np.concatenate(rows, axis=0), tags[34675][2]


def sha256(data: bytes | pathlib.Path) -> str:
    if isinstance(data, pathlib.Path):
        data = data.read_bytes()
    return hashlib.sha256(data).hexdigest()


def icc_matrix_gamma(icc: bytes, require_gamma: bool = True) -> tuple[np.ndarray, float | None]:
    if len(icc) < 132:
        raise ValueError("truncated ICC profile")
    count = struct.unpack_from(">I", icc, 128)[0]
    tags: dict[bytes, bytes] = {}
    for i in range(count):
        pos = 132 + i * 12
        if pos + 12 > len(icc):
            raise ValueError("truncated ICC tag table")
        sig, off, size = struct.unpack_from(">4sII", icc, pos)
        if off + size > len(icc):
            raise ValueError("ICC tag outside profile")
        tags[sig] = icc[off : off + size]
    try:
        matrix = np.array([struct.unpack_from(">iii", tags[s], 8) for s in (b"rXYZ", b"gXYZ", b"bXYZ")], dtype=np.float64).T / 65536.0
    except KeyError as exc:
        raise ValueError("ICC lacks RGB matrix tags") from exc
    trc = tags.get(b"rTRC")
    gamma: float | None = None
    if trc is not None and trc[:4] == b"curv" and len(trc) >= 14 and struct.unpack_from(">I", trc, 8)[0] == 1:
        gamma = struct.unpack_from(">H", trc, 12)[0] / 256.0
    if require_gamma and gamma is None:
        raise ValueError("ICC requires a single-value rTRC curve")
    if gamma is not None and (not np.isfinite(gamma) or gamma <= 0):
        raise ValueError("invalid ICC matrix/gamma")
    if not np.isfinite(matrix).all():
        raise ValueError("invalid ICC matrix")
    return matrix, gamma


def cube_nodes(image: np.ndarray, dimension: int, cell: int) -> np.ndarray:
    h, w, channels = image.shape
    if channels != 3 or h % cell or w % cell:
        raise ValueError(f"cube shape {image.shape} is not divisible by cell {cell}")
    rows, columns = h // cell, w // cell
    blocks = image.reshape(rows, cell, columns, cell, 3)
    if np.any(blocks.min(axis=(1, 3)) != blocks.max(axis=(1, 3))):
        raise ValueError("calibration tiles must be spatially constant")
    tiles = blocks.mean(axis=(1, 3), dtype=np.float64) / 65535.0
    nodes = tiles.reshape(-1, 3)[: dimension**3]
    if len(nodes) != dimension**3:
        raise ValueError("cube has fewer nodes than dimension^3")
    return nodes


def grid_nodes(levels16: np.ndarray) -> np.ndarray:
    levels = levels16.astype(np.float64) / 65535.0
    b, g, r = np.meshgrid(levels, levels, levels, indexing="ij")
    return np.stack([r, g, b], axis=-1).reshape(-1, 3)


def srgb_linear(x: np.ndarray) -> np.ndarray:
    x = np.asarray(x, dtype=np.float64)
    return np.where(x <= 0.04045, x / 12.92, ((np.maximum(x, 0) + 0.055) / 1.055) ** 2.4)


def srgb_encode_extended(x: np.ndarray) -> np.ndarray:
    x = np.asarray(x, dtype=np.float64)
    a, sign = np.abs(x), np.sign(x)
    return sign * np.where(a <= 0.0031308, 12.92 * a, 1.055 * np.maximum(a, 0) ** (1 / 2.4) - 0.055)


def pchip_slopes(values: np.ndarray) -> np.ndarray:
    d = np.diff(values)
    m = np.empty_like(values)
    m[0], m[-1] = d[0], d[-1]
    for i in range(1, len(values) - 1):
        m[i] = 2 * d[i - 1] * d[i] / (d[i - 1] + d[i]) if d[i - 1] * d[i] > 0 else 0
    return m


def map_linear(x: np.ndarray, values: np.ndarray, ev: float) -> np.ndarray:
    x = np.asarray(x, dtype=np.float64)
    out = np.empty_like(x)
    neg, high = x < 0, x > 1
    mid = ~(neg | high)
    out[neg] = x[neg] * (2**ev)
    slope = (srgb_linear(values[64]) - srgb_linear(values[63])) / (1 - srgb_linear(63 / 64))
    out[high] = srgb_linear(values[64]) + (x[high] - 1) * slope
    if np.any(mid):
        p = np.clip(srgb_encode_extended(x[mid]), 0, 1) * 64
        i = np.minimum(63, p.astype(int))
        t = p - i
        m = pchip_slopes(values)
        z = ((2 * t**3 - 3 * t**2 + 1) * values[i] + (t**3 - 2 * t**2 + t) * m[i] + (-2 * t**3 + 3 * t**2) * values[i + 1] + (t**3 - t**2) * m[i + 1])
        z = np.clip(z, np.minimum(values[i], values[i + 1]), np.maximum(values[i], values[i + 1]))
        out[mid] = srgb_linear(z)
    return out


def response(ev: float, table: np.ndarray) -> np.ndarray:
    if ev == 0:
        return np.linspace(0, 1, 65)
    last = len(table) - 1
    pos = min(float(last), max(0.0, (ev + 5.0) * last / 10.0))
    lo = min(last - 1, int(pos))
    w = pos - lo
    return table[lo] * (1 - w) + table[lo + 1] * w


TO_WIDE = np.array([[0.5292907577680172, 0.33015660364785177, 0.14055263858413108], [0.09836164805996374, 0.8734849381186465, 0.028153413821389802], [0.016866088436003183, 0.11765576165553973, 0.8654781499084571]])
FROM_WIDE = np.array([[2.0343104306914266, -0.7276094363341301, -0.30670099435729664], [-0.22880499207676658, 1.2317141502386277, -0.00290915816186133], [-0.008539365225714066, -0.1532636513148021, 1.1618030165405162]])


def current_linear(source_linear: np.ndarray, ev: float, table: np.ndarray) -> np.ndarray:
    source_linear = np.asarray(source_linear, dtype=np.float64)
    if ev == 0:
        return source_linear.copy()
    c = source_linear @ TO_WIDE.T
    low, high = c.min(axis=1, keepdims=True), c.max(axis=1, keepdims=True)
    values = response(ev, table)
    a, b = map_linear(low, values, ev), map_linear(high, values, ev)
    mapped = a + (c - low) * (b - a) / np.maximum(high - low, 1e-12)
    return mapped @ FROM_WIDE.T


def pp_to_linear_srgb(encoded: np.ndarray, pp_matrix: np.ndarray, source_matrix: np.ndarray, gamma: float) -> np.ndarray:
    pp_linear = np.power(np.clip(encoded, 0, 1), gamma)
    return pp_linear @ np.linalg.solve(source_matrix, pp_matrix).T


def require_hash(path: pathlib.Path, expected: str, label: str) -> None:
    actual = sha256(path)
    if actual != expected:
        raise ValueError(f"{label} SHA-256 mismatch: {actual} != {expected}")


def resolve_input(path: str, directory: pathlib.Path) -> pathlib.Path:
    return (directory / path).resolve()


def relative_path(path: pathlib.Path, directory: pathlib.Path) -> str:
    return os.path.relpath(path, directory)


def validate_source(item: dict[str, Any], label: str, input_dir: pathlib.Path,
                    output_dir: pathlib.Path) -> tuple[np.ndarray, bytes, np.ndarray, dict[str, Any]]:
    path = resolve_input(item["path"], input_dir)
    require_hash(path, item["sha256"], f"{label} source")
    image, icc = read_tiff(path)
    if sha256(icc) != item["icc_sha256"]:
        raise ValueError(f"{label} source ICC SHA-256 mismatch")
    levels16 = np.asarray(item["levels16"], dtype=np.int64)
    if len(levels16) != item["dimension"] or item["dimension"] != 65 or levels16[0] != 0 or levels16[-1] != 65535 or np.any(np.diff(levels16) <= 0):
        raise ValueError(f"{label} source has invalid 65-axis")
    expected_levels = np.rint(np.linspace(0, 1, 65) ** item["axis_power"] * 65535).astype(np.int64)
    if item["axis_power"] not in (1, 2) or not np.array_equal(levels16, expected_levels):
        raise ValueError(f"{label} source axis does not match its declared spacing")
    nodes = cube_nodes(image, item["dimension"], item["cell"])
    expected = grid_nodes(levels16)
    if np.max(np.abs(nodes - expected)) > 1e-12:
        raise ValueError(f"{label} source node values do not match manifest levels")
    return nodes, icc, levels16, {"path": relative_path(path, output_dir), "sha256": sha256(path), "icc_sha256": sha256(icc), "shape": list(image.shape), "axis_power": item["axis_power"], "levels16": levels16.tolist()}


def load_table(cal: dict[str, Any], input_dir: pathlib.Path,
               output_dir: pathlib.Path) -> tuple[np.ndarray, dict[str, Any]]:
    path = resolve_input(cal["table_path"], input_dir)
    require_hash(path, cal["table_sha256"], "calibration table")
    source = json.loads(path.read_text())
    table = np.asarray(source["table_code16"], dtype=np.float64)
    if table.shape != (101, 65) or np.any(table < 0) or np.any(table > 65535):
        raise ValueError(f"invalid table_code16 shape/range: {table.shape}")
    swift = resolve_input(cal["swift_path"], input_dir)
    require_hash(swift, cal["swift_sha256"], "Swift table")
    rows = []
    for line in swift.read_text().splitlines():
        if line.lstrip().startswith("[") and "//" in line:
            try:
                value = json.loads(line.split("//", 1)[0].strip().rstrip(",").replace("'", '"'))
            except Exception:
                continue
            if isinstance(value, list) and len(value) == 65 and all(isinstance(x, int) for x in value):
                rows.append(value)
    if rows != table.astype(np.int64).tolist():
        raise ValueError("Swift RasterExposure table does not match calibration table")
    values = table / 65535.0
    values[50] = np.linspace(0, 1, 65)  # Same exact neutral row as Swift/Metal.
    return values, {"table_path": relative_path(path, output_dir), "table_sha256": sha256(path), "swift_path": relative_path(swift, output_dir), "swift_sha256": sha256(swift), "rows": 101, "samples": 65}


def build(args: argparse.Namespace) -> dict[str, Any]:
    spec_path = pathlib.Path(args.input).resolve()
    input_dir = spec_path.parent
    out_dir = pathlib.Path(args.output_dir).resolve()
    spec = json.loads(spec_path.read_text())
    if spec.get("version") != 2:
        raise ValueError("expected the current quarter-EV calibration input version 2")
    table, calibration_meta = load_table(spec["calibration"], input_dir, out_dir)
    h_nodes, source_icc, h_levels, h_meta = validate_source(spec["h_source"], "H65", input_dir, out_dir)
    i_nodes, i_icc, i_levels, i_meta = validate_source(spec["i_source"], "I65", input_dir, out_dir)
    if sha256(source_icc) != sha256(i_icc):
        raise ValueError("H65 and I65 source ICC profiles differ")
    if sha256(source_icc) != "3f6d674174f3804eb0dabdac90ae17486e898c5063a66f861c116ea033da8301":
        raise ValueError("this model requires the recorded SDK sRGB source profile")
    source_matrix, source_gamma = icc_matrix_gamma(source_icc, require_gamma=False)
    if out_dir.exists():
        raise ValueError("output directory must be new")
    rows = spec["rows"]
    if len(rows) != 41 or [r["index"] for r in rows] != list(range(41)):
        raise ValueError("rows must contain indices 0..40")
    if any(float(r["ev"]) != r["index"] / 4 - 5 for r in rows):
        raise ValueError("rows must use ordered quarter EVs from -5 to +5")
    out_dir.mkdir(exist_ok=False)
    row_out: list[dict[str, Any]] = []
    target_icc_sha = None
    target_matrix = None
    target_gamma = None
    for row in rows:
        ev, power = float(row["ev"]), int(row["axis_power"])
        if power not in (1, 2) or (ev < 0 and power != 1) or (ev > 0 and power != 2) or (ev == 0 and power != 1):
            raise ValueError(f"invalid axis policy at row {row['index']}")
        source_nodes = h_nodes if power == 1 else i_nodes
        levels16 = h_levels if power == 1 else i_levels
        source_path = resolve_input(row["path"], input_dir)
        require_hash(source_path, row["sha256"], f"row {row['index']} TIFF")
        if "settings" in row:
            state = row["settings"]
            state_path = resolve_input(state["path"], input_dir)
            require_hash(state_path, state["sha256"], f"row {row['index']} develop state")
            text = json.loads(state_path.read_text())[source_path.stem]
            match = re.search(r"Exposure2012 = ([^,]+)", text)
            if match is None or abs(float(match.group(1)) - ev) > 1e-12:
                raise ValueError("saved Lightroom colour exposure does not match the declared EV")
        image, icc = read_tiff(source_path)
        if image.shape != (2116, 2080, 3):
            raise ValueError("output cube dimensions differ from its source")
        if sha256(icc) != "0a8ef7d1d958d98225b3b71d93d9e8e3cecd9c302e014973d025d2a977ecf27c":
            raise ValueError("expected the recorded Lightroom ProPhoto output profile")
        if row.get("icc_sha256") and sha256(icc) != row["icc_sha256"]:
            raise ValueError(f"row {row['index']} ICC SHA-256 mismatch")
        if target_icc_sha is None:
            target_icc_sha = sha256(icc)
            target_matrix, target_gamma = icc_matrix_gamma(icc)
        elif sha256(icc) != target_icc_sha:
            raise ValueError("row output ICC profiles differ")
        output = cube_nodes(image, 65, 4)
        input_nodes = grid_nodes(levels16)
        output_linear = pp_to_linear_srgb(output, target_matrix, source_matrix, target_gamma)
        base = current_linear(srgb_linear(input_nodes), ev, table)
        delta = np.zeros_like(output_linear) if ev == 0 else output_linear - base
        q = np.rint(delta * 65535.0)
        if np.any(q < -32768) or np.any(q > 32767):
            raise ValueError(f"row {row['index']} exceeds int16/65535: {np.max(np.abs(delta))}")
        q16 = q.astype("<i2", copy=False)
        payload = q16.tobytes(order="C")
        filename = f"row-{int(row['index']):02d}-ev-{ev:+.2f}.int16le"
        out_path = out_dir / filename
        with out_path.open("xb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        if out_path.read_bytes() != payload:
            raise ValueError("payload readback mismatch")
        row_out.append({"index": int(row["index"]), "ev": ev, "axis_power": power, "levels16": levels16.tolist(), "dimension": 65, "source_output_path": relative_path(source_path, out_dir), "source_output_sha256": sha256(source_path), "source_output_icc_sha256": sha256(icc), "source_output_shape": list(image.shape), "delta_maximum": float(np.max(np.abs(delta))), "delta_mae": float(np.mean(np.abs(delta))), "quantization_max_abs": float(np.max(np.abs(q16.astype(np.float64) / 65535.0 - delta))), "quantization_mae": float(np.mean(np.abs(q16.astype(np.float64) / 65535.0 - delta))), "int16_min": int(q16.min()), "int16_max": int(q16.max()), "payload_bytes": len(payload), "payload_sha256": sha256(payload), "file": filename, "path": filename, "file_sha256": sha256(out_path), "file_rawsha256": sha256(payload), "ev0_delta_bypass": ev == 0})
    manifest = {"format": "oh-my-lrc.product-candidate.residual-lut", "version": 2, "dimension": 65, "node_order": "R-fastest,G-next,B-slowest; serialized B,G,R,RGB", "input_space": "encoded-sRGB", "value_space": "linear-sRGB delta from current RasterExposure base", "storage": {"type": "signed little-endian int16", "scale_denominator": 65535, "decode": "int16/65535", "spatial_interpolation": "float32 trilinear", "ev_interpolation": "linear between adjacent rows", "ev0": "strict zero delta bypass"}, "axis_policy": {"negative_ev": "uniform H65", "positive_ev": "quadratic I65", "zero_ev": "uniform H65 metadata; delta is zero"}, "calibration": calibration_meta, "sources": {"h_source": h_meta, "i_source": i_meta, "source_icc_sha256": sha256(source_icc), "source_matrix": source_matrix.tolist(), "source_gamma": source_gamma, "output_icc_sha256": target_icc_sha, "output_matrix": target_matrix.tolist(), "output_gamma": target_gamma}, "rows": row_out, "metrics": None}
    manifest_path = out_dir / "manifest.json"
    if args.compare_dir:
        other = pathlib.Path(args.compare_dir).resolve()
        comparisons = []
        for row in row_out:
            a, b = out_dir / row["file"], other / row["file"]
            equal = b.is_file() and a.read_bytes() == b.read_bytes()
            comparisons.append({"file": row["file"], "expected": relative_path(b, out_dir), "equal": equal, "sha256": sha256(a)})
        manifest["readback"] = {"against": relative_path(other, out_dir), "all_equal": all(x["equal"] for x in comparisons), "rows": comparisons}
        if not manifest["readback"]["all_equal"]:
            raise ValueError("payloads differ from the explicit comparison directory")
    with manifest_path.open("x") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", help="explicit calibration input JSON")
    parser.add_argument("--output-dir", required=True, help="new output directory")
    parser.add_argument("--compare-dir", help="optional existing pack directory for byte-for-byte readback")
    args = parser.parse_args()
    manifest = build(args)
    print(json.dumps({"output": relative_path(pathlib.Path(args.output_dir).resolve() / "manifest.json", pathlib.Path.cwd()), "rows": len(manifest["rows"]), "payload_bytes": sum(x["payload_bytes"] for x in manifest["rows"]), "readback": manifest.get("readback")}, indent=2))


if __name__ == "__main__":
    main()
