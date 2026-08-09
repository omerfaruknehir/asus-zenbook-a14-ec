#!/usr/bin/env python3
"""Read-only Stage D mapper for Windows CAMP F0 TLMM GPIOs 96..106."""

from __future__ import annotations

import datetime as dt
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

TARGET_PINS = tuple(range(96, 107))
EXPECTED_FUNCTION = {
    96: "cam_mclk", 97: "cam_mclk", 98: "cam_mclk", 99: "cam_mclk",
    100: "cam_aon",
    101: "cci_i2c", 102: "cci_i2c", 103: "cci_i2c",
    104: "cci_i2c", 105: "cci_i2c", 106: "cci_i2c",
}
OUT = Path(sys.argv[1]).expanduser() if len(sys.argv) > 1 else Path.home() / "Downloads" / "a14-aos-stage-d-gpio-map.txt"


def log(line: str = "") -> None:
    print(line)
    with OUT.open("a", encoding="utf-8") as fh:
        fh.write(line + "\n")


def section(name: str) -> None:
    log()
    log(f"===== {name} =====")


def read_text(path: str) -> str:
    return Path(path).read_text(encoding="utf-8", errors="replace").strip()


def node_start(line: str) -> str | None:
    s = line.strip()
    if not s.endswith("{"):
        return None
    head = s[:-1].strip()
    if not head or "=" in head:
        return None
    return head


def extract_prop(block: str, name: str) -> str | None:
    m = re.search(rf'^\s*{re.escape(name)}\s*=\s*(.+?);\s*$', block, flags=re.M)
    return m.group(1).strip() if m else None


def direct_properties(lines: list[str], start: int, end: int) -> list[str]:
    props: list[str] = []
    depth = 0
    for line in lines[start + 1:end]:
        s = line.strip()
        if depth == 0 and "=" in s and s.endswith(";"):
            props.append(s)
        depth += line.count("{") - line.count("}")
    return props


def flag_props(block: str) -> list[str]:
    names = (
        "bias-disable", "bias-pull-up", "bias-pull-down",
        "input-enable", "input-disable", "output-enable",
        "output-high", "output-low", "qcom,apps", "qcom,remote",
    )
    return [name for name in names if re.search(rf'^\s*{re.escape(name)}\s*;\s*$', block, flags=re.M)]


def target_hits(block: str) -> list[int]:
    return [pin for pin in TARGET_PINS if re.search(rf'"gpio{pin}"(?:\s*[,;]|\s*$)', block, flags=re.M)]


def main() -> int:
    if shutil.which("dtc") is None:
        print("ERROR: dtc is required", file=sys.stderr)
        return 1

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("", encoding="utf-8")

    cmdline = read_text("/proc/cmdline")
    markers = sorted(set(re.findall(r'\ba14_aos_[^\s]*_test=[^\s]+', cmdline)))

    section("IDENTITY")
    log(f"collected_at={dt.datetime.now().astimezone().isoformat(timespec='microseconds')}")
    log(f"kernel={os.uname().release}")
    log(f"boot_id={read_text('/proc/sys/kernel/random/boot_id')}")
    log(f"cmdline={cmdline}")
    log(f"boot_scope={'custom-diagnostic' if markers else 'normal-no-a14-test-marker'}")
    for marker in markers:
        log(f"boot_marker={marker}")

    section("SAFETY")
    log("operation=read-only-live-dt-map")
    log("hardware_write=false")
    log("gpio_write=false")
    log("direct_cpas_mmio=false")
    log("ssc_contacted=false")

    section("X1E80100 PIN FUNCTION MAP")
    log("source_model=upstream-pinctrl-x1e80100")
    for pin in TARGET_PINS:
        log(f"gpio{pin}_soc_function={EXPECTED_FUNCTION[pin]}")

    with tempfile.TemporaryDirectory(prefix="a14-stage-d-gpio-map-") as td:
        dts_path = Path(td) / "live.dts"
        err_path = Path(td) / "dtc.err"
        with dts_path.open("w", encoding="utf-8") as out, err_path.open("w", encoding="utf-8") as err:
            proc = subprocess.run(
                ["dtc", "-I", "fs", "-O", "dts", "/sys/firmware/devicetree/base"],
                stdout=out, stderr=err, check=False, text=True,
            )
        if proc.returncode != 0:
            section("DTC")
            log(f"dtc_status=failed:{proc.returncode}")
            log(err_path.read_text(encoding="utf-8", errors="replace"))
            return 1

        lines = dts_path.read_text(encoding="utf-8", errors="replace").splitlines()
        stack: list[tuple[str, int, str]] = []
        nodes: list[dict[str, object]] = []
        for idx, line in enumerate(lines):
            start_name = node_start(line)
            if start_name is not None:
                parent_path = stack[-1][2] if stack else ""
                component = start_name.split(":", 1)[-1].strip()
                path = (parent_path.rstrip("/") + "/" + component).replace("//", "/")
                stack.append((start_name, idx, path))
            if line.strip() in ("};", "}") and stack:
                name, start, path = stack.pop()
                nodes.append({
                    "name": name,
                    "start": start,
                    "end": idx,
                    "path": path,
                    "text": "\n".join(lines[start:idx + 1]),
                })

        # Only leaf/config nodes with a direct pins property are target pin blocks.
        pin_nodes: list[dict[str, object]] = []
        for node in nodes:
            props = direct_properties(lines, int(node["start"]), int(node["end"]))
            pins_lines = [p for p in props if p.startswith("pins =")]
            if not pins_lines:
                continue
            hits = target_hits("\n".join(pins_lines))
            if hits:
                copy = dict(node)
                copy["hits"] = hits
                pin_nodes.append(copy)
        pin_nodes.sort(key=lambda n: int(n["start"]))

        section("LIVE PINCTRL BLOCKS")
        if not pin_nodes:
            log("target_pinctrl_blocks=none")

        for i, node in enumerate(pin_nodes, 1):
            block = str(node["text"])
            hits = list(node["hits"])

            # Pinctrl phandles commonly live on the enclosing state rather than
            # the child config node. Select the smallest enclosing phandled node.
            ancestors = []
            for candidate in nodes:
                if int(candidate["start"]) <= int(node["start"]) and int(candidate["end"]) >= int(node["end"]):
                    ph = extract_prop(str(candidate["text"]), "phandle")
                    if ph:
                        span = int(candidate["end"]) - int(candidate["start"])
                        ancestors.append((span, candidate, ph))
            ancestors.sort(key=lambda item: item[0])
            state_node = ancestors[0][1] if ancestors else None
            state_phandle = ancestors[0][2] if ancestors else None

            function = extract_prop(block, "function")
            drive = extract_prop(block, "drive-strength")
            pins_prop = extract_prop(block, "pins")
            flags = flag_props(block)

            log(f"block_{i}_path={node['path']}")
            log(f"block_{i}_pins={','.join('gpio'+str(p) for p in hits)}")
            log(f"block_{i}_pins_property={pins_prop or 'unparsed'}")
            log(f"block_{i}_function={function or 'unspecified'}")
            log(f"block_{i}_expected_functions={','.join(sorted(set(EXPECTED_FUNCTION[p] for p in hits)))}")
            log(f"block_{i}_drive_strength={drive or 'unspecified'}")
            log(f"block_{i}_flags={','.join(flags) if flags else 'none'}")
            log(f"block_{i}_state_path={state_node['path'] if state_node else 'none'}")
            log(f"block_{i}_state_phandle={state_phandle or 'none'}")

            if state_phandle:
                refs: list[tuple[str, str]] = []
                for other in nodes:
                    for prop in direct_properties(lines, int(other["start"]), int(other["end"])):
                        if state_phandle in prop and not prop.startswith("phandle ="):
                            refs.append((str(other["path"]), prop))
                seen = set()
                dedup = []
                for ref in refs:
                    if ref not in seen:
                        seen.add(ref)
                        dedup.append(ref)
                if dedup:
                    for j, (path, prop) in enumerate(dedup, 1):
                        log(f"block_{i}_consumer_{j}_path={path}")
                        log(f"block_{i}_consumer_{j}_property={prop}")
                else:
                    log(f"block_{i}_consumers=none-found")
            else:
                log(f"block_{i}_consumers=unresolvable-no-enclosing-phandle")
            log("---")

        section("PER-PIN SUMMARY")
        for pin in TARGET_PINS:
            matches = [n for n in pin_nodes if pin in n["hits"]]
            functions = []
            for node in matches:
                f = extract_prop(str(node["text"]), "function")
                if f:
                    functions.append(f.strip('"'))
            log(f"gpio{pin}_live_block_count={len(matches)}")
            log(f"gpio{pin}_live_functions={','.join(sorted(set(functions))) if functions else 'none'}")
            log(f"gpio{pin}_expected_function={EXPECTED_FUNCTION[pin]}")

    section("RESULT")
    log("result=read-only-camp-gpio-map-complete")
    log(f"report={OUT}")
    log("hardware_write=false")
    log("gpio_write=false")
    log("direct_cpas_mmio=false")
    log("ssc_contacted=false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
