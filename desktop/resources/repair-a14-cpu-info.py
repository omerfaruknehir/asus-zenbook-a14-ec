#!/usr/bin/env python3
"""Repair an already-applied A14 Resources CPU-information source patch."""

from __future__ import annotations

import argparse
import difflib
import re
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

CPU_PAGE = Path("src/ui/pages/cpu.rs")
CPU_UI = Path("data/resources/ui/pages/cpu.ui")
FIELD_RE = re.compile(
    r"(?m)^(?P<indent>[ \t]*)pub microarchitecture: "
    r"TemplateChild<adw::ActionRow>,[ \t]*$"
)


def repair_page(text: str) -> str:
    matches = list(FIELD_RE.finditer(text))
    if len(matches) != 1:
        raise RuntimeError(
            "expected exactly one microarchitecture TemplateChild field; "
            f"found {len(matches)}"
        )

    match = matches[0]
    line_start = match.start()
    previous_end = line_start
    previous_start = text.rfind("\n", 0, max(0, previous_end - 1)) + 1
    previous = text[previous_start:previous_end].strip()

    if previous == "#[template_child]":
        return text

    indent = match.group("indent")
    return text[:line_start] + f"{indent}#[template_child]\n" + text[line_start:]


def apply(repo: Path, dry_run: bool = False) -> int:
    page = repo / CPU_PAGE
    ui = repo / CPU_UI
    if not page.is_file() or not ui.is_file():
        raise RuntimeError("not a Resources source checkout")

    ui_text = ui.read_text()
    if 'id="microarchitecture"' not in ui_text:
        raise RuntimeError(
            "the A14 CPU-information patch is not applied: "
            "microarchitecture UI row is missing"
        )

    original = page.read_text()
    repaired = repair_page(original)
    if repaired == original:
        print("Resources A14 template metadata is already correct.")
        return 0

    diff = "".join(
        difflib.unified_diff(
            original.splitlines(keepends=True),
            repaired.splitlines(keepends=True),
            fromfile=f"a/{CPU_PAGE}",
            tofile=f"b/{CPU_PAGE}",
        )
    )

    if dry_run:
        sys.stdout.write(diff)
        return 0

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = page.with_name(f"cpu.rs.a14-template-backup-{timestamp}")
    patch = repo / f"resources-a14-template-repair-{timestamp}.patch"
    shutil.copy2(page, backup)
    page.write_text(repaired)
    patch.write_text(diff)

    print("Repaired Resources A14 template metadata.")
    print(f"Backup: {backup}")
    print(f"Patch:  {patch}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("repo", nargs="?", default=".")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    try:
        return apply(Path(args.repo).expanduser().resolve(), args.dry_run)
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
