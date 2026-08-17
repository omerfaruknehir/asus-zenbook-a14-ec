#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Mirror X1's DT/Gunyah PCIe-SMMUv3 ownership rule for A14 ACPI boot.

On X1, upstream x1-el2.dtso only enables pcie_smmu when Linux owns EL2.
The Windows-oriented A14 IORT nevertheless describes that SMMUv3 to Linux at
EL1, where touching its registers causes a synchronous external abort.  For the
exact A14 QCOM/QCOMEDK2 IORT revision and PCIe-SMMUv3 base, do not create a
Linux platform device/fwnode at EL1. Existing IORT translation then naturally
returns -ENODEV for PCI clients, which ACPI DMA setup treats as "no Linux
IOMMU" rather than EPROBE_DEFER.
"""

from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 PCIe SMMUv3 ownership: {msg}")


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
        fail("usage: apply-a14-full-acpi-pcie-smmuv3-firmware-owned.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file() or kernel_version(root) != KERNEL_VERSION:
        fail(f"targets exactly Linux {KERNEL_VERSION}")

    path = root / "drivers/acpi/arm64/iort.c"
    text = path.read_text()

    text = replace_once(
        text,
        '#include <linux/dma-map-ops.h>\n#include "init.h"\n',
        '#include <linux/dma-map-ops.h>\n#include <asm/virt.h>\n#include "init.h"\n',
        "arm64_virt_include",
    )

    helper = r'''/*
 * The X1 DT intentionally leaves pcie_smmu disabled when Linux runs under
 * Gunyah at EL1; arch/arm64/boot/dts/qcom/x1-el2.dtso only enables it when
 * Linux takes ownership in EL2.  The A14 Windows IORT still exposes the same
 * SMMUv3 at 0x15400000, and probing it from EL1 raises an external abort.
 *
 * Keep this quirk deliberately exact: one OEM/table revision, one SMMUv3
 * base, and EL1 only.  At EL2 the normal IORT path remains untouched.
 */
static bool __init a14_iort_pcie_smmuv3_firmware_owned(
						struct acpi_iort_node *node)
{
	struct acpi_iort_smmu_v3 *smmu;

	if (!iort_table || node->type != ACPI_IORT_NODE_SMMU_V3 ||
	    is_kernel_in_hyp_mode())
		return false;

	if (memcmp(iort_table->oem_id, "QCOM  ", ACPI_OEM_ID_SIZE) ||
	    memcmp(iort_table->oem_table_id, "QCOMEDK2", ACPI_OEM_TABLE_ID_SIZE) ||
	    iort_table->oem_revision != 0x8380)
		return false;

	smmu = (struct acpi_iort_smmu_v3 *)node->node_data;
	return smmu->base_address == 0x15400000;
}

'''

    anchor = 'static void __init iort_init_platform_devices(void)\n{\n'
    if helper in text:
        print("ownership_helper=current")
    else:
        count = text.count(anchor)
        if count != 1:
            fail(f"ownership_helper: expected one iort_init_platform_devices anchor, found {count}")
        text = text.replace(anchor, helper + anchor, 1)
        print("ownership_helper=applied")

    old = '''\t\tiort_enable_acs(iort_node);\n\n\t\tops = iort_get_dev_cfg(iort_node);\n'''
    new = '''\t\tif (a14_iort_pcie_smmuv3_firmware_owned(iort_node)) {\n\t\t\tstruct acpi_iort_smmu_v3 *smmu =\n\t\t\t\t(struct acpi_iort_smmu_v3 *)iort_node->node_data;\n\n\t\t\tpr_info("A14: leaving PCIe SMMUv3[%llx] firmware-owned at EL1\\n",\n\t\t\t\tsmmu->base_address);\n\t\t\tgoto next_iort_node;\n\t\t}\n\n\t\tiort_enable_acs(iort_node);\n\n\t\tops = iort_get_dev_cfg(iort_node);\n'''
    text = replace_once(text, old, new, "ownership_skip")

    old = '''\t\tiort_node = ACPI_ADD_PTR(struct acpi_iort_node, iort_node,\n\t\t\t\t\tiort_node->length);\n\t}\n}\n\nvoid __init acpi_iort_init(void)\n'''
    new = '''next_iort_node:\n\t\tiort_node = ACPI_ADD_PTR(struct acpi_iort_node, iort_node,\n\t\t\t\t\tiort_node->length);\n\t}\n}\n\nvoid __init acpi_iort_init(void)\n'''
    text = replace_once(text, old, new, "ownership_next_label")

    path.write_text(text)
    final = path.read_text()
    required = (
        '#include <asm/virt.h>',
        'a14_iort_pcie_smmuv3_firmware_owned',
        'iort_table->oem_revision != 0x8380',
        'smmu->base_address == 0x15400000',
        'is_kernel_in_hyp_mode()',
        'A14: leaving PCIe SMMUv3[%llx] firmware-owned at EL1',
        'goto next_iort_node;',
        'next_iort_node:',
    )
    missing = [token for token in required if token not in final]
    if missing:
        fail(f"verification missing: {missing}")

    if final.count('static bool __init a14_iort_pcie_smmuv3_firmware_owned(') != 1:
        fail("ownership helper duplicated")
    if final.count('next_iort_node:') != 1:
        fail("next_iort_node label duplicated")

    print("A14_FULL_ACPI_PCIE_SMMUV3_OWNERSHIP=APPLIED")
    print("oem_id=QCOM")
    print("oem_table_id=QCOMEDK2")
    print("oem_revision=0x8380")
    print("smmuv3_base=0x15400000")
    print("el1_behavior=firmware-owned-no-linux-platform-device")
    print("el2_behavior=normal-iort-linux-owned")


if __name__ == "__main__":
    main()
