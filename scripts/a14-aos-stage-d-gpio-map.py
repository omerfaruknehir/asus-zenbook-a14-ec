#!/usr/bin/env python3
"""Read-only Stage D mapper for Windows CAMP F0 TLMM GPIOs 96..106.

The mapper decompiles the live Linux DT and resolves each target pin config to
the nearest enclosing pinctrl state that is actually referenced by a device.
It performs no hardware or kernel-state mutation.
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

# Function selected by the ASUS/QRD CAMP_RES_QRD.bin F0 TLMM entries.
# GPIO99 is intentionally GPIO/function 0 in the Windows resource payload; it
# must not be inferred from the SoC's available cam_mclk alternate function.
WINDOWS_F0_FUNCTION = {
    96: "cam_mclk",
    97: "cam_mclk",
    98: "cam_mclk",
    99: "gpio",
    100: "cam_aon",
    101: "cci_i2c",
    102: "cci_i2c",
    103: "cci_i2c",
    104: "cci_i2c",
    105: "cci_i2c",
    106: "cci_i2c",
}

SOC_ALT_FUNCTION = {
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

OUT = (
    Path(sys.argv[1]).expanduser()
    if len(sys.argv) > 1
    else Path.home() / "Downloads" / "a14-aos-stage-d-gpio-map.txt"
)


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


def direct_properties(lines: list[str], start: int, end: int) -> list[str]:
    """Return properties directly owned by one node, excluding descendants."""
    props: list[str] = []
    depth = 0
    for line in lines[start + 1 : end]:
        s = line.strip()
        if depth == 0 and "=" in s and s.endswith(";"):
            props.append(s)
        depth += line.count("{") - line.count("}")
    return props


def direct_prop(lines: list[str], node: dict[str, object], name: str) -> str | None:
    prefix = name + " ="
    for prop in direct_properties(lines, int(node["start"]), int(node["end"])):
        if prop.startswith(prefix):
            return prop.split("=", 1)[1].strip().rstrip(";").strip()
    return None


def extract_prop(block: str, name: str) -> str | None:
    m = re.search(rf"^\s*{re.escape(name)}\s*=\s*(.+?);\s*$", block, flags=re.M)
    return m.group(1).strip() if m else None


def flag_props(block: str) -> list[str]:
    names = (
        "bias-disable",
        "bias-pull-up",
        "bias-pull-down",
        "input-enable",
        "input-disable",
        "output-enable",
        "output-high",
        "output-low",
        "qcom,apps",
        "qcom,remote",
    )
    return [
        name
        for name in names
        if re.search(rf"^\s*{re.escape(name)}\s*;\s*$", block, flags=re.M)
    ]


def target_hits(props: list[str]) -> list[int]:
    joined = "\n".join(props)
    return [
        pin
        for pin in TARGET_PINS
        if re.search(rf'"gpio{pin}"(?:\s*[,;]|\s*$)', joined, flags=re.M)
    ]


def phandle_in_property(token: str, prop: str) -> bool:
    """Match one phandle cell exactly inside a <...> property value."""
    if not prop.startswith("pinctrl-") or "=" not in prop:
        return False
    value = prop.split("=", 1)[1]
    cells = re.findall(r"0x[0-9a-fA-F]+|\b\d+\b", value)
    token_cells = re.findall(r"0x[0-9a-fA-F]+|\b\d+\b", token)
    return bool(token_cells) and token_cells[0].lower() in {c.lower() for c in cells}


def pinctrl_consumers(
    lines: list[str], nodes: list[dict[str, object]], phandle: str
) -> list[tuple[str, str]]:
    refs: list[tuple[str, str]] = []
    for other in nodes:
        for prop in direct_properties(lines, int(other["start"]), int(other["end"])):
            if phandle_in_property(phandle, prop):
                refs.append((str(other["path"]), prop))
    seen: set[tuple[str, str]] = set()
    dedup: list[tuple[str, str]] = []
    for ref in refs:
        if ref not in seen:
            seen.add(ref)
            dedup.append(ref)
    return dedup


def main() -> int:
    if shutil.which("dtc") is None:
        print("ERROR: dtc is required", file=sys.stderr)
        return 1

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("", encoding="utf-8")

    cmdline = read_text("/proc/cmdline")
    markers = sorted(set(re.findall(r"\ba14_aos_[^\s]*_test=[^\s]+", cmdline)))

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

    section("WINDOWS CAMP F0 PIN FUNCTION MODEL")
    log("windows_source=CAMP_RES_QRD.bin")
    for pin in TARGET_PINS:
        log(f"gpio{pin}_windows_f0_function={WINDOWS_F0_FUNCTION[pin]}")
        log(f"gpio{pin}_soc_alt_function={SOC_ALT_FUNCTION[pin]}")

    with tempfile.TemporaryDirectory(prefix="a14-stage-d-gpio-map-") as td:
        dts_path = Path(td) / "live.dts"
        err_path = Path(td) / "dtc.err"
        with dts_path.open("w", encoding="utf-8") as out, err_path.open(
            "w", encoding="utf-8"
        ) as err:
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
                nodes.append(
                    {
                        "name": name,
                        "start": start,
                        "end": idx,
                        "path": path,
                        "text": "\n".join(lines[start : idx + 1]),
                    }
                )

        pin_nodes: list[dict[str, object]] = []
        for node in nodes:
            props = direct_properties(lines, int(node["start"]), int(node["end"]))
            pins_props = [p for p in props if p.startswith("pins =")]
            hits = target_hits(pins_props)
            if hits:
                copy = dict(node)
                copy["hits"] = hits
                pin_nodes.append(copy)
        pin_nodes.sort(key=lambda n: int(n["start"]))

        section("LIVE PINCTRL BLOCKS")
        if not pin_nodes:
            log("target_pinctrl_blocks=none")

        per_pin_consumers: dict[int, set[str]] = {pin: set() for pin in TARGET_PINS}
        per_pin_states: dict[int, set[str]] = {pin: set() for pin in TARGET_PINS}

        for i, node in enumerate(pin_nodes, 1):
            block = str(node["text"])
            hits = list(node["hits"])

            # Consider every enclosing node with its *own direct* phandle. Prefer
            # the smallest ancestor whose phandle is directly referenced by a
            # pinctrl-N property. This resolves parent-state phandles correctly
            # while ignoring incidental child phandles emitted by dtc symbols.
            candidates: list[
                tuple[int, dict[str, object], str, list[tuple[str, str]]]
            ] = []
            for candidate in nodes:
                if not (
                    int(candidate["start"]) <= int(node["start"])
                    and int(candidate["end"]) >= int(node["end"])
                ):
                    continue
                ph = direct_prop(lines, candidate, "phandle")
                if not ph:
                    continue
                span = int(candidate["end"]) - int(candidate["start"])
                refs = pinctrl_consumers(lines, nodes, ph)
                candidates.append((span, candidate, ph, refs))

            referenced = [item for item in candidates if item[3]]
            referenced.sort(key=lambda item: item[0])
            candidates.sort(key=lambda item: item[0])
            chosen = referenced[0] if referenced else (candidates[0] if candidates else None)

            if chosen:
                _, state_node, state_phandle, refs = chosen
            else:
                state_node = None
                state_phandle = None
                refs = []

            function = extract_prop(block, "function")
            drive = extract_prop(block, "drive-strength")
            pins_prop = extract_prop(block, "pins")
            flags = flag_props(block)

            log(f"block_{i}_path={node['path']}")
            log(f"block_{i}_pins={','.join('gpio' + str(p) for p in hits)}")
            log(f"block_{i}_pins_property={pins_prop or 'unparsed'}")
            log(f"block_{i}_function={function or 'unspecified'}")
            log(
                f"block_{i}_windows_f0_functions="
                + ",".join(sorted({WINDOWS_F0_FUNCTION[p] for p in hits}))
            )
            log(f"block_{i}_drive_strength={drive or 'unspecified'}")
            log(f"block_{i}_flags={','.join(flags) if flags else 'none'}")
            log(f"block_{i}_state_path={state_node['path'] if state_node else 'none'}")
            log(f"block_{i}_state_phandle={state_phandle or 'none'}")

            if refs:
                for j, (path, prop) in enumerate(refs, 1):
                    log(f"block_{i}_consumer_{j}_path={path}")
                    log(f"block_{i}_consumer_{j}_property={prop}")
                    for pin in hits:
                        per_pin_consumers[pin].add(path)
            elif state_phandle:
                log(f"block_{i}_consumers=none-found")
            else:
                log(f"block_{i}_consumers=unresolvable-no-enclosing-phandle")

            if state_node:
                for pin in hits:
                    per_pin_states[pin].add(str(state_node["path"]))
            log("---")

        section("CCI NODE PINCTRL REFERENCES")
        for cci_path in ("/soc@0/cci@ac15000", "/soc@0/cci@ac16000"):
            matches = [n for n in nodes if n["path"] == cci_path]
            if not matches:
                log(f"cci_node_missing={cci_path}")
                continue
            cci_node = matches[0]
            props = direct_properties(lines, int(cci_node["start"]), int(cci_node["end"]))
            log(f"cci_node={cci_path}")
            for prop in props:
                if prop.startswith("pinctrl-"):
                    log(f"cci_pinctrl_property={prop}")

        section("PER-PIN SUMMARY")
        for pin in TARGET_PINS:
            matches = [n for n in pin_nodes if pin in n["hits"]]
            functions = sorted(
                {
                    f.strip('"')
                    for n in matches
                    if (f := extract_prop(str(n["text"]), "function"))
                }
            )
            consumers = sorted(per_pin_consumers[pin])
            states = sorted(per_pin_states[pin])
            log(f"gpio{pin}_live_block_count={len(matches)}")
            log(f"gpio{pin}_live_functions={','.join(functions) if functions else 'none'}")
            log(f"gpio{pin}_windows_f0_function={WINDOWS_F0_FUNCTION[pin]}")
            log(f"gpio{pin}_consumer_count={len(consumers)}")
            log(f"gpio{pin}_consumers={','.join(consumers) if consumers else 'none'}")
            log(f"gpio{pin}_states={','.join(states) if states else 'none'}")

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
