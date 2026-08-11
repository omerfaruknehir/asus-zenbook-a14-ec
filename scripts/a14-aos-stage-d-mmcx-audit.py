#!/usr/bin/env python3
"""Read-only Stage D CAMCC/MMCX topology and OPP audit for the Zenbook A14.

This tool deliberately does not runtime-resume devices, change performance
states, touch camera/CPAS registers, load modules, or contact SSC. It only reads
live DT/sysfs/debugfs state and writes a text report.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import os
from pathlib import Path
import struct
import sys
import tempfile
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

CAMCC_COMPAT = b"qcom,x1e80100-camcc"
CAMSS_COMPAT = b"qcom,x1e80100-camss"


def read_bytes(path: Path) -> Optional[bytes]:
    try:
        return path.read_bytes()
    except (FileNotFoundError, PermissionError, OSError):
        return None


def be_u32s(data: Optional[bytes]) -> List[int]:
    if not data or len(data) % 4:
        return []
    return list(struct.unpack(">" + "I" * (len(data) // 4), data))


def be_u64s(data: Optional[bytes]) -> List[int]:
    if not data or len(data) % 8:
        return []
    return list(struct.unpack(">" + "Q" * (len(data) // 8), data))


def string_list(data: Optional[bytes]) -> List[str]:
    if not data:
        return []
    return [part.decode("utf-8", "replace") for part in data.rstrip(b"\0").split(b"\0") if part]


def one_u32(node: Path, prop: str, default: Optional[int] = None) -> Optional[int]:
    vals = be_u32s(read_bytes(node / prop))
    return vals[0] if vals else default


def relative_dt_path(dt_root: Path, node: Path) -> str:
    try:
        rel = node.resolve().relative_to(dt_root.resolve())
        return "/" + rel.as_posix()
    except Exception:
        return str(node)


def compatible_matches(node: Path, needle: bytes) -> bool:
    raw = read_bytes(node / "compatible")
    if not raw:
        return False
    return needle in raw.split(b"\0")


def find_compatible(dt_root: Path, needle: bytes) -> List[Path]:
    matches: List[Path] = []
    for compat in dt_root.rglob("compatible"):
        try:
            if needle in compat.read_bytes().split(b"\0"):
                matches.append(compat.parent)
        except (PermissionError, OSError):
            continue
    return sorted(matches, key=lambda p: str(p))


def build_phandle_map(dt_root: Path) -> Dict[int, Path]:
    out: Dict[int, Path] = {}
    for prop_name in ("phandle", "linux,phandle"):
        for prop in dt_root.rglob(prop_name):
            vals = be_u32s(read_bytes(prop))
            if vals:
                out.setdefault(vals[0], prop.parent)
    return out


def fmt_u32s(vals: Sequence[int]) -> str:
    if not vals:
        return "unavailable"
    return " ".join(f"0x{x:08x}" for x in vals)


def dump_property(lines: List[str], node: Path, name: str) -> None:
    raw = read_bytes(node / name)
    if raw is None:
        lines.append(f"{name}=unavailable")
        return
    strings = string_list(raw)
    # DT string properties should be printable and NUL-terminated. Avoid
    # misclassifying binary phandle cells that happen to contain ASCII bytes.
    if raw.endswith(b"\0") and strings and all(all((32 <= ord(c) < 127) for c in s) for s in strings):
        lines.append(f"{name}_strings=" + " | ".join(strings))
    lines.append(f"{name}_raw_u32={fmt_u32s(be_u32s(raw))}")
    lines.append(f"{name}_raw_hex={raw.hex()}")


def parse_power_domains(
    node: Path, phandles: Dict[int, Path], dt_root: Path
) -> List[Tuple[int, Optional[Path], List[int]]]:
    cells = be_u32s(read_bytes(node / "power-domains"))
    result: List[Tuple[int, Optional[Path], List[int]]] = []
    i = 0
    while i < len(cells):
        ph = cells[i]
        i += 1
        provider = phandles.get(ph)
        argc = one_u32(provider, "#power-domain-cells", 0) if provider else 0
        argc = int(argc or 0)
        if i + argc > len(cells):
            args = cells[i:]
            i = len(cells)
        else:
            args = cells[i : i + argc]
            i += argc
        result.append((ph, provider, args))
    return result


def dump_opp(lines: List[str], label: str, node: Optional[Path], dt_root: Path) -> None:
    if node is None:
        lines.append(f"{label}=unresolved")
        return
    lines.append(f"{label}_path={relative_dt_path(dt_root, node)}")
    for prop in ("opp-level", "opp-hz", "opp-microvolt", "opp-supported-hw", "turbo-mode"):
        raw = read_bytes(node / prop)
        if raw is None:
            continue
        if prop == "opp-hz":
            lines.append(f"{label}_{prop}_u64=" + ",".join(str(v) for v in be_u64s(raw)))
        else:
            vals = be_u32s(raw)
            lines.append(f"{label}_{prop}_u32=" + ",".join(str(v) for v in vals))
        lines.append(f"{label}_{prop}_hex={raw.hex()}")


def dump_node(
    lines: List[str], title: str, node: Path, dt_root: Path, phandles: Dict[int, Path]
) -> None:
    lines.append("")
    lines.append(f"===== {title} =====")
    lines.append(f"dt_path={relative_dt_path(dt_root, node)}")
    lines.append("compatible=" + " | ".join(string_list(read_bytes(node / "compatible"))))
    for prop in (
        "power-domain-names",
        "power-domains",
        "required-opps",
        "operating-points-v2",
        "clock-names",
        "clocks",
        "status",
    ):
        dump_property(lines, node, prop)

    lines.append("-- resolved power-domains --")
    pd_names = string_list(read_bytes(node / "power-domain-names"))
    for idx, (ph, provider, args) in enumerate(parse_power_domains(node, phandles, dt_root)):
        name = pd_names[idx] if idx < len(pd_names) else f"index{idx}"
        provider_path = relative_dt_path(dt_root, provider) if provider else "unresolved"
        provider_compat = " | ".join(string_list(read_bytes(provider / "compatible"))) if provider else ""
        lines.append(
            f"pd[{idx}] name={name} phandle=0x{ph:x} provider={provider_path} "
            f"args={','.join(str(v) for v in args)} compatible={provider_compat}"
        )

    lines.append("-- resolved required-opps --")
    required = be_u32s(read_bytes(node / "required-opps"))
    if not required:
        lines.append("required-opps=unavailable")
    else:
        for idx, ph in enumerate(required):
            dump_opp(lines, f"required_opp[{idx}]_phandle_0x{ph:x}", phandles.get(ph), dt_root)


def dump_runtime(lines: List[str], device: Path, label: str) -> None:
    lines.append("")
    lines.append(f"===== RUNTIME PM: {label} =====")
    lines.append(f"device={device}")
    for prop in ("control", "runtime_status", "runtime_usage", "runtime_active_time", "runtime_suspended_time"):
        raw = read_bytes(device / "power" / prop)
        if raw is None:
            lines.append(f"{prop}=unavailable")
        else:
            lines.append(f"{prop}={raw.decode('ascii', 'replace').strip()}")


def dump_genpd(lines: List[str], debugfs: Path) -> None:
    summary = debugfs / "pm_genpd" / "pm_genpd_summary"
    lines.append("")
    lines.append("===== GENPD SUMMARY (READ-ONLY) =====")
    try:
        text = summary.read_text(errors="replace")
    except Exception as exc:
        lines.append(f"pm_genpd_summary=unavailable:{type(exc).__name__}:{exc}")
        return
    lines.append(f"pm_genpd_summary={summary}")
    # Preserve the complete summary so parent/child indentation and per-client
    # performance states are not lost by a grep-only view.
    lines.extend(text.rstrip().splitlines())


def dump_devlinks(lines: List[str], virtual_devlink: Path) -> None:
    lines.append("")
    lines.append("===== RELEVANT DEVICE LINKS =====")
    if not virtual_devlink.is_dir():
        lines.append("virtual_devlink=unavailable")
        return
    needles = ("ade0000.clock-controller", "acb7000.isp")
    found = 0
    for entry in sorted(virtual_devlink.iterdir(), key=lambda p: p.name):
        if not any(n in entry.name for n in needles):
            continue
        found += 1
        try:
            target = os.path.realpath(entry)
        except OSError:
            target = "unresolved"
        lines.append(f"{entry.name} -> {target}")
    if not found:
        lines.append("relevant_devlinks=none-visible")


def run_self_test() -> int:
    assert be_u32s(struct.pack(">III", 1, 2, 0x40)) == [1, 2, 0x40]
    assert be_u64s(struct.pack(">QQ", 123, 456)) == [123, 456]
    assert string_list(b"mxc\0mmcx\0") == ["mxc", "mmcx"]
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        provider = root / "rsc" / "power-controller"
        opp = provider / "opp-table" / "opp-64"
        consumer = root / "soc" / "clock-controller@ade0000"
        provider.mkdir(parents=True)
        opp.mkdir(parents=True)
        consumer.mkdir(parents=True)
        (provider / "phandle").write_bytes(struct.pack(">I", 0x10))
        (provider / "#power-domain-cells").write_bytes(struct.pack(">I", 1))
        (opp / "phandle").write_bytes(struct.pack(">I", 0x20))
        (opp / "opp-level").write_bytes(struct.pack(">I", 64))
        (consumer / "power-domains").write_bytes(struct.pack(">IIII", 0x10, 5, 0x10, 6))
        (consumer / "power-domain-names").write_bytes(b"mxc\0mmcx\0")
        (consumer / "required-opps").write_bytes(struct.pack(">II", 0x20, 0x20))
        ph = build_phandle_map(root)
        parsed = parse_power_domains(consumer, ph, root)
        assert [(x[0], x[2]) for x in parsed] == [(0x10, [5]), (0x10, [6])]
        assert ph[0x20] == opp
    print("Stage D MMCX audit self-test passed")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", help="report path; default is ~/a14-stage-d-mmcx-audit-<timestamp>.txt")
    ap.add_argument("--dt-root", default="/sys/firmware/devicetree/base")
    ap.add_argument("--debugfs", default="/sys/kernel/debug")
    ap.add_argument("--platform-devices", default="/sys/bus/platform/devices")
    ap.add_argument("--virtual-devlink", default="/sys/devices/virtual/devlink")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return run_self_test()

    dt_root = Path(args.dt_root)
    if not dt_root.is_dir():
        raise SystemExit(f"DT root not found: {dt_root}")

    stamp = _dt.datetime.now().astimezone().strftime("%Y%m%d-%H%M%S")
    output = Path(args.output).expanduser() if args.output else Path.home() / f"a14-stage-d-mmcx-audit-{stamp}.txt"
    phandles = build_phandle_map(dt_root)
    camcc_nodes = find_compatible(dt_root, CAMCC_COMPAT)
    camss_nodes = find_compatible(dt_root, CAMSS_COMPAT)

    lines: List[str] = []
    lines.extend(
        [
            "ASUS Zenbook A14 Stage D CAMCC/MMCX read-only audit",
            "====================================================",
            f"collected_at={_dt.datetime.now().astimezone().isoformat()}",
            f"kernel_release={os.uname().release}",
            "operation=read-only-discovery",
            "runtime_pm_changes=false",
            "power_domain_changes=false",
            "performance_state_changes=false",
            "clock_changes=false",
            "interconnect_changes=false",
            "camera_stream_started=false",
            "camera_ioctls=false",
            "cpas_mmio_mapped=false",
            "cpas_mmio_access=false",
            "direct_readl_writel=false",
            "scm_invocation=false",
            "ssc_contacted=false",
            f"dt_phandle_count={len(phandles)}",
            f"camcc_node_count={len(camcc_nodes)}",
            f"camss_node_count={len(camss_nodes)}",
        ]
    )

    if not camcc_nodes:
        lines.append("camcc_error=qcom,x1e80100-camcc node not found")
    for idx, node in enumerate(camcc_nodes):
        dump_node(lines, f"CAMCC LIVE DT NODE {idx}", node, dt_root, phandles)

    if not camss_nodes:
        lines.append("camss_error=qcom,x1e80100-camss node not found")
    for idx, node in enumerate(camss_nodes):
        dump_node(lines, f"CAMSS LIVE DT NODE {idx}", node, dt_root, phandles)

    platform = Path(args.platform_devices)
    dump_runtime(lines, platform / "ade0000.clock-controller", "CAMCC")
    dump_runtime(lines, platform / "acb7000.isp", "CAMSS")
    dump_genpd(lines, Path(args.debugfs))
    dump_devlinks(lines, Path(args.virtual_devlink))

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Report: {output}")
    print("Read-only audit complete; no runtime-PM/power/clock/camera/CPAS/SSC state was changed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
