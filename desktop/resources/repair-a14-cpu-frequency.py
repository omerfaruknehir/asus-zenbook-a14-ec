#!/usr/bin/env python3
"""Repair CPU frequency reporting in an existing custom Resources A14 tree.

This intentionally touches only src/utils/cpu.rs frequency code. It preserves
all other A14/Qualcomm Resources changes (GPU backend, temperature sensors,
model/topology polish, UI changes, etc.).
"""

from __future__ import annotations

import argparse
import difflib
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

CPU_RS = Path("src/utils/cpu.rs")
MARKER = "A14_RESOURCES_CPU_FREQ_REPAIR_V1"

HELPERS = r'''
// A14_RESOURCES_CPU_FREQ_REPAIR_V1
fn a14_parse_cpu_list(list: &str) -> Vec<usize> {
    let mut cpus = Vec::new();
    for item in list.trim().split(',').map(str::trim).filter(|item| !item.is_empty()) {
        if let Some((start, end)) = item.split_once('-') {
            if let (Ok(start), Ok(end)) = (start.parse::<usize>(), end.parse::<usize>()) {
                if start <= end {
                    cpus.extend(start..=end);
                }
            }
        } else if let Ok(cpu) = item.parse::<usize>() {
            cpus.push(cpu);
        }
    }
    cpus.sort_unstable();
    cpus.dedup();
    cpus
}

fn a14_read_u64<P: AsRef<Path>>(path: P) -> Option<u64> {
    std::fs::read_to_string(path).ok()?.trim().parse().ok()
}

fn a14_policy_for_cpu(cpu: usize) -> Option<PathBuf> {
    let direct = PathBuf::from(format!("/sys/devices/system/cpu/cpu{cpu}/cpufreq"));
    if direct.is_dir() {
        return Some(direct);
    }

    for policy in glob("/sys/devices/system/cpu/cpufreq/policy*").ok()?.flatten() {
        for member_file in ["affected_cpus", "related_cpus"] {
            let members = std::fs::read_to_string(policy.join(member_file))
                .map(|value| a14_parse_cpu_list(&value))
                .unwrap_or_default();
            if members.contains(&cpu) {
                return Some(policy);
            }
        }
    }
    None
}

fn a14_policy_current_khz(policy: &Path) -> Option<u64> {
    // qcom-cpufreq-hw can expose hardware feedback as cpuinfo_avg_freq. Keep
    // the normal CPUFreq current-frequency attributes as fallbacks so an idle
    // core does not become N/A merely because hardware feedback is transient.
    for attribute in ["cpuinfo_avg_freq", "cpuinfo_cur_freq", "scaling_cur_freq"] {
        if let Some(value) = a14_read_u64(policy.join(attribute)).filter(|value| *value > 0) {
            return Some(value);
        }
    }
    None
}

fn a14_policy_hardware_max_khz(policy: &Path) -> Option<u64> {
    // Prefer an invariant hardware maximum. Do not use scaling_max_freq until
    // the end because Whisper/QoS is allowed to lower that runtime policy cap.
    if let Some(value) = a14_read_u64(policy.join("cpuinfo_max_freq")).filter(|value| *value > 0) {
        return Some(value);
    }

    if let Ok(values) = std::fs::read_to_string(policy.join("scaling_available_frequencies")) {
        if let Some(value) = values
            .split_whitespace()
            .filter_map(|value| value.parse::<u64>().ok())
            .max()
        {
            return Some(value);
        }
    }

    if let Ok(time_in_state) = std::fs::read_to_string(policy.join("stats/time_in_state")) {
        if let Some(value) = time_in_state
            .lines()
            .filter_map(|line| line.split_whitespace().next())
            .filter_map(|value| value.parse::<u64>().ok())
            .max()
        {
            return Some(value);
        }
    }

    a14_read_u64(policy.join("scaling_max_freq")).filter(|value| *value > 0)
}
'''.strip("\n")

MAX_SPEED = r'''
fn linux_cpu_max_speed(online_cpus: &[usize]) -> Option<f64> {
    let mut max_khz = None;

    for cpu in online_cpus {
        if let Some(policy) = a14_policy_for_cpu(*cpu) {
            if let Some(value) = a14_policy_hardware_max_khz(&policy) {
                max_khz = Some(max_khz.map_or(value, |current: u64| current.max(value)));
            }
        }
    }

    // Inspect policies directly as well. This handles policy directories whose
    // per-CPU symlinks are absent and policies containing temporarily-offline CPUs.
    if let Ok(policies) = glob("/sys/devices/system/cpu/cpufreq/policy*") {
        for policy in policies.flatten() {
            if let Some(value) = a14_policy_hardware_max_khz(&policy) {
                max_khz = Some(max_khz.map_or(value, |current: u64| current.max(value)));
            }
        }
    }

    max_khz.map(|value| value as f64 * 1000.0)
}
'''.strip("\n")

GET_CPU_FREQ = r'''
pub fn get_cpu_freq(core: usize) -> Result<u64> {
    trace!("Finding CPU frequency for core {core}…");

    let policy = a14_policy_for_cpu(core)
        .with_context(|| format!("unable to find CPUFreq policy for core {core}"))?;

    a14_policy_current_khz(&policy)
        .with_context(|| format!("unable to read CPUFreq frequency for core {core}"))
        .map(|freq| freq * 1000)
        .inspect(|freq| trace!("Frequency of core {core}: {freq} Hz"))
}
'''.strip("\n")


def function_span(text: str, signature: str) -> tuple[int, int]:
    start = text.find(signature)
    if start < 0:
        raise RuntimeError(f"function not found: {signature}")
    brace = text.find("{", start)
    if brace < 0:
        raise RuntimeError(f"function opening brace not found: {signature}")

    depth = 0
    for pos in range(brace, len(text)):
        char = text[pos]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return start, pos + 1
    raise RuntimeError(f"function closing brace not found: {signature}")


def replace_function(text: str, signature: str, replacement: str) -> str:
    start, end = function_span(text, signature)
    return text[:start] + replacement + text[end:]


def repair_cpu_source(text: str) -> str:
    # This repair is specifically for the already-custom A14 tree. Refuse to
    # silently turn an unrelated upstream Resources checkout into a different
    # build; the full apply-a14-cpu-info.py patcher exists for that case.
    if "A14_RESOURCES_CPU_INFO_V1" not in text:
        raise RuntimeError(
            "existing A14 CPU patch marker is missing; use apply-a14-cpu-info.py for a fresh Resources tree"
        )
    if "fn apply_linux_sysfs(&mut self)" not in text:
        raise RuntimeError("existing A14 CpuInfo::apply_linux_sysfs helper is missing")

    if MARKER not in text:
        max_start, _ = function_span(text, "fn linux_cpu_max_speed(")
        text = text[:max_start] + HELPERS + "\n\n" + text[max_start:]

    text = replace_function(text, "fn linux_cpu_max_speed(", MAX_SPEED)
    text = replace_function(text, "pub fn get_cpu_freq(core: usize)", GET_CPU_FREQ)

    required = (
        MARKER,
        '"cpuinfo_avg_freq", "cpuinfo_cur_freq", "scaling_cur_freq"',
        'policy.join("cpuinfo_max_freq")',
        'policy.join("scaling_available_frequencies")',
        'policy.join("stats/time_in_state")',
        'policy.join("scaling_max_freq")',
        "fn linux_cpu_max_speed(online_cpus: &[usize]) -> Option<f64>",
        "pub fn get_cpu_freq(core: usize) -> Result<u64>",
    )
    missing = [token for token in required if token not in text]
    if missing:
        raise RuntimeError("CPU frequency repair incomplete: " + ", ".join(missing))
    return text


def apply(repo: Path, dry_run: bool = False) -> int:
    cpu = repo / CPU_RS
    if not cpu.is_file():
        raise RuntimeError(f"not a Resources source tree; missing {CPU_RS}")

    original = cpu.read_text()
    repaired = repair_cpu_source(original)
    if repaired == original:
        print("Resources A14 CPU frequency repair is already applied.")
        return 0

    diff = "".join(
        difflib.unified_diff(
            original.splitlines(keepends=True),
            repaired.splitlines(keepends=True),
            fromfile=f"a/{CPU_RS}",
            tofile=f"b/{CPU_RS}",
        )
    )
    if dry_run:
        sys.stdout.write(diff)
        return 0

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = cpu.with_name(f"cpu.rs.a14-frequency-backup-{timestamp}")
    patch = repo / f"resources-a14-cpu-frequency-{timestamp}.patch"
    shutil.copy2(cpu, backup)
    cpu.write_text(repaired)
    patch.write_text(diff)

    print("Repaired Resources A14 CPU current/max frequency reporting.")
    print(f"Backup: {backup}")
    print(f"Patch:  {patch}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("repo", nargs="?", default=".", help="existing custom Resources source tree")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        return apply(Path(args.repo).expanduser().resolve(), args.dry_run)
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
