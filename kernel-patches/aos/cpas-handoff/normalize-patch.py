#!/usr/bin/env python3
"""Normalize unified-diff hunk counts without changing patch content."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

HUNK = re.compile(
    r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$"
)


def normalize(text: str) -> str:
    lines = text.splitlines(keepends=True)
    out: list[str] = []
    i = 0

    while i < len(lines):
        raw = lines[i]
        line = raw.rstrip("\r\n")
        match = HUNK.match(line)
        if not match:
            out.append(raw)
            i += 1
            continue

        j = i + 1
        old_count = 0
        new_count = 0
        while j < len(lines):
            candidate = lines[j]
            if candidate.startswith("@@ ") or candidate.startswith("diff --git "):
                break
            if candidate.startswith("-- ") and candidate.rstrip("\r\n") == "-- ":
                break
            if not candidate:
                break

            prefix = candidate[0]
            if prefix == " ":
                old_count += 1
                new_count += 1
            elif prefix == "-":
                old_count += 1
            elif prefix == "+":
                new_count += 1
            elif prefix == "\\":
                pass
            else:
                break
            j += 1

        old_start, _, new_start, _, suffix = match.groups()
        newline = "\r\n" if raw.endswith("\r\n") else "\n"
        out.append(
            f"@@ -{old_start},{old_count} +{new_start},{new_count} @@{suffix}{newline}"
        )
        out.extend(lines[i + 1 : j])
        i = j

    return "".join(out)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("patches", nargs="+", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    changed = False
    for path in args.patches:
        original = path.read_text()
        normalized = normalize(original)
        if normalized != original:
            changed = True
            if not args.check:
                path.write_text(normalized)
        print(f"{'needs-normalization' if normalized != original else 'ok'}: {path}")

    return 1 if args.check and changed else 0


if __name__ == "__main__":
    raise SystemExit(main())
