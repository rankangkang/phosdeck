#!/usr/bin/env python3
"""Enforce the documentation rules in AGENTS.md (文档约定). Standard library only.

Checks tracked and untracked (non-ignored) files, so a newly written report fails
before it is committed. Run from anywhere: python3 scripts/check-docs.py
"""
import re
import subprocess
import sys
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
STATUS_MAX_LINES = 100
PROCESS_DIRS = {"handoff", "handoffs", "validation", "archive", "reports"}
DATED = re.compile(r"(19|20)\d\d[-_.]?(0[1-9]|1[0-2])[-_.]?(0[1-9]|[12]\d|3[01])")
CHANGELOG_LINE = re.compile(r"^\s*(>\s*)?(\*\*)?(更新|最新|Update[sd]?)(\*\*)?\s*[:：]")
LINK = re.compile(r"\]\(([^)\s]+)\)|(?:src|href|srcset)=\"([^\"]+)\"")

files = subprocess.run(
    ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
    cwd=repo, capture_output=True, text=True, check=True,
).stdout.splitlines()
files = [f for f in files if (repo / f).exists()]
errors = []

for f in files:
    parts = Path(f).parts
    if parts[0] not in ("docs", "design"):
        continue
    if PROCESS_DIRS & {p.lower() for p in parts[:-1]}:
        errors.append(f"{f}: 过程目录不入库（handoff/validation/archive），结果写提交说明，证据放 build/")
    if DATED.search(parts[-1]):
        errors.append(f"{f}: 文件名不带日期")

for f in files:
    if not f.endswith((".md", ".html")):
        continue
    path = repo / f
    text = path.read_text(encoding="utf-8")
    for match in LINK.finditer(text):
        target = (match.group(1) or match.group(2)).split("#")[0]
        if target and not re.match(r"[a-z]+:", target) and not (path.parent / target).exists():
            errors.append(f"{f}: 链接失效 {target}")
    if f.startswith(("docs/", "design/")) and not f.startswith("docs/research/"):
        for number, line in enumerate(text.splitlines(), 1):
            if CHANGELOG_LINE.match(line):
                errors.append(f"{f}:{number}: 不写“更新：”流水段落，直接改写成现行事实")

status = repo / "docs/STATUS.md"
if status.exists():
    count = len(status.read_text(encoding="utf-8").splitlines())
    if count > STATUS_MAX_LINES:
        errors.append(f"docs/STATUS.md: {count} 行，超过 {STATUS_MAX_LINES} 行，删掉已完成或已过时的条目")

index = repo / "docs/README.md"
index_text = index.read_text(encoding="utf-8") if index.exists() else ""
for entry in sorted({Path(f).parts[1] for f in files if f.startswith("docs/") and len(Path(f).parts) > 1}):
    if entry == "README.md":
        continue
    if f"({entry})" not in index_text and f"({entry}/" not in index_text:
        errors.append(f"docs/{entry}: 未在 docs/README.md 登记")

if errors:
    print("文档检查失败（规则见 AGENTS.md 文档约定）：", file=sys.stderr)
    for error in errors:
        print("  " + error, file=sys.stderr)
    sys.exit(1)
print("文档检查通过")
