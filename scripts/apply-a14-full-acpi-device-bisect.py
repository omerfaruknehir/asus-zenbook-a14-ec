#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Add a selectable ordinal halt inside Linux's device_initcall level."""
from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 ACPI device bisect: {msg}")


def kernel_version(root: Path) -> str:
    vals = {}
    for line in (root / "Makefile").read_text().splitlines():
        for key in ("VERSION", "PATCHLEVEL", "SUBLEVEL"):
            if line.startswith(key + " ="):
                vals[key] = line.split("=", 1)[1].strip()
    return ".".join(vals[k] for k in ("VERSION", "PATCHLEVEL", "SUBLEVEL"))


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text()
    if new in text:
        print(f"{label}=current")
        return
    count = text.count(old)
    if count != 1:
        fail(f"{label}: expected one anchor in {path}, found {count}")
    path.write_text(text.replace(old, new, 1))
    print(f"{label}=applied")


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: apply-a14-full-acpi-device-bisect.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file() or kernel_version(root) != KERNEL_VERSION:
        fail(f"targets exactly Linux {KERNEL_VERSION}")

    mainc = root / "init/main.c"
    hdr = root / "include/linux/a14_full_acpi.h"
    if not hdr.is_file() or "a14_acpi_checkpoint" not in hdr.read_text():
        fail("base checkpoint transform missing")
    text = mainc.read_text()
    if "initcall-device-after" not in text:
        fail("late checkpoint transform must be applied first")

    replace_once(
        mainc,
        "static ktime_t initcall_calltime;\n",
        "static ktime_t initcall_calltime;\n\n"
        "/* A14 full-ACPI diagnostic: ordinal binary search inside device initcalls. */\n"
        "static unsigned int a14_device_halt_after;\n"
        "static bool a14_device_halt_after_set;\n\n"
        "static int __init a14_device_halt_after_setup(char *str)\n"
        "{\n"
        "\tunsigned int value;\n\n"
        "\tif (!str || kstrtouint(str, 0, &value))\n"
        "\t\treturn 0;\n"
        "\ta14_device_halt_after = value;\n"
        "\ta14_device_halt_after_set = true;\n"
        "\treturn 0;\n"
        "}\n"
        "early_param(\"a14_device_halt_after\", a14_device_halt_after_setup);\n",
        "device_bisect_param",
    )

    old = (
        "\tdo_trace_initcall_level(initcall_level_names[level]);\n"
        "\tfor (fn = initcall_levels[level]; fn < initcall_levels[level+1]; fn++)\n"
        "\t\tdo_one_initcall(initcall_from_entry(fn));\n\n"
        "\t/* A14 ACPI diagnostic: stop only after complete initcall levels. */\n"
    )
    new = (
        "\tdo_trace_initcall_level(initcall_level_names[level]);\n"
        "\tif (level == 6 && a14_device_halt_after_set && a14_device_halt_after == 0) {\n"
        "\t\tpr_emerg(\"A14 DEVICE BISECT: halt before device initcall 1\\n\");\n"
        "\t\ta14_acpi_checkpoint(\"device-bisect\");\n"
        "\t}\n\n"
        "\tfor (fn = initcall_levels[level]; fn < initcall_levels[level+1]; fn++) {\n"
        "\t\tinitcall_t call = initcall_from_entry(fn);\n\n"
        "\t\tdo_one_initcall(call);\n"
        "\t\tif (level == 6 && a14_device_halt_after_set) {\n"
        "\t\t\tunsigned int ordinal = fn - initcall_levels[level] + 1;\n\n"
        "\t\t\tif (ordinal == a14_device_halt_after) {\n"
        "\t\t\t\tpr_emerg(\"A14 DEVICE BISECT: completed %u device initcalls; last=%pS\\n\",\n"
        "\t\t\t\t\t ordinal, call);\n"
        "\t\t\t\ta14_acpi_checkpoint(\"device-bisect\");\n"
        "\t\t\t}\n"
        "\t\t}\n"
        "\t}\n\n"
        "\t/* A14 ACPI diagnostic: stop only after complete initcall levels. */\n"
    )
    replace_once(mainc, old, new, "device_bisect_loop")

    final = mainc.read_text()
    for token in ("a14_device_halt_after", "device-bisect", "A14 DEVICE BISECT"):
        if token not in final:
            fail(f"verification missing {token}")

    print("A14_FULL_ACPI_DEVICE_BISECT=APPLIED")


if __name__ == "__main__":
    main()
