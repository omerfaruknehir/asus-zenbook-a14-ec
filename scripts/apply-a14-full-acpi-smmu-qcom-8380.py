#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Recognize the A14/QCOMEDK2 IORT OEM revision in arm-smmu-qcom ACPI mode.

Linux's Qualcomm ARM-SMMU implementation currently matches QCOM/QCOMEDK2
IORT OEM revision 0x8180 exactly. The ASUS Zenbook A14 UX3407RA firmware dump
uses QCOM/QCOMEDK2 OEM revision 0x8380, so ACPI boot otherwise falls through
to the generic ARM-SMMU implementation. Add the observed revision alongside
the upstream entry. DT matching is untouched.
"""
from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"
OLD = '\t{ "QCOM  ", "QCOMEDK2", 0x8180, ACPI_SIG_IORT, equal, "QCOM SMMU" },\n'
NEW_LINE = '\t{ "QCOM  ", "QCOMEDK2", 0x8380, ACPI_SIG_IORT, equal, "QCOM SMMU A14" },\n'


def fail(msg: str) -> None:
    raise SystemExit(f"A14 QCOM SMMU ACPI 0x8380: {msg}")


def kernel_version(root: Path) -> str:
    vals = {}
    for line in (root / "Makefile").read_text().splitlines():
        for key in ("VERSION", "PATCHLEVEL", "SUBLEVEL"):
            if line.startswith(key + " ="):
                vals[key] = line.split("=", 1)[1].strip()
    return ".".join(vals[k] for k in ("VERSION", "PATCHLEVEL", "SUBLEVEL"))


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: apply-a14-full-acpi-smmu-qcom-8380.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file() or kernel_version(root) != KERNEL_VERSION:
        fail(f"targets exactly Linux {KERNEL_VERSION}")

    path = root / "drivers/iommu/arm/arm-smmu/arm-smmu-qcom.c"
    text = path.read_text()

    if NEW_LINE in text:
        print("qcom_iort_8380_match=current")
    else:
        count = text.count(OLD)
        if count != 1:
            fail(f"expected exactly one upstream QCOMEDK2 0x8180 anchor, found {count}")
        text = text.replace(OLD, OLD + NEW_LINE, 1)
        path.write_text(text)
        print("qcom_iort_8380_match=applied")

    final = path.read_text()
    if NEW_LINE not in final:
        fail("verification failed: 0x8380 matcher missing")
    if final.count(NEW_LINE) != 1:
        fail("verification failed: 0x8380 matcher duplicated")
    if OLD not in final:
        fail("verification failed: upstream 0x8180 matcher was disturbed")

    print("A14_FULL_ACPI_QCOM_SMMU_8380=APPLIED")
    print("oem_id=QCOM")
    print("oem_table_id=QCOMEDK2")
    print("oem_revision=0x8380")
    print("selected_impl=qcom_smmu_500_impl0_data")
    print("dt_matching=unchanged")


if __name__ == "__main__":
    main()
