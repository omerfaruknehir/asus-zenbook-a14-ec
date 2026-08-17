#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Extend the A14 full-ACPI diagnostic checkpoints into late kernel init."""
from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 ACPI late checkpoints: {msg}")


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
        fail("usage: apply-a14-full-acpi-late-checkpoints.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file() or kernel_version(root) != KERNEL_VERSION:
        fail(f"targets exactly Linux {KERNEL_VERSION}")

    hdr = root / "include/linux/a14_full_acpi.h"
    bus = root / "drivers/acpi/bus.c"
    mainc = root / "init/main.c"
    if not hdr.is_file() or "a14_acpi_checkpoint" not in hdr.read_text():
        fail("apply the base checkpoint transform first")
    if "A14 ACPI CHECKPOINT REACHED" not in bus.read_text():
        fail("base checkpoint implementation missing")

    replace_once(
        bus,
        "\tacpi_setup_sb_notify_handler();\n"
        "\tacpi_viot_init();\n"
        "\treturn 0;\n"
        "}\n\n"
        "subsys_initcall(acpi_init);\n",
        "\tacpi_setup_sb_notify_handler();\n"
        "\tacpi_viot_init();\n"
        "\ta14_acpi_checkpoint(\"acpi-init-done\");\n"
        "\treturn 0;\n"
        "}\n\n"
        "subsys_initcall(acpi_init);\n",
        "checkpoint_acpi_init_done",
    )

    replace_once(
        mainc,
        "#include <linux/acpi.h>\n#include <linux/bootconfig.h>\n",
        "#include <linux/acpi.h>\n"
        "#include <linux/a14_full_acpi.h>\n"
        "#include <linux/bootconfig.h>\n",
        "checkpoint_main_include",
    )

    initcall_stages = (
        "initcall-subsys-after",
        "initcall-fs-after",
        "initcall-device-after",
        "initcall-late-after",
    )
    main_text = mainc.read_text()
    if all(f'a14_acpi_checkpoint("{stage}")' in main_text for stage in initcall_stages):
        # The later device-bisect transform intentionally rewrites the initcall
        # loop while preserving these four level checkpoints.  Treat that tree
        # as already current instead of requiring the original pre-bisect loop
        # anchor to still exist.
        print("checkpoint_initcall_levels=current")
    else:
        replace_once(
            mainc,
            "\tdo_trace_initcall_level(initcall_level_names[level]);\n"
            "\tfor (fn = initcall_levels[level]; fn < initcall_levels[level+1]; fn++)\n"
            "\t\tdo_one_initcall(initcall_from_entry(fn));\n"
            "}\n",
            "\tdo_trace_initcall_level(initcall_level_names[level]);\n"
            "\tfor (fn = initcall_levels[level]; fn < initcall_levels[level+1]; fn++)\n"
            "\t\tdo_one_initcall(initcall_from_entry(fn));\n\n"
            "\t/* A14 ACPI diagnostic: stop only after complete initcall levels. */\n"
            "\tswitch (level) {\n"
            "\tcase 4:\n"
            "\t\ta14_acpi_checkpoint(\"initcall-subsys-after\");\n"
            "\t\tbreak;\n"
            "\tcase 5:\n"
            "\t\ta14_acpi_checkpoint(\"initcall-fs-after\");\n"
            "\t\tbreak;\n"
            "\tcase 6:\n"
            "\t\ta14_acpi_checkpoint(\"initcall-device-after\");\n"
            "\t\tbreak;\n"
            "\tcase 7:\n"
            "\t\ta14_acpi_checkpoint(\"initcall-late-after\");\n"
            "\t\tbreak;\n"
            "\t}\n"
            "}\n",
            "checkpoint_initcall_levels",
        )

    expected = [
        "acpi-init-done",
        *initcall_stages,
    ]
    combined = bus.read_text() + mainc.read_text()
    missing = [stage for stage in expected if stage not in combined]
    if missing:
        fail(f"late checkpoint verification failed: {missing}")

    print("A14_FULL_ACPI_LATE_CHECKPOINTS=APPLIED")
    print("stages=" + ",".join(expected))


if __name__ == "__main__":
    main()
