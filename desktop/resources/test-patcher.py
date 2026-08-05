#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "a14_resources_cpu", ROOT / "apply-a14-cpu-info.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

CPU_RS = r'''use anyhow::{Context, Result};
use glob::glob;
use lazy_regex::{Lazy, Regex, lazy_regex};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::LazyLock,
};
static RE_LSCPU_MODEL_NAME: Lazy<Regex> = lazy_regex!(r"Model name:\s*(.*)");
static RE_LSCPU_ARCHITECTURE: Lazy<Regex> = lazy_regex!(r"Architecture:\s*(.*)");
static RE_LSCPU_CPUS: Lazy<Regex> = lazy_regex!(r"CPU\(s\):\s*(.*)");
static RE_LSCPU_SOCKETS: Lazy<Regex> = lazy_regex!(r"Socket\(s\):\s*(.*)");
static RE_LSCPU_CORES: Lazy<Regex> = lazy_regex!(r"Core\(s\) per socket:\s*(.*)");
static RE_LSCPU_VIRTUALIZATION: Lazy<Regex> = lazy_regex!(r"Virtualization:\s*(.*)");
static RE_LSCPU_MAX_MHZ: Lazy<Regex> = lazy_regex!(r"CPU max MHz:\s*(.*)");
#[derive(Debug, Clone, Default, PartialEq)]
pub struct CpuInfo {
    pub model_name: Option<String>,
    pub architecture: Option<String>,
    pub logical_cpus: Option<usize>,
    pub physical_cpus: Option<usize>,
    pub sockets: Option<usize>,
    pub virtualization: Option<String>,
    pub max_speed: Option<f64>,
}

impl CpuInfo {
    fn parse_lscpu<S: AsRef<str>>(lscpu_output: S) -> Self {
        let lscpu_output = lscpu_output.as_ref();
        let model_name = RE_LSCPU_MODEL_NAME.captures(lscpu_output).and_then(|captures| captures.get(1).map(|capture| Self::trade_mark_symbols(capture.as_str())));
        let architecture = RE_LSCPU_ARCHITECTURE.captures(lscpu_output).and_then(|captures| captures.get(1).map(|capture| capture.as_str().into()));
        let sockets = RE_LSCPU_SOCKETS.captures(lscpu_output).and_then(|captures| captures.get(1).and_then(|capture| capture.as_str().parse().ok()));
        let logical_cpus = RE_LSCPU_CPUS.captures(lscpu_output).and_then(|captures| {
            captures
                .get(1)
                .and_then(|capture| capture.as_str().parse().ok())
        });
        let physical_cpus = RE_LSCPU_CORES.captures(lscpu_output).and_then(|captures| captures.get(1).and_then(|capture| capture.as_str().parse::<usize>().ok()).map(|int| int.saturating_mul(sockets.unwrap_or(1))));
        let virtualization = RE_LSCPU_VIRTUALIZATION.captures(lscpu_output).and_then(|captures| captures.get(1).map(|capture| capture.as_str().into()));
        let max_speed = RE_LSCPU_MAX_MHZ.captures(lscpu_output).and_then(|captures| captures.get(1).and_then(|capture| capture.as_str().parse::<f64>().ok().map(|float| float * 1_000_000.0)));
        Self {
            model_name,
            architecture,
            logical_cpus,
            physical_cpus,
            sockets,
            virtualization,
            max_speed,
        }
    }

    fn trade_mark_symbols<S: AsRef<str>>(s: S) -> String { s.as_ref().to_string() }

    pub fn get() -> Result<Self> {
        String::from_utf8(std::process::Command::new("lscpu").env("LC_ALL", "C").output()?.stdout)
            .context("unable to parse lscpu output to UTF-8")
            .map(Self::parse_lscpu)
    }
}
'''

CPU_PAGE_RS = r'''mod imp {
    pub struct ResCPU {
        pub architecture: TemplateChild<adw::ActionRow>,
    }
    impl Default for ResCPU {
        fn default() -> Self {
            Self {
                architecture: Default::default(),
            }
        }
    }
}
impl ResCPU {
    pub fn setup_widgets(&self, cpu_info: CpuInfo) {
        let imp = self.imp();
        imp.architecture
            .set_subtitle(&cpu_info.architecture.unwrap_or_else(|| i18n("N/A")));

        if let Some(model_name) = cpu_info.model_name {
            imp.set_tab_detail_string(&model_name);
        }
    }
}
'''

CPU_UI = r'''<interface>
                    <child>
                      <object class="AdwActionRow" id="architecture">
                        <style>
                          <class name="property"/>
                        </style>
                        <property name="subtitle-selectable">true</property>
                        <property name="title" translatable="yes">Architecture</property>
                      </object>
                    </child>
</interface>
'''


def main() -> None:
    with tempfile.TemporaryDirectory() as raw:
        repo = Path(raw)
        files = {
            repo / "src/utils/cpu.rs": CPU_RS,
            repo / "src/ui/pages/cpu.rs": CPU_PAGE_RS,
            repo / "data/resources/ui/pages/cpu.ui": CPU_UI,
        }
        for path, content in files.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)

        assert MODULE.apply(repo, False) == 0
        assert MODULE.apply(repo, False) == 0

        cpu = (repo / "src/utils/cpu.rs").read_text()
        page = (repo / "src/ui/pages/cpu.rs").read_text()
        ui = (repo / "data/resources/ui/pages/cpu.ui").read_text()

        assert cpu.count(MODULE.MARKER) == 1
        assert "RE_LSCPU_ONLINE_CPUS" in cpu
        assert "let is_x1e = qcom_x1e_platform();" in cpu
        assert "Qualcomm Oryon (ARMv8.7-A)" in cpu
        assert "pub microarchitecture: Option<String>" in cpu
        assert page.count("microarchitecture: Default::default()") == 1
        assert "imp.set_tab_name(microarchitecture)" in page
        assert ui.count('id="microarchitecture"') == 1


if __name__ == "__main__":
    main()
