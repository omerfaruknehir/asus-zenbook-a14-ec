#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Add targeted checkpoints inside Linux 7.1.5 arm_smmu_init()."""
from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 SMMU checkpoints: {msg}")


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
        fail("usage: apply-a14-full-acpi-smmu-checkpoints.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file() or kernel_version(root) != KERNEL_VERSION:
        fail(f"targets exactly Linux {KERNEL_VERSION}")

    hdr = root / "include/linux/a14_full_acpi.h"
    smmu = root / "drivers/iommu/arm/arm-smmu/arm-smmu.c"
    if not hdr.is_file() or "a14_acpi_checkpoint" not in hdr.read_text():
        fail("apply the base A14 checkpoint transform first")

    replace_once(
        smmu,
        '#include <linux/acpi.h>\n',
        '#include <linux/acpi.h>\n#include <linux/a14_full_acpi.h>\n',
        'smmu_checkpoint_include',
    )

    old = '''static int __init arm_smmu_init(void)\n{\n\tint ret;\n\n\tret = platform_driver_register(&arm_smmu_driver);\n\tif (ret)\n\t\treturn ret;\n\n\tret = arm_smmu_impl_module_init();\n\tif (ret)\n\t\tplatform_driver_unregister(&arm_smmu_driver);\n\n\treturn ret;\n}\n'''
    new = '''static int __init arm_smmu_init(void)\n{\n\tint ret;\n\n\ta14_acpi_checkpoint("smmu-init-enter");\n\n\tret = platform_driver_register(&arm_smmu_driver);\n\tif (ret)\n\t\treturn ret;\n\n\ta14_acpi_checkpoint("smmu-driver-registered");\n\n\tret = arm_smmu_impl_module_init();\n\tif (ret)\n\t\tplatform_driver_unregister(&arm_smmu_driver);\n\n\ta14_acpi_checkpoint("smmu-impl-registered");\n\n\treturn ret;\n}\n'''
    replace_once(smmu, old, new, 'smmu_init_checkpoints')

    text = smmu.read_text()
    for stage in ("smmu-init-enter", "smmu-driver-registered", "smmu-impl-registered"):
        if stage not in text:
            fail(f"verification failed: {stage} missing")

    print("A14_FULL_ACPI_SMMU_CHECKPOINTS=APPLIED")
    print("stages=smmu-init-enter,smmu-driver-registered,smmu-impl-registered")


if __name__ == "__main__":
    main()
