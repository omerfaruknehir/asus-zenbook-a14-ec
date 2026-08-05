#!/usr/bin/env python3
"""Repair physical-core counting in an already-patched Resources checkout."""

from __future__ import annotations

import argparse
import difflib
import re
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

CPU_RS = Path("src/utils/cpu.rs")

FUNCTION_RE = re.compile(
    r"fn linux_cpu_topology\(online_cpus: &\[usize\]\) "
    r"-> \(Option<usize>, Option<usize>\) \{.*?\n\}\n\n"
    r"(?=fn linux_cpu_max_speed)",
    re.DOTALL,
)

NEW_FUNCTION = r'''fn linux_cpu_topology(online_cpus: &[usize]) -> (Option<usize>, Option<usize>) {
    let mut physical_cores = BTreeSet::new();
    let mut packages = BTreeSet::new();

    for cpu in online_cpus {
        let topology = format!("/sys/devices/system/cpu/cpu{cpu}/topology");

        if let Some(package) = read_linux_usize(format!("{topology}/physical_package_id")) {
            packages.insert(package);
        }

        // core_id is only unique inside a topology cluster on some ARM64
        // systems. Counting it globally collapsed the A14's 12 Oryon cores to
        // four. A physical core is represented by one unique thread-sibling
        // mask; on this no-SMT platform each mask contains one online CPU.
        let siblings = ["thread_siblings_list", "core_cpus_list"]
            .iter()
            .find_map(|attribute| {
                std::fs::read_to_string(format!("{topology}/{attribute}")).ok()
            })
            .map(|value| parse_linux_cpu_list(&value))
            .unwrap_or_default();

        if !siblings.is_empty() {
            physical_cores.insert(siblings);
        }
    }

    (
        (!physical_cores.is_empty()).then_some(physical_cores.len()),
        (!packages.is_empty()).then_some(packages.len()),
    )
}

'''


def repair(text: str) -> str:
    match = FUNCTION_RE.search(text)
    if not match:
        raise RuntimeError("linux_cpu_topology helper was not found")

    current = match.group(0)
    if "thread_siblings_list" in current:
        return text

    return text[: match.start()] + NEW_FUNCTION + text[match.end() :]


def apply(repo: Path, dry_run: bool = False) -> int:
    path = repo / CPU_RS
    if not path.is_file():
        raise RuntimeError("not a Resources source checkout")

    original = path.read_text()
    changed = repair(original)
    if changed == original:
        print("Resources A14 CPU topology is already correct.")
        return 0

    diff = "".join(
        difflib.unified_diff(
            original.splitlines(keepends=True),
            changed.splitlines(keepends=True),
            fromfile=f"a/{CPU_RS}",
            tofile=f"b/{CPU_RS}",
        )
    )

    if dry_run:
        sys.stdout.write(diff)
        return 0

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = path.with_name(f"cpu.rs.a14-topology-backup-{timestamp}")
    patch = repo / f"resources-a14-topology-repair-{timestamp}.patch"
    shutil.copy2(path, backup)
    path.write_text(changed)
    patch.write_text(diff)

    print("Repaired Resources A14 physical-core topology.")
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
