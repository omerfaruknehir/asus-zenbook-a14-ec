#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Add a bounded delay after non-selected A14 ACPI trace breadcrumbs."""
from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 ACPI trace delay: {msg}")


def kernel_version(root: Path) -> str:
    vals = {}
    for line in (root / "Makefile").read_text().splitlines():
        for key in ("VERSION", "PATCHLEVEL", "SUBLEVEL"):
            if line.startswith(key + " ="):
                vals[key] = line.split("=", 1)[1].strip()
    return ".".join(vals[k] for k in ("VERSION", "PATCHLEVEL", "SUBLEVEL"))


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        print(f"{label}=current")
        return text
    count = text.count(old)
    if count != 1:
        fail(f"{label}: expected one anchor, found {count}")
    print(f"{label}=applied")
    return text.replace(old, new, 1)


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: apply-a14-full-acpi-trace-delay.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file() or kernel_version(root) != KERNEL_VERSION:
        fail(f"targets exactly Linux {KERNEL_VERSION}")

    path = root / "drivers/acpi/bus.c"
    text = path.read_text()
    if 'A14 ACPI TRACE: %s' not in text or 'a14_acpi_reboot_delay_ms' not in text:
        fail("apply the trace/timed-reboot checkpoint transform first")

    if 'early_param("a14_acpi_trace_delay_ms"' in text:
        print("trace_delay_param=current")
    else:
        old = '''early_param("a14_acpi_reboot_delay_ms", a14_acpi_reboot_delay_setup);\n\nvoid a14_acpi_checkpoint(const char *stage)\n'''
        new = '''early_param("a14_acpi_reboot_delay_ms", a14_acpi_reboot_delay_setup);\n\n/* Optional diagnostic-only pause after each non-selected breadcrumb. This\n * makes the last successfully reached stage readable before a following MMIO\n * operation can reset the machine. The GRUB helper currently requests 2 s. */\nstatic unsigned int a14_acpi_trace_delay_ms;\n\nstatic int __init a14_acpi_trace_delay_setup(char *str)\n{\n\tunsigned int value;\n\n\tif (!str || kstrtouint(str, 0, &value))\n\t\treturn 0;\n\tif (value > 10000)\n\t\tvalue = 10000;\n\ta14_acpi_trace_delay_ms = value;\n\treturn 0;\n}\nearly_param("a14_acpi_trace_delay_ms", a14_acpi_trace_delay_setup);\n\nvoid a14_acpi_checkpoint(const char *stage)\n'''
        text = replace_once(text, old, new, "trace_delay_param")

    if 'unsigned int remaining = a14_acpi_trace_delay_ms;' in text:
        print("trace_delay_logic=current")
    else:
        old = '''\tpr_emerg("A14 ACPI TRACE: %s\\n", stage);\n\tif (strcmp(a14_acpi_halt_stage, stage))\n\t\treturn;\n\n'''
        new = '''\tpr_emerg("A14 ACPI TRACE: %s\\n", stage);\n\tif (strcmp(a14_acpi_halt_stage, stage)) {\n\t\tunsigned int remaining = a14_acpi_trace_delay_ms;\n\n\t\twhile (remaining) {\n\t\t\tunsigned int step = remaining > 100 ? 100 : remaining;\n\n\t\t\ttouch_nmi_watchdog();\n\t\t\tmdelay(step);\n\t\t\tremaining -= step;\n\t\t}\n\t\treturn;\n\t}\n\n'''
        text = replace_once(text, old, new, "trace_delay_logic")

    path.write_text(text)
    final = path.read_text()
    for token in (
        'a14_acpi_trace_delay_ms',
        'early_param("a14_acpi_trace_delay_ms"',
        'unsigned int remaining = a14_acpi_trace_delay_ms;',
    ):
        if token not in final:
            fail(f"verification missing {token}")

    print("A14_FULL_ACPI_TRACE_DELAY=APPLIED")
    print("trace_delay_scope=non-selected-checkpoints")
    print("trace_delay_max_ms=10000")


if __name__ == "__main__":
    main()
