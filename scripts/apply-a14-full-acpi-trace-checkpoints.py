#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Upgrade A14 checkpoints to emit breadcrumbs before the selected halt."""
from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 ACPI trace checkpoints: {msg}")


def kernel_version(root: Path) -> str:
    vals = {}
    for line in (root / "Makefile").read_text().splitlines():
        for key in ("VERSION", "PATCHLEVEL", "SUBLEVEL"):
            if line.startswith(key + " ="):
                vals[key] = line.split("=", 1)[1].strip()
    return ".".join(vals[k] for k in ("VERSION", "PATCHLEVEL", "SUBLEVEL"))


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: apply-a14-full-acpi-trace-checkpoints.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file() or kernel_version(root) != KERNEL_VERSION:
        fail(f"targets exactly Linux {KERNEL_VERSION}")

    bus = root / "drivers/acpi/bus.c"
    text = bus.read_text()
    if "A14 ACPI CHECKPOINT REACHED" not in text or "a14_acpi_halt_stage" not in text:
        fail("base A14 checkpoint implementation is missing")

    if 'pr_emerg("A14 ACPI TRACE: %s\\n", stage);' in text:
        print("checkpoint_trace_core=current")
    else:
        old = '''void a14_acpi_checkpoint(const char *stage)\n{\n\tif (!a14_acpi_halt_stage[0] || strcmp(a14_acpi_halt_stage, stage))\n\t\treturn;\n\n\tpr_emerg("============================================================\\n");\n'''
        new = '''void a14_acpi_checkpoint(const char *stage)\n{\n\tif (!a14_acpi_halt_stage[0])\n\t\treturn;\n\n\t/* Every reached checkpoint becomes a breadcrumb in both earlycon and\n\t * PSTORE_CONSOLE. Only the selected stage intentionally stops boot. */\n\tpr_emerg("A14 ACPI TRACE: %s\\n", stage);\n\tif (strcmp(a14_acpi_halt_stage, stage))\n\t\treturn;\n\n\tpr_emerg("============================================================\\n");\n'''
        count = text.count(old)
        if count != 1:
            fail(f"expected one checkpoint core anchor, found {count}")
        bus.write_text(text.replace(old, new, 1))
        print("checkpoint_trace_core=applied")

    final = bus.read_text()
    for token in (
        'A14 ACPI TRACE: %s',
        'A14 ACPI CHECKPOINT REACHED: %s',
        'strcmp(a14_acpi_halt_stage, stage)',
    ):
        if token not in final:
            fail(f"verification missing {token}")

    print("A14_FULL_ACPI_TRACE_CHECKPOINTS=APPLIED")
    print("behavior=trace-every-reached-stage,halt-only-selected-stage")


if __name__ == "__main__":
    main()
