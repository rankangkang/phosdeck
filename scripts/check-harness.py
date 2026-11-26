#!/usr/bin/env python3
"""Verify AI harness invariants, architecture boundaries, and doc/code sync.

Standard library only. Complementary to scripts/check-docs.py (which enforces
documentation hygiene). Run from anywhere: python3 scripts/check-harness.py
"""
from collections import defaultdict
from pathlib import Path
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

    if errors:
        print("AI 基建与架构检查失败：", file=sys.stderr)
        for err in errors:
            print("  " + err, file=sys.stderr)
        return 1
    print("AI 基建与架构检查通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
