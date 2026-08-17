#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Add selectable early-boot checkpoints to the A14 full-ACPI kernel.

The checkpoints are diagnostics only.  Boot with, for example,

    a14_acpi_halt=acpi-early-enter

and the kernel intentionally remains at that exact point.  This lets us locate
an otherwise unlogged firmware/reset boundary without relying on initramfs,
pstore, or a readable last console line.
"""
from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 ACPI checkpoints: {msg}")


def kernel_version(root: Path) -> str:
    vals = {}
    for line in (root / "Makefile").read_text().splitlines():
        for key in ("VERSION", "PATCHLEVEL", "SUBLEVEL"):
            if line.startswith(key + " ="):
                vals[key] = line.split("=", 1)[1].strip()
    try:
        return ".".join(vals[k] for k in ("VERSION", "PATCHLEVEL", "SUBLEVEL"))
    except KeyError as exc:
        fail(f"cannot determine kernel version: {exc}")


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
        fail("usage: apply-a14-full-acpi-checkpoints.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file():
        fail(f"not a kernel tree: {root}")
    if kernel_version(root) != KERNEL_VERSION:
        fail(f"targets exactly Linux {KERNEL_VERSION}")

    marker = root / "include/linux/a14_full_acpi.h"
    if not marker.is_file() or "A14_FULL_ACPI_V0" not in marker.read_text():
        fail("base A14 full-ACPI transform is not present")

    replace_once(
        marker,
        "#define A14_FULL_ACPI_V0 1\n#endif\n",
        "#define A14_FULL_ACPI_V0 1\n\n"
        "void a14_acpi_checkpoint(const char *stage);\n\n"
        "#endif\n",
        "checkpoint_header",
    )

    bus = root / "drivers/acpi/bus.c"
    replace_once(
        bus,
        "#include <linux/prmt.h>\n\n#include \"internal.h\"\n",
        "#include <linux/prmt.h>\n"
        "#include <linux/nmi.h>\n"
        "#include <linux/string.h>\n"
        "#include <linux/a14_full_acpi.h>\n\n"
        "#include \"internal.h\"\n",
        "checkpoint_bus_includes",
    )

    replace_once(
        bus,
        "struct acpi_device *acpi_root;\n"
        "struct proc_dir_entry *acpi_root_dir;\n"
        "EXPORT_SYMBOL(acpi_root_dir);\n",
        "struct acpi_device *acpi_root;\n"
        "struct proc_dir_entry *acpi_root_dir;\n"
        "EXPORT_SYMBOL(acpi_root_dir);\n\n"
        "/* A14 full-ACPI diagnostic only: selected with a14_acpi_halt=<stage>. */\n"
        "static char a14_acpi_halt_stage[40];\n\n"
        "static int __init a14_acpi_halt_setup(char *str)\n"
        "{\n"
        "\tif (!str || !*str)\n"
        "\t\treturn 0;\n\n"
        "\tstrscpy(a14_acpi_halt_stage, str, sizeof(a14_acpi_halt_stage));\n"
        "\treturn 0;\n"
        "}\n"
        "early_param(\"a14_acpi_halt\", a14_acpi_halt_setup);\n\n"
        "void a14_acpi_checkpoint(const char *stage)\n"
        "{\n"
        "\tif (!a14_acpi_halt_stage[0] || strcmp(a14_acpi_halt_stage, stage))\n"
        "\t\treturn;\n\n"
        "\tpr_emerg(\"============================================================\\n\");\n"
        "\tpr_emerg(\"A14 ACPI CHECKPOINT REACHED: %s\\n\", stage);\n"
        "\tpr_emerg(\"Intentional hold. If this machine reboots anyway, the reset is external to later kernel boot code.\\n\");\n"
        "\tpr_emerg(\"============================================================\\n\");\n\n"
        "\tfor (;;) {\n"
        "\t\tint i;\n\n"
        "\t\t/* Avoid Linux software lockup noise while still allowing an\n"
        "\t\t * independently armed firmware/SoC watchdog to reveal itself. */\n"
        "\t\ttouch_nmi_watchdog();\n"
        "\t\tfor (i = 0; i < 100; i++)\n"
        "\t\t\tmdelay(10);\n"
        "\t}\n"
        "}\n",
        "checkpoint_core",
    )

    replace_once(
        bus,
        "\tif (acpi_disabled)\n\t\treturn;\n\n\tpr_info(\"Core revision %08x\\n\", ACPI_CA_VERSION);\n",
        "\tif (acpi_disabled)\n\t\treturn;\n\n"
        "\ta14_acpi_checkpoint(\"acpi-early-enter\");\n\n"
        "\tpr_info(\"Core revision %08x\\n\", ACPI_CA_VERSION);\n",
        "checkpoint_acpi_early_enter",
    )

    replace_once(
        bus,
        "\tstatus = acpi_initialize_subsystem();\n"
        "\tif (ACPI_FAILURE(status)) {\n"
        "\t\tpr_err(\"Unable to initialize the ACPI Interpreter\\n\");\n"
        "\t\tgoto error0;\n"
        "\t}\n\n#ifdef CONFIG_X86\n",
        "\tstatus = acpi_initialize_subsystem();\n"
        "\tif (ACPI_FAILURE(status)) {\n"
        "\t\tpr_err(\"Unable to initialize the ACPI Interpreter\\n\");\n"
        "\t\tgoto error0;\n"
        "\t}\n\n"
        "\ta14_acpi_checkpoint(\"acpi-early-after-subsystem\");\n\n"
        "#ifdef CONFIG_X86\n",
        "checkpoint_acpi_early_after_subsystem",
    )

    # acpi_subsystem_init() has another identical `if (acpi_disabled) return;`,
    # so anchor the function signature too.
    replace_once(
        bus,
        "void __init acpi_subsystem_init(void)\n"
        "{\n"
        "\tacpi_status status;\n\n"
        "\tif (acpi_disabled)\n"
        "\t\treturn;\n\n"
        "\tstatus = acpi_enable_subsystem(~ACPI_NO_ACPI_ENABLE);\n",
        "void __init acpi_subsystem_init(void)\n"
        "{\n"
        "\tacpi_status status;\n\n"
        "\tif (acpi_disabled)\n"
        "\t\treturn;\n\n"
        "\ta14_acpi_checkpoint(\"acpi-subsystem-enter\");\n\n"
        "\tstatus = acpi_enable_subsystem(~ACPI_NO_ACPI_ENABLE);\n",
        "checkpoint_acpi_subsystem_enter",
    )

    replace_once(
        bus,
        "\t\tregulator_has_full_constraints();\n"
        "\t}\n"
        "}\n\n"
        "static acpi_status acpi_bus_table_handler",
        "\t\tregulator_has_full_constraints();\n"
        "\t}\n\n"
        "\ta14_acpi_checkpoint(\"acpi-subsystem-after-enable\");\n"
        "}\n\n"
        "static acpi_status acpi_bus_table_handler",
        "checkpoint_acpi_subsystem_after_enable",
    )

    replace_once(
        bus,
        "static int __init acpi_init(void)\n"
        "{\n"
        "\tint result;\n\n"
        "\tif (acpi_disabled) {\n"
        "\t\tpr_info(\"Interpreter disabled.\\n\");\n"
        "\t\treturn -ENODEV;\n"
        "\t}\n\n"
        "\tacpi_kobj = kobject_create_and_add(\"acpi\", firmware_kobj);\n",
        "static int __init acpi_init(void)\n"
        "{\n"
        "\tint result;\n\n"
        "\tif (acpi_disabled) {\n"
        "\t\tpr_info(\"Interpreter disabled.\\n\");\n"
        "\t\treturn -ENODEV;\n"
        "\t}\n\n"
        "\ta14_acpi_checkpoint(\"acpi-init-enter\");\n\n"
        "\tacpi_kobj = kobject_create_and_add(\"acpi\", firmware_kobj);\n",
        "checkpoint_acpi_init_enter",
    )

    replace_once(
        bus,
        "\tresult = acpi_bus_init();\n"
        "\tif (result) {\n"
        "\t\tkobject_put(acpi_kobj);\n"
        "\t\tdisable_acpi();\n"
        "\t\treturn result;\n"
        "\t}\n"
        "\tacpi_init_ffh();\n",
        "\tresult = acpi_bus_init();\n"
        "\tif (result) {\n"
        "\t\tkobject_put(acpi_kobj);\n"
        "\t\tdisable_acpi();\n"
        "\t\treturn result;\n"
        "\t}\n\n"
        "\ta14_acpi_checkpoint(\"acpi-bus-done\");\n"
        "\tacpi_init_ffh();\n",
        "checkpoint_acpi_bus_done",
    )

    replace_once(
        bus,
        "\tacpi_ghes_init();\n"
        "\tacpi_arch_init();\n"
        "\tacpi_scan_init();\n"
        "\tacpi_ec_init();\n",
        "\tacpi_ghes_init();\n"
        "\tacpi_arch_init();\n"
        "\ta14_acpi_checkpoint(\"acpi-scan-before\");\n"
        "\tacpi_scan_init();\n"
        "\ta14_acpi_checkpoint(\"acpi-scan-after\");\n"
        "\tacpi_ec_init();\n",
        "checkpoint_acpi_scan",
    )

    pci = root / "drivers/pci/pci-acpi.c"
    replace_once(
        pci,
        "#include <linux/rwsem.h>\n#include \"pci.h\"\n",
        "#include <linux/rwsem.h>\n"
        "#include <linux/a14_full_acpi.h>\n"
        "#include \"pci.h\"\n",
        "checkpoint_pci_include",
    )
    replace_once(
        pci,
        "static int __init acpi_pci_init(void)\n"
        "{\n"
        "\tif (acpi_gbl_FADT.boot_flags & ACPI_FADT_NO_MSI) {\n",
        "static int __init acpi_pci_init(void)\n"
        "{\n"
        "\ta14_acpi_checkpoint(\"pci-acpi-enter\");\n\n"
        "\tif (acpi_gbl_FADT.boot_flags & ACPI_FADT_NO_MSI) {\n",
        "checkpoint_pci_enter",
    )
    replace_once(
        pci,
        "\tacpi_pci_slot_init();\n"
        "\tacpiphp_init();\n\n"
        "\treturn 0;\n"
        "}\n"
        "arch_initcall(acpi_pci_init);\n",
        "\tacpi_pci_slot_init();\n"
        "\tacpiphp_init();\n\n"
        "\ta14_acpi_checkpoint(\"pci-acpi-after\");\n"
        "\treturn 0;\n"
        "}\n"
        "arch_initcall(acpi_pci_init);\n",
        "checkpoint_pci_after",
    )

    expected = [
        "acpi-early-enter",
        "acpi-early-after-subsystem",
        "acpi-subsystem-enter",
        "acpi-subsystem-after-enable",
        "pci-acpi-enter",
        "pci-acpi-after",
        "acpi-init-enter",
        "acpi-bus-done",
        "acpi-scan-before",
        "acpi-scan-after",
    ]
    combined = bus.read_text() + pci.read_text()
    missing = [stage for stage in expected if stage not in combined]
    if missing:
        fail(f"checkpoint verification failed: {missing}")

    print("A14_FULL_ACPI_CHECKPOINTS=APPLIED")
    print("stages=" + ",".join(expected))


if __name__ == "__main__":
    main()
