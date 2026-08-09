#!/usr/bin/env python3
"""Read-only Stage D mapper for Windows CAMP F0 TLMM GPIOs 96..106.

This script decompiles the *live* Linux device tree and maps every pinctrl node
that contains the Windows CAMP F0 TLMM pins to its phandle consumers.

Safety boundary:
- no GPIO writes or direction changes
- no sysfs/debugfs writes or mounts
- no driver bind/unbind or module operations
- no CPAS MMIO, /dev/mem, ioremap/readl/writel
- no SSC/AOS activation
"""

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
    96: "cam_mclk",
    97: "cam_mclk",
    98: "cam_mclk",
    99: "cam_mclk",
    100: "cam_aon",
    101: "cci_i2c",
    102: "cci_i2c",
    103: "cci_i2c",
    104: "cci_i2c",
    105: "cci_i2c",
    106: "cci_i2c",
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
    # Exclude property values containing braces; DT node declarations end in '{'.
    head = s[:-1].strip()
    if not head or "=" in head:
        return None
    return head


def exact_pin_hits(text: str) -> list[int]:
    hits = []
    for pin in TARGET_PINS:
        if re.search(rf'"gpio{pin}"(?:\s*[,;]|\s*$)', text, flags=re.M):
            hits.append(pin)
    return hits


def extract_prop(block: str, name: str) -> str | None:
    m = re.search(rf'^\s*{re.escape(name)}\s*=\s*(.+?);\s*$', block, flags=re.M)
    return m.group(1).strip() if m else None


def flag_props(block: str) -> list[str]:
    names = (
        "bias-disable", "bias-pull-up", "bias-pull-down",
        "input-enable", "input-disable", "output-enable",
        "output-high", "output-low", "qcom,apps", "qcom,remote",
    )
    present = []
    for name in names:
        if re.search(rf'^\s*{re.escape(name)}\s*;\s*$', block, flags=re.M):
            present.append(name)
    return present


def main() -> int:
    if shutil.which("dtc") is None:
        print("ERROR: dtc is required", file=sys.stderr)
        return 1

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("", encoding="utf-8")

    cmdline = read_text("/proc/cmdline")
    boot_id = read_text("/proc/sys/kernel/random/boot_id")
    markers = sorted(set(re.findall(r'\ba14_aos_[^\s]*_test=[^\s]+', cmdline)))

    section("IDENTITY")
    log(f"collected_at={dt.datetime.now().astimezone().isoformat(timespec='microseconds')}")
    log(f"kernel={os.uname().release}")
    log(f"boot_id={boot_id}")
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
                stdout=out,
                stderr=err,
                check=False,
                text=True,
            )
        if proc.returncode != 0:
            section("DTC")
            log(f"dtc_status=failed:{proc.returncode}")
            log(err_path.read_text(encoding="utf-8", errors="replace"))
            return 1

        text = dts_path.read_text(encoding="utf-8", errors="replace")
        lines = text.splitlines()

        # Build brace-delimited DT node ranges and paths.
        stack: list[tuple[str, int, str]] = []
        nodes: list[dict[str, object]] = []
        for idx, line in enumerate(lines):
            start = node_start(line)
            if start is not None:
                parent_path = stack[-1][2] if stack else ""
                component = start.split(":", 1)[-1].strip()
                path = (parent_path.rstrip("/") + "/" + component).replace("//", "/")
                stack.append((start, idx, path))

            # DT output places node-closing braces on their own lines (possibly with ';').
            stripped = line.strip()
            if stripped in ("};", "}") and stack:
                name, start_idx, path = stack.pop()
                nodes.append({
                    "name": name,
                    "start": start_idx,
                    "end": idx,
                    "path": path,
                    "text": "\n".join(lines[start_idx:idx + 1]),
                })

        pin_nodes: list[dict[str, object]] = []
        for node in nodes:
            block = str(node["text"])
            if "pins" not in block:
                continue
            hits = exact_pin_hits(block)
            if not hits:
                continue
            # Prefer the narrowest node that directly has a pins property. Parent states
            # may contain child pin nodes; only keep nodes whose own top-level text has
            # a pins property before another child node opens.
            start_i = int(node["start"])
            end_i = int(node["end"])
            depth = 0
            owns_pins = False
            for line in lines[start_i + 1:end_i]:
                s = line.strip()
                if depth == 0 and re.match(r'^pins\s*=', s):
                    owns_pins = True
                    break
                depth += line.count("{") - line.count("}")
            if owns_pins:
                node = dict(node)
                node["hits"] = hits
                pin_nodes.append(node)

        # Deduplicate exact ranges.
        uniq = {(int(n["start"]), int(n["end"])): n for n in pin_nodes}
        pin_nodes = sorted(uniq.values(), key=lambda n: int(n["start"]))

        section("LIVE PINCTRL BLOCKS")
        if not pin_nodes:
            log("target_pinctrl_blocks=none")
        else:
            for i, node in enumerate(pin_nodes, 1):
                block = str(node["text"])
                hits = list(node["hits"])
                phandle = extract_prop(block, "phandle")
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
                log(f"block_{i}_phandle={phandle or 'none'}")

                if phandle:
                    token = phandle.strip()
                    # Resolve references in every node outside this definition.
                    refs: list[tuple[str, str]] = []
                    for other in nodes:
                        if other["start"] == node["start"] and other["end"] == node["end"]:
                            continue
                        other_text = str(other["text"])
                        # Only direct property lines containing this phandle; skip nested
                        # child content by checking lines individually.
                        for raw in other_text.splitlines()[1:-1]:
                            s = raw.strip()
                            if token in s and "=" in s and not s.startswith("phandle"):
                                refs.append((str(other["path"]), s))
                    # Deduplicate while preserving order.
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
                    log(f"block_{i}_consumers=unresolvable-no-phandle")
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
