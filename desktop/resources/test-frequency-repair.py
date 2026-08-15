#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "a14_frequency_repair", HERE / "repair-a14-cpu-frequency.py"
)
assert SPEC and SPEC.loader
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)

CUSTOM_CPU = r'''use anyhow::{Context, Result};
use glob::glob;
use std::path::{Path, PathBuf};

// A14_RESOURCES_CPU_INFO_V1
fn parse_linux_cpu_list(_list: &str) -> Vec<usize> { vec![] }

fn linux_cpu_max_speed(_online_cpus: &[usize]) -> Option<f64> {
    None
}

// Existing custom Qualcomm work must survive the frequency-only repair.
fn qcom_physical_topology_from_sysfs() -> (Option<usize>, Option<usize>) {
    // CUSTOM_KEEP_ME
    (Some(12), Some(1))
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct CpuInfo {
    pub max_speed: Option<f64>,
}

impl CpuInfo {
    fn apply_linux_sysfs(&mut self) {
        let online_cpus = vec![0usize, 1usize];
        if let Some(max_speed) = linux_cpu_max_speed(&online_cpus) {
            self.max_speed = Some(max_speed);
        }
    }
}

pub fn get_cpu_freq(core: usize) -> Result<u64> {
    read_parsed::<u64>(format!(
        "/sys/devices/system/cpu/cpu{core}/cpufreq/cpuinfo_avg_freq"
    ))
    .or_else(|_| {
        read_parsed::<u64>(format!(
            "/sys/devices/system/cpu/cpu{core}/cpufreq/scaling_cur_freq"
        ))
    })
    .map(|x| x * 1000)
}

fn parse_proc_stat_line(_line: &str) {}
'''


def main() -> None:
    with tempfile.TemporaryDirectory() as raw:
        repo = Path(raw)
        cpu = repo / "src/utils/cpu.rs"
        cpu.parent.mkdir(parents=True)
        cpu.write_text(CUSTOM_CPU)

        assert MOD.apply(repo, False) == 0
        first = cpu.read_text()
        assert "CUSTOM_KEEP_ME" in first
        assert "qcom_physical_topology_from_sysfs" in first
        assert first.count(MOD.MARKER) == 1
        assert '"cpuinfo_avg_freq", "cpuinfo_cur_freq", "scaling_cur_freq"' in first
        assert 'policy.join("cpuinfo_max_freq")' in first
        assert 'policy.join("scaling_available_frequencies")' in first
        assert 'policy.join("stats/time_in_state")' in first
        assert 'policy.join("scaling_max_freq")' in first
        assert "a14_policy_for_cpu(core)" in first
        assert "linux_cpu_max_speed(&online_cpus)" in first

        # A second repair must be byte-for-byte idempotent and preserve custom work.
        assert MOD.apply(repo, False) == 0
        assert cpu.read_text() == first


if __name__ == "__main__":
    main()
