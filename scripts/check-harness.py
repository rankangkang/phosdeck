#!/usr/bin/env python3
"""Verify AI harness invariants, architecture boundaries, and doc/code sync.

Standard library only. Complementary to scripts/check-docs.py (which enforces
documentation hygiene). Run from anywhere: python3 scripts/check-harness.py
"""
from collections import defaultdict
from pathlib import Path
import json
import re
import subprocess
import sys

REPO = Path(__file__).resolve().parent.parent

AGENTS_MAX_LINES = 120
AGENTS_MAX_CHARS = 5500
STATUS_MAX_LINES = 100
STATUS_MAX_CHARS = 10500
STATUS_MAX_LINE_CHARS = 420

NON_UI_DIRS = {"Files", "Catalog", "Imaging", "Import", "Export", "Plugins"}
UI_MODULES = {"SwiftUI", "AppKit"}
APP_ONLY_MODULES = {"MCP", "NIOCore", "NIOHTTP1", "NIOPosix"}
IMAGING_ONLY_MODULES = {"LibRawRuntime", "CLiteRT", "CoreML", "Vision"}


def git_tracked_and_untracked() -> list[str]:
    out = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
        cwd=REPO,
        text=True,
    )
    return [f for f in out.splitlines() if (REPO / f).exists()]


def github_slug(heading: str) -> str:
    s = heading.strip().lower()
    s = re.sub(r"[`*_~]", "", s)
    s = re.sub(r"[^\w\s-]", "", s, flags=re.U)
    s = re.sub(r" ", "-", s)
    return s


def check_pbxproj_registration(errors: list[str]) -> None:
    pbx_path = REPO / "Phosdeck.xcodeproj/project.pbxproj"
    if not pbx_path.exists():
        errors.append("缺少 Phosdeck.xcodeproj/project.pbxproj")
        return
    pbx = pbx_path.read_text(encoding="utf-8")
    for base_dir in ("Sources", "Tests"):
        root = REPO / base_dir
        if not root.exists():
            continue
        for swift_file in sorted(root.rglob("*.swift")):
            rel = swift_file.relative_to(REPO).as_posix()
            if swift_file.name not in pbx:
                errors.append(f"{rel}: 未在 Phosdeck.xcodeproj/project.pbxproj 中登记")


def check_architecture_imports(errors: list[str]) -> None:
    sources_root = REPO / "Sources"
    for swift_file in sorted(sources_root.rglob("*.swift")):
        rel = swift_file.relative_to(sources_root)
        layer = rel.parts[0]
        text = swift_file.read_text(encoding="utf-8", errors="ignore")
        imports = set(re.findall(r"^\s*import\s+([A-Za-z0-9_]+)", text, re.M))

        if layer in NON_UI_DIRS:
            bad_ui = sorted(imports & UI_MODULES)
            if bad_ui:
                errors.append(
                    f"Sources/{rel.as_posix()}: 非表现层禁止 import {', '.join(bad_ui)}（见 docs/architecture.md）"
                )
        if layer != "App":
            bad_app = sorted(imports & APP_ONLY_MODULES)
            if bad_app:
                errors.append(
                    f"Sources/{rel.as_posix()}: 仅 Sources/App 允许 import {', '.join(bad_app)}（见 docs/architecture.md）"
                )
        if layer != "Imaging":
            bad_img = sorted(imports & IMAGING_ONLY_MODULES)
            if bad_img:
                errors.append(
                    f"Sources/{rel.as_posix()}: 仅 Sources/Imaging 允许 import {', '.join(bad_img)}（见 docs/architecture.md）"
                )


def check_schema_version_sync(errors: list[str]) -> None:
    store = REPO / "Sources/Catalog/CatalogStore.swift"
    status = REPO / "docs/STATUS.md"
    arch = REPO / "docs/architecture.md"
    if not store.exists():
        return
    m = re.search(r"schemaVersion\s*=\s*(\d+)", store.read_text(encoding="utf-8"))
    if not m:
        errors.append("Sources/Catalog/CatalogStore.swift: 未找到 schemaVersion 定义")
        return
    actual = m.group(1)
    for doc_path, pattern in (
        (status, r"schema\s+(\d+)"),
        (arch, r"schemaVersion\s*=\s*(\d+)"),
    ):
        if not doc_path.exists():
            continue
        dm = re.search(pattern, doc_path.read_text(encoding="utf-8"))
        if dm and dm.group(1) != actual:
            rel = doc_path.relative_to(REPO).as_posix()
            errors.append(
                f"{rel}: 声明 schema {dm.group(1)}，与 CatalogStore.schemaVersion = {actual} 不一致"
            )


def check_context_budgets(errors: list[str]) -> None:
    agents = REPO / "AGENTS.md"
    if agents.exists():
        text = agents.read_text(encoding="utf-8")
        lines = text.splitlines()
        chars = len(text)
        if len(lines) > AGENTS_MAX_LINES:
            errors.append(
                f"AGENTS.md: {len(lines)} 行，超过入口地图上限 {AGENTS_MAX_LINES} 行；细节请下沉到 docs/"
            )
        if chars > AGENTS_MAX_CHARS:
            errors.append(
                f"AGENTS.md: {chars} 字符，超过入口地图上限 {AGENTS_MAX_CHARS} 字符；细节请下沉到 docs/"
            )

    status = REPO / "docs/STATUS.md"
    if status.exists():
        text = status.read_text(encoding="utf-8")
        lines = text.splitlines()
        chars = len(text)
        if len(lines) > STATUS_MAX_LINES:
            errors.append(f"docs/STATUS.md: {len(lines)} 行，超过 {STATUS_MAX_LINES} 行")
        if chars > STATUS_MAX_CHARS:
            errors.append(
                f"docs/STATUS.md: {chars} 字符，超过 {STATUS_MAX_CHARS} 字符；压缩历史过程记录，只留现行状态"
            )
        for lineno, line in enumerate(lines, 1):
            if len(line) > STATUS_MAX_LINE_CHARS:
                errors.append(
                    f"docs/STATUS.md:{lineno}: 单行 {len(line)} 字符，超过 {STATUS_MAX_LINE_CHARS} 字符（禁止用超长段绕过行数限制）"
                )

    claude = REPO / "CLAUDE.md"
    if claude.exists():
        if "AGENTS.md" not in claude.read_text(encoding="utf-8"):
            errors.append("CLAUDE.md: 必须指向 AGENTS.md 作为唯一事实源")


def check_markdown_anchors(files: list[str], errors: list[str]) -> None:
    md_files = [REPO / f for f in files if f.endswith(".md")]
    anchors_by_file: dict[Path, set[str]] = {}
    for p in md_files:
        text = p.read_text(encoding="utf-8", errors="ignore")
        slugs: set[str] = set()
        counts: dict[str, int] = defaultdict(int)
        in_code = False
        for line in text.splitlines():
            if line.strip().startswith("```"):
                in_code = not in_code
                continue
            if in_code:
                continue
            hm = re.match(r"^#{1,6}\s+(.+?)\s*#*\s*$", line)
            if hm:
                base = github_slug(hm.group(1))
                slug = base if counts[base] == 0 else f"{base}-{counts[base]}"
                slugs.add(slug)
                counts[base] += 1
        anchors_by_file[p.resolve()] = slugs

    link_re = re.compile(r"\]\(([^)\s]+)\)")
    for p in md_files:
        rel = p.relative_to(REPO).as_posix()
        text = p.read_text(encoding="utf-8", errors="ignore")
        in_code = False
        for lineno, line in enumerate(text.splitlines(), 1):
            if line.strip().startswith("```"):
                in_code = not in_code
                continue
            if in_code:
                continue
            for m in link_re.finditer(line):
                raw = m.group(1)
                if re.match(r"[a-z]+:", raw):
                    continue
                if "#" in raw:
                    file_part, anchor = raw.split("#", 1)
                else:
                    file_part, anchor = raw, ""
                target = (p.parent / file_part).resolve() if file_part else p.resolve()
                if not target.exists():
                    errors.append(f"{rel}:{lineno}: 链接目标不存在 {raw}")
                    continue
                if anchor and target.is_file() and target in anchors_by_file:
                    if anchor.lower() not in anchors_by_file[target]:
                        errors.append(f"{rel}:{lineno}: 锚点不存在 {raw}")


def check_project_yml_resources(errors: list[str]) -> None:
    yml = REPO / "project.yml"
    if not yml.exists():
        return
    text = yml.read_text(encoding="utf-8")
    for m in re.finditer(r"^\s*-\s*path:\s*(docs/references/[^\s]+)", text, re.M):
        ref_path = m.group(1)
        if not (REPO / ref_path).exists():
            errors.append(f"project.yml: 声明的许可/参考资源不存在 {ref_path}")


def check_test_map_sync(errors: list[str]) -> None:
    arch = REPO / "docs/architecture.md"
    tests_dir = REPO / "Tests"
    if not arch.exists() or not tests_dir.exists():
        return
    actual = {p.stem for p in tests_dir.glob("*Tests.swift")}
    listed = set(re.findall(r"`([A-Za-z0-9]+Tests)`", arch.read_text(encoding="utf-8")))
    for missing in sorted(actual - listed):
        errors.append(f"docs/architecture.md: 测试映射表缺少 Tests/{missing}.swift")
    for stale in sorted(listed - actual):
        errors.append(f"docs/architecture.md: 测试映射表引用了不存在的 {stale}")


def check_design_token_sync(errors: list[str]) -> None:
    tokens_path = REPO / "design/darkroom_instrument_tokens_v3.json"
    theme_path = REPO / "Sources/UI/DarkroomTheme.swift"
    if not tokens_path.exists() or not theme_path.exists():
        return
    tokens = json.loads(tokens_path.read_text(encoding="utf-8"))
    swift = theme_path.read_text(encoding="utf-8")

    pairs = {
        m.group(1): (f"#{m.group(2).upper()}", f"#{m.group(3).upper()}")
        for m in re.finditer(
            r"static let (\w+)\s*=\s*pair\(0x([0-9A-Fa-f]{6}),\s*0x([0-9A-Fa-f]{6})\)",
            swift,
        )
    }
    hexes = {
        m.group(1): f"#{m.group(2).upper()}"
        for m in re.finditer(r"static let (\w+)\s*=\s*hex\(0x([0-9A-Fa-f]{6})\)", swift)
    }

    ivory = tokens["themes"]["ivory"]["colors"]
    graphite = tokens["themes"]["graphite"]["colors"]
    shared = tokens["sharedColors"]

    theme_pair_map = {
        "surfaceBase": "surface.base",
        "surfacePanel": "surface.panel",
        "surfaceRaised": "surface.raised",
        "surfaceInset": "surface.inset",
        "surfaceSelected": "surface.selected",
        "plateTop": "plate.top",
        "plateBottom": "plate.bottom",
        "textPrimary": "text.primary",
        "textSecondary": "text.secondary",
        "textDisabled": "text.disabled",
        "separator": "border.separator",
        "seamLight": "border.seamLight",
        "controlBorder": "border.control",
        "accentText": "accent.text",
        "accentSignal": "accent.signal",
        "focusRing": "focus.ring",
        "error": "status.error",
        "success": "status.success",
        "warning": "status.warning",
        "lampOn": "lamp.on",
        "lampSocket": "lamp.socket",
        "lampOff": "lamp.off",
        "capTop": "cap.top",
        "capBottom": "cap.bottom",
        "materialEdge": "material.edge",
        "knobRimTop": "knob.rimTop",
        "knobRimBottom": "knob.rimBottom",
        "keyLip": "key.lip",
        "keyLipSelected": "key.lipSelected",
        "keyHeld": "key.held",
        "keyTop": "key.top",
        "keyBottom": "key.bottom",
    }
    theme_single_map = {
        "keyPrimaryLip": "key.primaryLip",
        "keyPrimary": "key.primary",
        "keyPrimaryTop": "key.primaryTop",
        "keyPrimaryBottom": "key.primaryBottom",
        "keyPrimaryText": "key.primaryText",
        "keyPrimaryEdge": "key.primaryEdge",
    }
    shared_map = {
        "lampSpecular": "lamp.specular",
        "labelRed": "photoLabel.red",
        "labelYellow": "photoLabel.yellow",
        "labelGreen": "photoLabel.green",
        "labelBlue": "photoLabel.blue",
        "labelPurple": "photoLabel.purple",
        "scopeBackground": "scope.background",
        "scopeBezel": "scope.bezel",
        "scopeGrid": "scope.grid",
        "scopeAxis": "scope.axis",
        "scopeText": "scope.text",
        "scopeLampOff": "scope.lamp.off",
        "traceNeutral": "scope.trace.neutral",
        "traceActive": "scope.trace.active",
        "traceRed": "scope.trace.red",
        "traceGreen": "scope.trace.green",
        "traceBlue": "scope.trace.blue",
        "clipHighlight": "photoOverlay.clipHighlight",
        "clipShadow": "photoOverlay.clipShadow",
        "overlayLight": "photoOverlay.light",
        "overlayDark": "photoOverlay.dark",
    }

    for swift_name, token_key in theme_pair_map.items():
        if swift_name not in pairs:
            errors.append(f"Sources/UI/DarkroomTheme.swift: 缺少 Palette.{swift_name}（对应 {token_key}）")
            continue
        iv, gr = pairs[swift_name]
        if ivory.get(token_key, "").upper() != iv or graphite.get(token_key, "").upper() != gr:
            errors.append(
                f"设计 Token 不同步: Palette.{swift_name}=({iv}, {gr}) != {token_key}=({ivory.get(token_key)}, {graphite.get(token_key)})"
            )

    for swift_name, token_key in theme_single_map.items():
        if swift_name not in hexes:
            errors.append(f"Sources/UI/DarkroomTheme.swift: 缺少 Palette.{swift_name}（对应 {token_key}）")
            continue
        val = hexes[swift_name]
        if ivory.get(token_key, "").upper() != val or graphite.get(token_key, "").upper() != val:
            errors.append(
                f"设计 Token 不同步: Palette.{swift_name}={val} != {token_key}=({ivory.get(token_key)}, {graphite.get(token_key)})"
            )

    for swift_name, token_key in shared_map.items():
        if swift_name not in hexes:
            errors.append(f"Sources/UI/DarkroomTheme.swift: 缺少 Palette.{swift_name}（对应 sharedColors.{token_key}）")
            continue
        val = hexes[swift_name]
        if shared.get(token_key, "").upper() != val:
            errors.append(
                f"设计 Token 不同步: Palette.{swift_name}={val} != sharedColors.{token_key}={shared.get(token_key)}"
            )

    for extra in sorted(set(pairs) - set(theme_pair_map)):
        errors.append(f"Sources/UI/DarkroomTheme.swift: Palette.{extra} 未在 check-harness.py 与 design/darkroom_instrument_tokens_v3.json 中登记同步")
    for extra in sorted(set(hexes) - set(theme_single_map) - set(shared_map)):
        errors.append(f"Sources/UI/DarkroomTheme.swift: Palette.{extra} 未在 check-harness.py 与 design/darkroom_instrument_tokens_v3.json 中登记同步")

    metrics_match = re.search(r"enum Metrics \{([\s\S]*?)\n\}", swift)
    if not metrics_match:
        errors.append("Sources/UI/DarkroomTheme.swift: 未找到 enum Metrics")
        return
    metrics_body = metrics_match.group(1)

    scalar_metrics = {
        m.group(1): float(m.group(2))
        for m in re.finditer(r"static let (\w+)(?::\s*CGFloat)?\s*=\s*(-?\d+(?:\.\d+)?)\b", metrics_body)
    }
    layout = tokens["layout"]
    radius = tokens["radius"]
    comps = tokens["components"]
    scalar_map = {
        "topBar": ("layout.topBarHeight", layout["topBarHeight"]),
        "topBarKeyLine": ("layout.topBarKeyCenterFromTop", layout["topBarKeyCenterFromTop"]),
        "photoInfoBar": ("layout.photoInfoBarHeight", layout["photoInfoBarHeight"]),
        "rim": ("layout.chassisRim", layout["chassisRim"]),
        "toolbar": ("layout.centerToolbarHeight", layout["centerToolbarHeight"]),
        "statusBar": ("layout.statusBarHeight", layout["statusBarHeight"]),
        "photoDisplayBezel": ("components.photoDisplayFrame.width", comps["photoDisplayFrame"]["width"]),
        "importDuplicateShade": ("components.thumbnail.importDuplicateShadeOpacity", comps["thumbnail"]["importDuplicateShadeOpacity"]),
        "photoMinWidth": ("layout.photoViewportMinWidth", layout["photoViewportMinWidth"]),
        "cameraLookDockWidth": ("layout.cameraLookDockWidth", layout["cameraLookDockWidth"]),
        "compactMaskWindowHeight": ("layout.compactMaskWindowHeightExclusive", layout["compactMaskWindowHeightExclusive"]),
        "padding": ("layout.panelPadding", layout["panelPadding"]),
        "sectionHeader": ("layout.sectionHeaderHeight", layout["sectionHeaderHeight"]),
        "row": ("layout.parameterRowHeight.default", layout["parameterRowHeight"]["default"]),
        "rowLabel": ("layout.parameterColumnsAtDefaultInspector.label", layout["parameterColumnsAtDefaultInspector"]["label"]),
        "rowValue": ("layout.parameterColumnsAtDefaultInspector.value", layout["parameterColumnsAtDefaultInspector"]["value"]),
        "rowUnit": ("layout.parameterColumnsAtDefaultInspector.unitWithinValue", layout["parameterColumnsAtDefaultInspector"]["unitWithinValue"]),
        "gap": ("layout.parameterColumnsAtDefaultInspector.gap1", layout["parameterColumnsAtDefaultInspector"]["gap1"]),
        "key": ("components.key.defaultHeight", comps["key"]["defaultHeight"]),
        "keyRadius": ("radius.key", radius["key"]),
        "inputRadius": ("radius.input", radius["input"]),
        "scopeRadius": ("radius.scope", radius["scope"]),
        "lamp": ("components.lamp.diameter", comps["lamp"]["diameter"]),
        "switchTravel": ("components.toggle.capTravel", comps["toggle"]["capTravel"]),
        "leverTravel": ("components.leverSwitch.capTravel", comps["leverSwitch"]["capTravel"]),
    }
    for swift_name, (token_path, expected) in scalar_map.items():
        actual = scalar_metrics.get(swift_name)
        if actual is None:
            errors.append(f"Sources/UI/DarkroomTheme.swift: 缺少 Metrics.{swift_name}（对应 {token_path}）")
        elif abs(actual - float(expected)) > 1e-6:
            errors.append(f"设计尺寸不同步: Metrics.{swift_name}={actual:g} != {token_path}={expected}")

    size_metrics = {
        m.group(1): (float(m.group(2)), float(m.group(3)))
        for m in re.finditer(
            r"static let (\w+)\s*=\s*CGSize\(width:\s*(\d+(?:\.\d+)?),\s*height:\s*(\d+(?:\.\d+)?)\)",
            metrics_body,
        )
    }
    size_map = {
        "focusMark": ("stroke.focusMark", (tokens["stroke"]["focusMarkWidthPt"], tokens["stroke"]["focusMarkHeightPt"])),
        "switchTrack": ("components.toggle", (comps["toggle"]["width"], comps["toggle"]["height"])),
        "switchCap": ("components.toggle.cap", (comps["toggle"]["capWidth"], comps["toggle"]["capHeight"])),
        "leverTrack": ("components.leverSwitch", (comps["leverSwitch"]["width"], comps["leverSwitch"]["height"])),
        "leverCap": ("components.leverSwitch.cap", (comps["leverSwitch"]["capWidth"], comps["leverSwitch"]["capHeight"])),
    }
    for swift_name, (token_path, expected) in size_map.items():
        actual = size_metrics.get(swift_name)
        if actual is None:
            errors.append(f"Sources/UI/DarkroomTheme.swift: 缺少 Metrics.{swift_name}（对应 {token_path}）")
        elif abs(actual[0] - float(expected[0])) > 1e-6 or abs(actual[1] - float(expected[1])) > 1e-6:
            errors.append(f"设计尺寸不同步: Metrics.{swift_name}={actual} != {token_path}={expected}")

    audit_meta = tokens.get("contrastAudit", {})
    audit_rel = audit_meta.get("auditFile")
    if audit_rel:
        audit_path = REPO / audit_rel
        if not audit_path.exists():
            errors.append(f"design/darkroom_instrument_tokens_v3.json: contrastAudit.auditFile 不存在 {audit_rel}")
        else:
            audit_data = json.loads(audit_path.read_text(encoding="utf-8"))
            pairs_count = len(audit_data.get("pairs", []))
            if audit_meta.get("checkedPairCount") != pairs_count:
                errors.append(
                    f"{audit_rel}: pairs 数量 ({pairs_count}) 与 tokens.contrastAudit.checkedPairCount ({audit_meta.get('checkedPairCount')}) 不一致"
                )


def check_ui_design_guards(errors: list[str]) -> None:
    ui_dir = REPO / "Sources/UI"
    if not ui_dir.exists():
        return
    max_overlay_radius = 4.0
    rules = [
        (
            re.compile(r"\bSlider\s*\("),
            "禁止使用原生 Slider，请改用 AdjustmentRow / GradientAdjustmentSlider / DetentSlider（见 design/darkroom_instrument_design_system_v3.md）",
        ),
        (
            re.compile(r"\bGroupBox\b|\.(?:ultraThin|thin|regular|thick|ultraThick)Material\b"),
            "禁止使用 GroupBox 或系统玻璃 Material，请改用 InstrumentPlate() 与 Seam() / Hairline()",
        ),
        (
            re.compile(r"\.buttonStyle\(\s*\.(?:bordered|borderedProminent)\b"),
            "禁止使用系统 bordered/borderedProminent 按钮样式，请改用 .key / .ghostTool / PrimaryKeyStyle",
        ),
        (
            re.compile(r"\.toggleStyle\(\s*\.switch\b"),
            "禁止使用系统 .switch 开关样式，请改用 .toggleStyle(.instrument) 或 .latchingKey",
        ),
        (
            re.compile(
                r"\bColor\.accentColor\b|\.foregroundStyle\(\s*\.(?:accentColor|secondary|primary|blue|orange|yellow|purple|pink|gray)\b"
            ),
            "禁止使用系统强调色或裸语义色，请改用 Theme.* 或 PhotoMat（mat.text / mat.textSecondary）",
        ),
    ]
    radius_re = re.compile(r"RoundedRectangle\(\s*cornerRadius:\s*(\d+(?:\.\d+)?)\b")

    for swift_file in sorted(ui_dir.rglob("*.swift")):
        rel = swift_file.relative_to(REPO).as_posix()
        text = swift_file.read_text(encoding="utf-8", errors="ignore")
        if swift_file.name.endswith("Sheet.swift") and ".instrumentForm()" not in text:
            errors.append(
                f"{rel}: 独立表单/弹窗须在根节点应用 .instrumentForm()（见 design/darkroom_instrument_design_system_v3.md）"
            )
        for lineno, raw_line in enumerate(text.splitlines(), 1):
            code = re.sub(r"//.*$", "", raw_line)
            if not code.strip():
                continue
            for pattern, message in rules:
                if pattern.search(code):
                    errors.append(f"{rel}:{lineno}: {message}")
            for m in radius_re.finditer(code):
                val = float(m.group(1))
                if val > max_overlay_radius:
                    errors.append(
                        f"{rel}:{lineno}: RoundedRectangle(cornerRadius: {m.group(1)}) 超过 customOverlayMaximum ({int(max_overlay_radius)} pt)"
                    )


def main() -> int:
    errors: list[str] = []
    files = git_tracked_and_untracked()
    check_pbxproj_registration(errors)
    check_architecture_imports(errors)
    check_schema_version_sync(errors)
    check_context_budgets(errors)
    check_markdown_anchors(files, errors)
    check_project_yml_resources(errors)
    check_test_map_sync(errors)
    check_design_token_sync(errors)
    check_ui_design_guards(errors)

    if errors:
        print("AI 基建与架构检查失败：", file=sys.stderr)
        for err in errors:
            print("  " + err, file=sys.stderr)
        return 1
    print("AI 基建与架构检查通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
