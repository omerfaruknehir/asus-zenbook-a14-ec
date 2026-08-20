#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Make the A14 strict multi-ID IORT path initialize NC metadata once.

The existing A14 helper correctly maps every explicit IORT input ID before
arch_setup_dma_ops(), but it calls upstream iort_iommu_configure_id() once per
ID.  For Named Components, every successful call invokes
`iort_named_component_init()`, which creates a managed software node.  GPU0 has
two input IDs, so the second call attempts to create the same `software_node`
sysfs link again and triggers sysfs_warn_dup().

This transform adds a built-in, non-exported multi-ID IORT primitive for Named
Components.  It scans the Named Component once, maps every requested ID into
the same fwspec, and calls iort_named_component_init() exactly once.  The
exported ACPI helper and msm.ko ABI remain unchanged.
"""

from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"
MARKER = "A14_IORT_NCOMP_MULTI_ID_INIT_ONCE_V1"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 GPU0 IORT multi-ID transform: {msg}")


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


def verify(root: Path) -> None:
    iort = (root / "drivers/acpi/arm64/iort.c").read_text()
    hdr = (root / "include/linux/acpi_iort.h").read_text()
    scan = (root / "drivers/acpi/scan.c").read_text()

    required_iort = [
        MARKER,
        "int iort_iommu_configure_ids(struct device *dev, const u32 *ids,",
        "iort_nc_iommu_map_id(dev, node, &ids[i])",
        "iort_named_component_init(dev, node);",
    ]
    for token in required_iort:
        if token not in iort:
            fail(f"iort verification missing {token}")

    if iort.count(MARKER) != 1:
        fail(f"expected exactly one {MARKER}")
    if hdr.count("iort_iommu_configure_ids") != 2:
        fail("expected real + stub iort_iommu_configure_ids declarations")
    if "ret = iort_iommu_configure_ids(dev, input_ids, num_ids);" not in scan:
        fail("ACPI helper does not use the multi-ID IORT primitive")
    if "for (i = 0; i < num_ids; i++)" in scan:
        fail("old repeated single-ID IORT loop remains")
    if "EXPORT_SYMBOL_GPL(iort_iommu_configure_ids)" in iort:
        fail("multi-ID IORT primitive must remain built-in/private")


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: apply-a14-full-acpi-gpu0-iort-multi-id-v1.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file():
        fail(f"not a kernel source tree: {root}")
    found = kernel_version(root)
    if found != KERNEL_VERSION:
        fail(f"targets exactly {KERNEL_VERSION}; found {found}")

    iort = root / "drivers/acpi/arm64/iort.c"
    hdr = root / "include/linux/acpi_iort.h"
    scan = root / "drivers/acpi/scan.c"
    msm = root / "drivers/gpu/drm/msm/msm_drv.c"
    for path in (iort, hdr, scan, msm):
        if not path.is_file():
            fail(f"missing {path}")

    # Require every already-proven layer before making this surgical change.
    for path, token, name in (
        (iort, "A14_IORT_NCOMP_NO_TRAILING_V1", "QCOM0C36 IORT pathname fix"),
        (scan, "A14_ACPI_DMA_IORT_IDS_V1", "strict pre-DMA multi-ID ACPI helper"),
        (scan, "A14_QCOM0C36_PLATFORM_ENUM_V1", "QCOM0C36 platform enumeration"),
        (msm, "A14_QCOM0C36_TOPOLOGY_V1", "GPU topology bridge"),
    ):
        if token not in path.read_text():
            fail(f"required prior layer missing: {name}")

    if MARKER in iort.read_text():
        verify(root)
        print("iort_multi_id_named_component_init_once=current")
        print("A14_IORT_NCOMP_MULTI_ID_INIT_ONCE_V1=APPLIED")
        return

    # Add the built-in interface next to the existing single-ID interface.
    replace_once(
        hdr,
        "int iort_iommu_configure_id(struct device *dev, const u32 *id_in);\n"
        "void iort_iommu_get_resv_regions(struct device *dev, struct list_head *head);\n",
        "int iort_iommu_configure_id(struct device *dev, const u32 *id_in);\n"
        "int iort_iommu_configure_ids(struct device *dev, const u32 *ids, size_t num_ids);\n"
        "void iort_iommu_get_resv_regions(struct device *dev, struct list_head *head);\n",
        "iort_multi_id_declaration",
    )
    replace_once(
        hdr,
        "static inline int iort_iommu_configure_id(struct device *dev, const u32 *id_in)\n"
        "{ return -ENODEV; }\n"
        "static inline\n"
        "void iort_iommu_get_resv_regions(struct device *dev, struct list_head *head)\n",
        "static inline int iort_iommu_configure_id(struct device *dev, const u32 *id_in)\n"
        "{ return -ENODEV; }\n"
        "static inline int iort_iommu_configure_ids(struct device *dev, const u32 *ids, size_t num_ids)\n"
        "{ return -ENODEV; }\n"
        "static inline\n"
        "void iort_iommu_get_resv_regions(struct device *dev, struct list_head *head)\n",
        "iort_multi_id_stub",
    )

    # Keep upstream single-ID semantics untouched.  The new primitive is used
    # only by the A14 strict ACPI helper and is deliberately Named-Component
    # only, because that is the firmware topology we are staging here.
    old_tail = '''\treturn err;\n}\n\n#else\nvoid iort_iommu_get_resv_regions(struct device *dev, struct list_head *head)\n{ }\nint iort_iommu_configure_id(struct device *dev, const u32 *input_id)\n{ return -ENODEV; }\n#endif\n'''
    new_tail = '''\treturn err;\n}\n\n/*\n * A14_IORT_NCOMP_MULTI_ID_INIT_ONCE_V1\n *\n * Map an explicit set of Named Component input IDs into one IOMMU fwspec,\n * then attach the Named Component software properties once.  This avoids\n * repeatedly creating the same managed software_node when a firmware Named\n * Component exposes multiple StreamIDs.\n *\n * This helper is intentionally not exported to modules.\n */\nint iort_iommu_configure_ids(struct device *dev, const u32 *ids, size_t num_ids)\n{\n\tstruct acpi_iort_node *node;\n\tsize_t i;\n\tint err;\n\n\tif (!ids || !num_ids || dev_is_pci(dev))\n\t\treturn -EINVAL;\n\n\tnode = iort_scan_node(ACPI_IORT_NODE_NAMED_COMPONENT,\n\t\t\t      iort_match_node_callback, dev);\n\tif (!node)\n\t\treturn -ENODEV;\n\n\tfor (i = 0; i < num_ids; i++) {\n\t\terr = iort_nc_iommu_map_id(dev, node, &ids[i]);\n\t\tif (err)\n\t\t\treturn err;\n\t}\n\n\tiort_named_component_init(dev, node);\n\treturn 0;\n}\n\n#else\nvoid iort_iommu_get_resv_regions(struct device *dev, struct list_head *head)\n{ }\nint iort_iommu_configure_id(struct device *dev, const u32 *input_id)\n{ return -ENODEV; }\nint iort_iommu_configure_ids(struct device *dev, const u32 *ids, size_t num_ids)\n{ return -ENODEV; }\n#endif\n'''
    replace_once(iort, old_tail, new_tail, "iort_multi_id_implementation")

    # Replace the V3 repeated single-ID loop, keeping the same mutex and the
    # same all-IDs-before-arch_setup_dma_ops ordering.
    replace_once(
        scan,
        '''\tint ret = 0;\n\tsize_t i;\n\n\tif (!input_ids || !num_ids)\n''',
        '''\tint ret;\n\n\tif (!input_ids || !num_ids)\n''',
        "acpi_helper_drop_loop_index",
    )
    replace_once(
        scan,
        '''\tfor (i = 0; i < num_ids; i++) {\n\t\tret = iort_iommu_configure_id(dev, &input_ids[i]);\n\t\tif (ret)\n\t\t\tbreak;\n\t}\n\n''',
        '''\tret = iort_iommu_configure_ids(dev, input_ids, num_ids);\n\n''',
        "acpi_helper_map_ids_once",
    )

    verify(root)
    print("A14_IORT_NCOMP_MULTI_ID_INIT_ONCE_V1=APPLIED")
    print("named_component_scan_count=1_per_device")
    print("named_component_software_node_init=once_after_all_ids")
    print("gpu_iort_inputs=0x03030000,0x03030020")
    print("gmu_iort_input=0x03030060")
    print("all_ids_before_dma_ops=preserved")
    print("msm_abi_change=none")
    print("gpu_mmio_access=none")
    print("gpu_power_change=none")


if __name__ == "__main__":
    main()
