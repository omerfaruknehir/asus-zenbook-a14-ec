#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Add fine-grained checkpoints inside Linux 7.1.5 arm_smmu_device_reset()."""
from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 SMMU reset checkpoints: {msg}")


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
        fail("usage: apply-a14-full-acpi-smmu-reset-checkpoints.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file() or kernel_version(root) != KERNEL_VERSION:
        fail(f"targets exactly Linux {KERNEL_VERSION}")

    path = root / "drivers/iommu/arm/arm-smmu/arm-smmu.c"
    text = path.read_text()
    if '#include <linux/a14_full_acpi.h>' not in text:
        fail("apply the existing A14 SMMU checkpoint transform first")

    text = replace_once(
        text,
        '''static void arm_smmu_device_reset(struct arm_smmu_device *smmu)\n{\n\tint i;\n\tu32 reg;\n\n\t/* clear global FSR */\n''',
        '''static void arm_smmu_device_reset(struct arm_smmu_device *smmu)\n{\n\tint i;\n\tu32 reg;\n\n\ta14_acpi_checkpoint("smmu-reset-enter");\n\n\t/* clear global FSR */\n''',
        "reset_enter",
    )

    text = replace_once(
        text,
        '''\treg = arm_smmu_gr0_read(smmu, ARM_SMMU_GR0_sGFSR);\n\tarm_smmu_gr0_write(smmu, ARM_SMMU_GR0_sGFSR, reg);\n\n\t/*\n''',
        '''\treg = arm_smmu_gr0_read(smmu, ARM_SMMU_GR0_sGFSR);\n\tarm_smmu_gr0_write(smmu, ARM_SMMU_GR0_sGFSR, reg);\n\ta14_acpi_checkpoint("smmu-reset-after-gfsr");\n\n\t/*\n''',
        "reset_after_gfsr",
    )

    text = replace_once(
        text,
        '''\tfor (i = 0; i < smmu->num_mapping_groups; ++i)\n\t\tarm_smmu_write_sme(smmu, i);\n\n\t/* Make sure all context banks are disabled and clear CB_FSR  */\n''',
        '''\tfor (i = 0; i < smmu->num_mapping_groups; ++i)\n\t\tarm_smmu_write_sme(smmu, i);\n\ta14_acpi_checkpoint("smmu-reset-after-streams");\n\n\t/* Make sure all context banks are disabled and clear CB_FSR  */\n''',
        "reset_after_streams",
    )

    text = replace_once(
        text,
        '''\tfor (i = 0; i < smmu->num_context_banks; ++i) {\n\t\tarm_smmu_write_context_bank(smmu, i);\n\t\tarm_smmu_cb_write(smmu, i, ARM_SMMU_CB_FSR, ARM_SMMU_CB_FSR_FAULT);\n\t}\n\n\t/* Invalidate the TLB, just in case */\n''',
        '''\tfor (i = 0; i < smmu->num_context_banks; ++i) {\n\t\tarm_smmu_write_context_bank(smmu, i);\n\t\tarm_smmu_cb_write(smmu, i, ARM_SMMU_CB_FSR, ARM_SMMU_CB_FSR_FAULT);\n\t}\n\ta14_acpi_checkpoint("smmu-reset-after-contexts");\n\n\t/* Invalidate the TLB, just in case */\n''',
        "reset_after_contexts",
    )

    text = replace_once(
        text,
        '''\tarm_smmu_gr0_write(smmu, ARM_SMMU_GR0_TLBIALLH, QCOM_DUMMY_VAL);\n\tarm_smmu_gr0_write(smmu, ARM_SMMU_GR0_TLBIALLNSNH, QCOM_DUMMY_VAL);\n\n\treg = arm_smmu_gr0_read(smmu, ARM_SMMU_GR0_sCR0);\n''',
        '''\tarm_smmu_gr0_write(smmu, ARM_SMMU_GR0_TLBIALLH, QCOM_DUMMY_VAL);\n\tarm_smmu_gr0_write(smmu, ARM_SMMU_GR0_TLBIALLNSNH, QCOM_DUMMY_VAL);\n\ta14_acpi_checkpoint("smmu-reset-after-tlbi");\n\n\treg = arm_smmu_gr0_read(smmu, ARM_SMMU_GR0_sCR0);\n\ta14_acpi_checkpoint("smmu-reset-after-scr0-read");\n''',
        "reset_tlbi_scr0_read",
    )

    text = replace_once(
        text,
        '''\tif (smmu->impl && smmu->impl->reset)\n\t\tsmmu->impl->reset(smmu);\n\n\t/* Push the button */\n\tarm_smmu_tlb_sync_global(smmu);\n\tarm_smmu_gr0_write(smmu, ARM_SMMU_GR0_sCR0, reg);\n''',
        '''\ta14_acpi_checkpoint("smmu-reset-before-impl");\n\tif (smmu->impl && smmu->impl->reset)\n\t\tsmmu->impl->reset(smmu);\n\ta14_acpi_checkpoint("smmu-reset-after-impl");\n\n\t/* Push the button */\n\ta14_acpi_checkpoint("smmu-reset-before-sync");\n\tarm_smmu_tlb_sync_global(smmu);\n\ta14_acpi_checkpoint("smmu-reset-after-sync");\n\ta14_acpi_checkpoint("smmu-reset-before-scr0-write");\n\tarm_smmu_gr0_write(smmu, ARM_SMMU_GR0_sCR0, reg);\n\ta14_acpi_checkpoint("smmu-reset-after-scr0-write");\n''',
        "reset_impl_sync_scr0",
    )

    path.write_text(text)
    final = path.read_text()
    stages = (
        "smmu-reset-enter",
        "smmu-reset-after-gfsr",
        "smmu-reset-after-streams",
        "smmu-reset-after-contexts",
        "smmu-reset-after-tlbi",
        "smmu-reset-after-scr0-read",
        "smmu-reset-before-impl",
        "smmu-reset-after-impl",
        "smmu-reset-before-sync",
        "smmu-reset-after-sync",
        "smmu-reset-before-scr0-write",
        "smmu-reset-after-scr0-write",
    )
    missing = [s for s in stages if s not in final]
    if missing:
        fail(f"verification failed: {missing}")

    print("A14_FULL_ACPI_SMMU_RESET_CHECKPOINTS=APPLIED")
    print("reset_stages=" + ",".join(stages))


if __name__ == "__main__":
    main()
