#!/usr/bin/env python3
"""Apply the ASUS Zenbook A14 / Snapdragon X CPU information fix to Resources.

This is a source-level patcher for nokyan/resources and compatible forks. It
uses strict structural markers, creates a backup, and emits a unified diff.
It does not install services, change sysfs, or add a runtime bridge.
"""

from __future__ import annotations

import argparse
import difflib
import re
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

CPU_RS = Path("src/utils/cpu.rs")
CPU_PAGE_RS = Path("src/ui/pages/cpu.rs")
CPU_UI = Path("data/resources/ui/pages/cpu.ui")
MARKER = "A14_RESOURCES_CPU_INFO_V1"

HELPER_BLOCK = r'''
// A14_RESOURCES_CPU_INFO_V1
fn parse_linux_cpu_list(list: &str) -> Vec<usize> {
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

fn read_linux_cpu_list<P: AsRef<Path>>(path: P) -> Vec<usize> {
    std::fs::read_to_string(path)
        .map(|value| parse_linux_cpu_list(&value))
        .unwrap_or_default()
}

fn read_linux_usize<P: AsRef<Path>>(path: P) -> Option<usize> {
    std::fs::read_to_string(path).ok()?.trim().parse().ok()
}

fn qcom_x1e_platform() -> bool {
    std::fs::read("/proc/device-tree/compatible")
        .or_else(|_| std::fs::read("/sys/firmware/devicetree/base/compatible"))
        .map(|compatible| {
            compatible
                .split(|byte| *byte == 0)
                .any(|entry| entry == b"qcom,x1e80100")
        })
        .unwrap_or(false)
}

fn linux_cpu_topology(online_cpus: &[usize]) -> (Option<usize>, Option<usize>) {
    let mut cores = BTreeSet::new();
    let mut packages = BTreeSet::new();

    for cpu in online_cpus {
        let topology = format!("/sys/devices/system/cpu/cpu{cpu}/topology");
        let package = read_linux_usize(format!("{topology}/physical_package_id"));
        let core = read_linux_usize(format!("{topology}/core_id"));

        if let Some(package) = package {
            packages.insert(package);
        }
        if let Some(core) = core {
            cores.insert((package.unwrap_or(0), core));
        }
    }

    (
        (!cores.is_empty()).then_some(cores.len()),
        (!packages.is_empty()).then_some(packages.len()),
    )
}

fn linux_cpu_max_speed(online_cpus: &[usize]) -> Option<f64> {
    let mut max_khz = None;

    for cpu in online_cpus {
        for attribute in ["cpuinfo_max_freq", "scaling_max_freq"] {
            let path = format!("/sys/devices/system/cpu/cpu{cpu}/cpufreq/{attribute}");
            if let Ok(value) = std::fs::read_to_string(path) {
                if let Ok(value) = value.trim().parse::<u64>() {
                    max_khz = Some(max_khz.map_or(value, |current: u64| current.max(value)));
                }
            }
        }
    }

    if max_khz.is_none() {
        if let Ok(paths) = glob("/sys/devices/system/cpu/cpufreq/policy*/cpuinfo_max_freq") {
            for path in paths.flatten() {
                if let Ok(value) = std::fs::read_to_string(path) {
                    if let Ok(value) = value.trim().parse::<u64>() {
                        max_khz = Some(max_khz.map_or(value, |current: u64| current.max(value)));
                    }
                }
            }
        }
    }

    max_khz.map(|value| value as f64 * 1000.0)
}
'''.strip("\n")

APPLY_METHOD = r'''
    fn apply_linux_sysfs(&mut self) {
        let is_x1e = qcom_x1e_platform();
        let online_cpus = read_linux_cpu_list("/sys/devices/system/cpu/online");

        if !online_cpus.is_empty() {
            self.logical_cpus = Some(online_cpus.len());

            let (physical_cpus, sockets) = linux_cpu_topology(&online_cpus);
            let is_aarch64 = is_x1e
                || self
                    .architecture
                    .as_deref()
                    .map(|architecture| architecture.eq_ignore_ascii_case("aarch64"))
                    .unwrap_or(false);

            self.physical_cpus = physical_cpus.or_else(|| is_aarch64.then_some(online_cpus.len()));
            self.sockets = sockets.or_else(|| is_aarch64.then_some(1));

            if let Some(max_speed) = linux_cpu_max_speed(&online_cpus) {
                self.max_speed = Some(max_speed);
            }
        }

        if is_x1e {
            self.microarchitecture = Some("Qualcomm Oryon (ARMv8.7-A)".into());
            self.architecture = Some("AArch64".into());

            let model_is_missing = self
                .model_name
                .as_deref()
                .map(str::trim)
                .map(|name| name.is_empty() || name.eq_ignore_ascii_case("Unknown CPU"))
                .unwrap_or(true);
            if model_is_missing {
                self.model_name = Some("Qualcomm Snapdragon X Elite / Plus".into());
            }
        }
    }
'''.strip("\n")

MICROARCH_XML = '''                    <child>
                      <object class="AdwActionRow" id="microarchitecture">
                        <style>
                          <class name="property"/>
                        </style>
                        <property name="subtitle-selectable">true</property>
                        <property name="title" translatable="yes">Microarchitecture</property>
                      </object>
                    </child>
'''


def replace_once(text: str, old: str, new: str, description: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{description}: expected exactly one marker, found {count}")
    return text.replace(old, new, 1)


def add_cpu_helpers(text: str) -> str:
    if MARKER in text:
        return text

    if "BTreeSet" not in text:
        if "collections::HashMap," in text:
            text = text.replace(
                "collections::HashMap,",
                "collections::{BTreeSet, HashMap},",
                1,
            )
        elif "collections::{HashMap," in text:
            text = text.replace(
                "collections::{HashMap,",
                "collections::{BTreeSet, HashMap,",
                1,
            )
        else:
            raise RuntimeError("unable to add BTreeSet import")

    if "RE_LSCPU_ONLINE_CPUS" not in text:
        marker = 'static RE_LSCPU_CPUS: Lazy<Regex> = lazy_regex!(r"CPU\\(s\\):\\s*(.*)");\n'
        addition = marker + '\nstatic RE_LSCPU_ONLINE_CPUS: Lazy<Regex> =\n    lazy_regex!(r"On-line CPU\\(s\\) list:\\s*(.*)");\n'
        text = replace_once(text, marker, addition, "online CPU regex")

    derive_marker = "#[derive(Debug, Clone, Default, PartialEq)]\npub struct CpuInfo"
    if derive_marker not in text:
        raise RuntimeError("CpuInfo declaration not found")
    text = text.replace(derive_marker, HELPER_BLOCK + "\n\n" + derive_marker, 1)
    return text


def patch_cpu_info(text: str) -> str:
    text = add_cpu_helpers(text)

    struct_start = text.index("pub struct CpuInfo {")
    struct_end = text.index("}\n\nimpl CpuInfo", struct_start)
    struct = text[struct_start:struct_end]
    if "pub microarchitecture:" not in struct:
        struct = struct.replace(
            "    pub architecture: Option<String>,\n",
            "    pub architecture: Option<String>,\n    pub microarchitecture: Option<String>,\n",
            1,
        )
        if "pub microarchitecture:" not in struct:
            raise RuntimeError("unable to add CpuInfo.microarchitecture")
        text = text[:struct_start] + struct + text[struct_end:]

    old_logical = '''        let logical_cpus = RE_LSCPU_CPUS.captures(lscpu_output).and_then(|captures| {
            captures
                .get(1)
                .and_then(|capture| capture.as_str().parse().ok())
        });
'''
    new_logical = '''        let logical_cpus = RE_LSCPU_ONLINE_CPUS
            .captures(lscpu_output)
            .and_then(|captures| captures.get(1))
            .map(|capture| parse_linux_cpu_list(capture.as_str()).len())
            .filter(|count| *count > 0)
            .or_else(|| {
                RE_LSCPU_CPUS.captures(lscpu_output).and_then(|captures| {
                    captures
                        .get(1)
                        .and_then(|capture| capture.as_str().parse().ok())
                })
            });
'''
    if old_logical in text:
        text = text.replace(old_logical, new_logical, 1)
    elif "RE_LSCPU_ONLINE_CPUS\n            .captures" not in text:
        raise RuntimeError("logical CPU parser block not found")

    parse_start = text.index("    fn parse_lscpu")
    parse_end = text.index("    fn trade_mark_symbols", parse_start)
    parse_block = text[parse_start:parse_end]
    if "microarchitecture: None," not in parse_block:
        last_field = "            max_speed,\n"
        if last_field not in parse_block:
            raise RuntimeError("CpuInfo parse result max_speed field not found")
        parse_block = parse_block.replace(last_field, last_field + "            microarchitecture: None,\n", 1)
        text = text[:parse_start] + parse_block + text[parse_end:]

    if "fn apply_linux_sysfs(&mut self)" not in text:
        marker = "    fn trade_mark_symbols"
        text = replace_once(text, marker, APPLY_METHOD + "\n\n" + marker, "CpuInfo apply method")

    old_map = ".map(Self::parse_lscpu)"
    if old_map in text:
        new_map = '''.map(|output| {
                let mut info = Self::parse_lscpu(output);
                info.apply_linux_sysfs();
                info
            })'''
        text = text.replace(old_map, new_map, 1)
    elif "info.apply_linux_sysfs();" not in text:
        raise RuntimeError("CpuInfo::get parse mapping not found")

    # Update explicit CpuInfo test literals. Default construction needs no change.
    text = re.sub(
        r"(\n\s+max_speed:\s+[^\n]+,\n)(\s+};)",
        lambda m: m.group(1)
        + ("            microarchitecture: None,\n" if "microarchitecture" not in m.group(0) else "")
        + m.group(2),
        text,
    )

    return text


def patch_cpu_page(text: str) -> str:
    if "pub microarchitecture: TemplateChild<adw::ActionRow>" not in text:
        text = replace_once(
            text,
            "        pub architecture: TemplateChild<adw::ActionRow>,\n",
            "        pub architecture: TemplateChild<adw::ActionRow>,\n"
            "        pub microarchitecture: TemplateChild<adw::ActionRow>,\n",
            "CPU page template child",
        )

    if "microarchitecture: Default::default()," not in text:
        text = replace_once(
            text,
            "                architecture: Default::default(),\n",
            "                architecture: Default::default(),\n"
            "                microarchitecture: Default::default(),\n",
            "CPU page default",
        )

    if "imp.microarchitecture" not in text:
        marker = '''        imp.architecture
            .set_subtitle(&cpu_info.architecture.unwrap_or_else(|| i18n("N/A")));
'''
        replacement = '''        imp.architecture.set_subtitle(
            &cpu_info
                .architecture
                .clone()
                .unwrap_or_else(|| i18n("N/A")),
        );

        imp.microarchitecture.set_subtitle(
            &cpu_info
                .microarchitecture
                .clone()
                .unwrap_or_else(|| i18n("N/A")),
        );
'''
        text = replace_once(text, marker, replacement, "CPU page architecture rows")

    old_model = '''        if let Some(model_name) = cpu_info.model_name {
            imp.set_tab_detail_string(&model_name);
        }
'''
    if old_model in text:
        replacement = '''        if let Some(microarchitecture) = cpu_info.microarchitecture.as_deref() {
            imp.set_tab_name(microarchitecture);
        }

        if let Some(model_name) = cpu_info.model_name.as_deref() {
            imp.set_tab_detail_string(model_name);
        }
'''
        text = text.replace(old_model, replacement, 1)
    elif "imp.set_tab_name(microarchitecture)" not in text:
        raise RuntimeError("CPU page model-name block not found")

    return text


def patch_cpu_ui(text: str) -> str:
    if 'id="microarchitecture"' in text:
        return text

    architecture_row = '''                    <child>
                      <object class="AdwActionRow" id="architecture">
                        <style>
                          <class name="property"/>
                        </style>
                        <property name="subtitle-selectable">true</property>
                        <property name="title" translatable="yes">Architecture</property>
                      </object>
                    </child>
'''
    return replace_once(
        text,
        architecture_row,
        architecture_row + MICROARCH_XML,
        "CPU UI architecture row",
    )


def apply(repo: Path, dry_run: bool) -> int:
    files = [repo / CPU_RS, repo / CPU_PAGE_RS, repo / CPU_UI]
    missing = [str(path) for path in files if not path.is_file()]
    if missing:
        raise RuntimeError("not a Resources source tree; missing: " + ", ".join(missing))

    original = {path: path.read_text() for path in files}
    changed = {
        files[0]: patch_cpu_info(original[files[0]]),
        files[1]: patch_cpu_page(original[files[1]]),
        files[2]: patch_cpu_ui(original[files[2]]),
    }

    diffs: list[str] = []
    for path in files:
        rel = path.relative_to(repo)
        diffs.extend(
            difflib.unified_diff(
                original[path].splitlines(keepends=True),
                changed[path].splitlines(keepends=True),
                fromfile=f"a/{rel}",
                tofile=f"b/{rel}",
            )
        )

    if not diffs:
        print("A14 Resources CPU information fix is already applied.")
        return 0

    patch_text = "".join(diffs)
    if dry_run:
        sys.stdout.write(patch_text)
        return 0

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = repo / f".a14-cpu-info-backup-{timestamp}"
    for path in files:
        destination = backup / path.relative_to(repo)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, destination)
        path.write_text(changed[path])

    patch_path = repo / f"resources-a14-cpu-info-{timestamp}.patch"
    patch_path.write_text(patch_text)
    print("Applied A14 CPU information fix.")
    print(f"Backup: {backup}")
    print(f"Patch:  {patch_path}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("repo", nargs="?", default=".", help="Resources source tree")
    parser.add_argument("--dry-run", action="store_true", help="print diff without writing")
    args = parser.parse_args()

    try:
        return apply(Path(args.repo).expanduser().resolve(), args.dry_run)
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
