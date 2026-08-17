#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Upgrade A14 checkpoints to emit breadcrumbs and reboot after a timed wait."""
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


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        fail(f"{label}: expected one anchor, found {count}")
    print(f"{label}=applied")
    return text.replace(old, new, 1)


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

    # First upgrade: every reached checkpoint is visible/saved, while only the
    # selected checkpoint enters the timed diagnostic stop/reboot sequence.
    if 'pr_emerg("A14 ACPI TRACE: %s\\n", stage);' in text:
        print("checkpoint_trace_core=current")
    else:
        old = '''void a14_acpi_checkpoint(const char *stage)\n{\n\tif (!a14_acpi_halt_stage[0] || strcmp(a14_acpi_halt_stage, stage))\n\t\treturn;\n\n\tpr_emerg("============================================================\\n");\n'''
        new = '''void a14_acpi_checkpoint(const char *stage)\n{\n\tif (!a14_acpi_halt_stage[0])\n\t\treturn;\n\n\t/* Every reached checkpoint becomes a breadcrumb in both earlycon and\n\t * PSTORE_CONSOLE. Only the selected stage enters the timed reboot. */\n\tpr_emerg("A14 ACPI TRACE: %s\\n", stage);\n\tif (strcmp(a14_acpi_halt_stage, stage))\n\t\treturn;\n\n\tpr_emerg("============================================================\\n");\n'''
        text = replace_once(text, old, new, "checkpoint_trace_core")

    # Configurable bounded wait. The helper explicitly supplies 5000 ms, and
    # 5000 ms is also the kernel-side default for older checkpoint selectors.
    if 'early_param("a14_acpi_reboot_delay_ms"' in text:
        print("checkpoint_reboot_param=current")
    else:
        old = '''early_param("a14_acpi_halt", a14_acpi_halt_setup);\n\nvoid a14_acpi_checkpoint(const char *stage)\n'''
        new = '''early_param("a14_acpi_halt", a14_acpi_halt_setup);\n\n/* Bounded diagnostic wait: never require a manual power cycle to leave a\n * reached checkpoint, because that can destroy the ramoops evidence. */\nstatic unsigned int a14_acpi_reboot_delay_ms = 5000;\n\nstatic int __init a14_acpi_reboot_delay_setup(char *str)\n{\n\tunsigned int value;\n\n\tif (!str || kstrtouint(str, 0, &value))\n\t\treturn 0;\n\tif (value > 60000)\n\t\tvalue = 60000;\n\ta14_acpi_reboot_delay_ms = value;\n\treturn 0;\n}\nearly_param("a14_acpi_reboot_delay_ms", a14_acpi_reboot_delay_setup);\n\nvoid a14_acpi_checkpoint(const char *stage)\n'''
        text = replace_once(text, old, new, "checkpoint_reboot_param")

    # Replace the old intentional infinite hold. emergency_restart() performs a
    # KMSG_DUMP_EMERG first, giving pstore/ramoops a final chance to persist the
    # kernel log, then uses the architecture emergency restart path.
    if 'A14 ACPI CHECKPOINT REBOOT NOW: %s' in text:
        print("checkpoint_timed_reboot=current")
    else:
        old = '''\tpr_emerg("Intentional hold. If this machine reboots anyway, the reset is external to later kernel boot code.\\n");\n\tpr_emerg("============================================================\\n");\n\n\tfor (;;) {\n\t\tint i;\n\n\t\t/* Avoid Linux software lockup noise while still allowing an\n\t\t * independently armed firmware/SoC watchdog to reveal itself. */\n\t\ttouch_nmi_watchdog();\n\t\tfor (i = 0; i < 100; i++)\n\t\t\tmdelay(10);\n\t}\n}\n'''
        new = '''\tpr_emerg("Timed checkpoint: preserving logs, then rebooting automatically in %u ms.\\n",\n\t\t a14_acpi_reboot_delay_ms);\n\tpr_emerg("============================================================\\n");\n\n\t{\n\t\tunsigned int remaining = a14_acpi_reboot_delay_ms;\n\n\t\twhile (remaining) {\n\t\t\tunsigned int step = remaining > 100 ? 100 : remaining;\n\n\t\t\t/* Keep Linux watchdog bookkeeping alive during the bounded\n\t\t\t * visibility/log-settle delay. */\n\t\t\ttouch_nmi_watchdog();\n\t\t\tmdelay(step);\n\t\t\tremaining -= step;\n\t\t}\n\t}\n\n\tpr_emerg("A14 ACPI CHECKPOINT REBOOT NOW: %s\\n", stage);\n\temergency_restart();\n\n\t/* emergency_restart() should never return. If the platform restart\n\t * handler itself is broken, keep the failure visible instead of\n\t * continuing execution past a diagnostic checkpoint. */\n\tpr_emerg("A14 ACPI ERROR: emergency_restart returned; restart path failed\\n");\n\tfor (;;)\n\t\tmdelay(1000);\n}\n'''
        text = replace_once(text, old, new, "checkpoint_timed_reboot")

    bus.write_text(text)
    final = bus.read_text()
    for token in (
        'A14 ACPI TRACE: %s',
        'A14 ACPI CHECKPOINT REACHED: %s',
        'a14_acpi_reboot_delay_ms',
        'A14 ACPI CHECKPOINT REBOOT NOW: %s',
        'emergency_restart();',
        'strcmp(a14_acpi_halt_stage, stage)',
    ):
        if token not in final:
            fail(f"verification missing {token}")

    if "Intentional hold. If this machine reboots anyway" in final:
        fail("old infinite checkpoint hold is still present")

    print("A14_FULL_ACPI_TRACE_CHECKPOINTS=APPLIED")
    print("behavior=trace-every-reached-stage,timed-wait-then-emergency-reboot")
    print("default_reboot_delay_ms=5000")


if __name__ == "__main__":
    main()
