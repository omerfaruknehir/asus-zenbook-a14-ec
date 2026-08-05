#!/usr/bin/env python3
"""Remove fabricated MSM/Adreno media-engine readings from Resources.

The upstream MSM DRM fdinfo ABI exposes the GPU engine only. Qualcomm's Iris
video codec is a separate V4L2 device and currently exposes no standard encoder
or decoder busy-percentage ABI. Keep unsupported values unavailable rather than
reporting a false idle 0%.
"""

from __future__ import annotations

import argparse
import difflib
import re
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

MSM_RS = Path("src/utils/gpu/msm.rs")

METHOD_RE = re.compile(
    r"(?P<indent>^[ \t]*)fn (?P<name>encode_usage|decode_usage)"
    r"\(&self\) -> Result<f64> \{.*?^(?P=indent)\}",
    re.MULTILINE | re.DOTALL,
)


def replacement(match: re.Match[str]) -> str:
    indent = match.group("indent")
    name = match.group("name")
    label = "encode" if name == "encode_usage" else "decode"
    return (
        f"{indent}fn {name}(&self) -> Result<f64> {{\n"
        f'{indent}    bail!("{label} usage not exposed for MSM/Adreno")\n'
        f"{indent}}}"
    )


def repair(text: str) -> str:
    matches = list(METHOD_RE.finditer(text))
    names = {match.group("name") for match in matches}
    if names != {"encode_usage", "decode_usage"}:
        raise RuntimeError(
            "expected MSM encode_usage and decode_usage implementations; "
            f"found {sorted(names)}"
        )

    changed = METHOD_RE.sub(replacement, text)

    if "fn vram_frequency(&self) -> Result<f64>" not in changed:
        raise RuntimeError("MSM vram_frequency implementation is missing")
    if "fn power_usage(&self) -> Result<f64>" not in changed:
        raise RuntimeError("MSM power_usage implementation is missing")

    return changed


def apply(repo: Path, dry_run: bool = False) -> int:
    path = repo / MSM_RS
    if not path.is_file():
        raise RuntimeError(
            "MSM/Adreno Resources backend is not present; apply the A14 MSM patch first"
        )

    original = path.read_text()
    changed = repair(original)
    if changed == original:
        print("Resources MSM/Adreno unsupported metrics already use N/A.")
        return 0

    diff = "".join(
        difflib.unified_diff(
            original.splitlines(keepends=True),
            changed.splitlines(keepends=True),
            fromfile=f"a/{MSM_RS}",
            tofile=f"b/{MSM_RS}",
        )
    )

    if dry_run:
        sys.stdout.write(diff)
        return 0

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = path.with_name(f"msm.rs.a14-metrics-backup-{timestamp}")
    patch = repo / f"resources-a14-gpu-metrics-repair-{timestamp}.patch"
    shutil.copy2(path, backup)
    path.write_text(changed)
    patch.write_text(diff)

    print("Removed fabricated MSM/Adreno encoder and decoder 0% readings.")
    print("Unsupported video-engine usage will now be N/A.")
    print("VRAM frequency and GPU power remain N/A unless the kernel exposes them.")
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
