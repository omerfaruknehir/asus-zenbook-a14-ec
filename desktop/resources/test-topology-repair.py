#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "a14_resources_topology_repair", ROOT / "repair-a14-cpu-topology.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

OLD = r'''fn linux_cpu_topology(online_cpus: &[usize]) -> (Option<usize>, Option<usize>) {
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
    None
}
'''


def main() -> None:
    with tempfile.TemporaryDirectory() as raw:
        repo = Path(raw)
        path = repo / MODULE.CPU_RS
        path.parent.mkdir(parents=True)
        path.write_text(OLD)

        assert MODULE.apply(repo, False) == 0
        changed = path.read_text()
        assert "thread_siblings_list" in changed
        assert "cores.insert((package.unwrap_or(0), core))" not in changed
        assert changed.count("fn linux_cpu_topology") == 1

        assert MODULE.apply(repo, False) == 0
        assert path.read_text() == changed


if __name__ == "__main__":
    main()
