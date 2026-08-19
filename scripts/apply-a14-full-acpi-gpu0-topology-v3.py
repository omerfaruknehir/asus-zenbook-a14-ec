#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Finalize QCOM0C36 topology with pre-DMA multi-ID IORT configuration.

V2 staged the topology but configured the GPU's first IORT ID through
acpi_dma_configure_id(), which can activate DMA/IOMMU state before the second
GPU ID is appended.  V3 adds a narrow strict ACPI helper that maps all explicit
IORT input IDs first and only then calls arch_setup_dma_ops().

The temporary GPL export of iort_iommu_configure_id() is removed again; DRM
uses only the new ACPI helper.
"""

from pathlib import Path
import subprocess
import sys

V3 = "A14_ACPI_DMA_IORT_IDS_V1"
TOPO = "A14_QCOM0C36_TOPOLOGY_V1"
SAFE = "adev->flags.coherent_dma ? DEV_DMA_COHERENT"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 GPU topology V3 transform: {msg}")


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


def verify(root: Path) -> None:
    scan = (root / "drivers/acpi/scan.c").read_text()
    hdr = (root / "include/acpi/acpi_bus.h").read_text()
    iort = (root / "drivers/acpi/arm64/iort.c").read_text()
    msm = (root / "drivers/gpu/drm/msm/msm_drv.c").read_text()

    if V3 not in scan:
        fail("strict multi-ID ACPI helper marker missing")
    if "acpi_dma_configure_iort_ids" not in hdr:
        fail("strict multi-ID ACPI helper declaration missing")
    if "EXPORT_SYMBOL_GPL(acpi_dma_configure_iort_ids);" not in scan:
        fail("strict multi-ID ACPI helper export missing")
    if "EXPORT_SYMBOL_GPL(iort_iommu_configure_id);" in iort:
        fail("temporary direct IORT export still present")
    if TOPO not in msm or SAFE not in msm:
        fail("module-safe QCOM0C36 topology bridge missing")
    if msm.count("acpi_dma_configure_iort_ids(") != 2:
        fail("expected strict IORT helper for GPU and GMU")
    if "iort_iommu_configure_id(&gpu->dev" in msm:
        fail("late second-GPU-IORT append remains")
    for token in ("0x03030000", "0x03030020", "0x03030060",
                  "a14-adreno-x185-acpi-topology",
                  "a14-gmu-x185-acpi-topology",
                  "a14-gpucc-x1e80100-acpi-topology",
                  "no_mmio=true"):
        if token not in msm:
            fail(f"topology verification missing {token}")


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: apply-a14-full-acpi-gpu0-topology-v3.py /path/to/linux-7.1.5")
    root = Path(sys.argv[1]).resolve()
    scan = root / "drivers/acpi/scan.c"
    hdr = root / "include/acpi/acpi_bus.h"
    iort = root / "drivers/acpi/arm64/iort.c"
    msm = root / "drivers/gpu/drm/msm/msm_drv.c"
    for path in (scan, hdr, iort, msm):
        if not path.is_file():
            fail(f"missing {path}")

    # Fully-applied V3 state: never feed its modified bridge back through the
    # older exact-block transforms.
    if V3 in scan.read_text() and "acpi_dma_configure_iort_ids" in msm.read_text():
        verify(root)
        print("topology_v3=current")
        print("A14_QCOM0C36_TOPOLOGY_V3=APPLIED")
        print("gpu_iort_order=all_ids_before_dma_ops")
        print("direct_iort_export=false")
        print("gpu_mmio_access=none")
        return

    v2 = Path(__file__).with_name("apply-a14-full-acpi-gpu0-topology-v2.py")
    if not v2.is_file():
        fail(f"missing V2 transform: {v2}")
    subprocess.run([sys.executable, str(v2), str(root)], check=True)

    # Remove V1's temporary module export: V3 keeps the lower IORT mapper
    # internal and exports only the strict ACPI DMA wrapper.
    replace_once(
        iort,
        '''/* A14_QCOM0C36_TOPOLOGY_V1: exported for explicit ACPI child IDs. */\nint iort_iommu_configure_id(struct device *dev, const u32 *id_in)\n''',
        '''int iort_iommu_configure_id(struct device *dev, const u32 *id_in)\n''',
        "remove_iort_export_marker",
    )
    replace_once(
        iort,
        '''}\nEXPORT_SYMBOL_GPL(iort_iommu_configure_id);\n\n#else\nvoid iort_iommu_get_resv_regions''',
        '''}\n\n#else\nvoid iort_iommu_get_resv_regions''',
        "remove_iort_export_symbol",
    )

    # Public GPL helper declaration next to the existing single-ID API.
    replace_once(
        hdr,
        '''int acpi_dma_configure_id(struct device *dev, enum dev_dma_attr attr,\n\t\t\t   const u32 *input_id);\nstatic inline int acpi_dma_configure(struct device *dev,\n''',
        '''int acpi_dma_configure_id(struct device *dev, enum dev_dma_attr attr,\n\t\t\t   const u32 *input_id);\nint acpi_dma_configure_iort_ids(struct device *dev, enum dev_dma_attr attr,\n\t\t\t\tconst u32 *input_ids, size_t num_ids);\nstatic inline int acpi_dma_configure(struct device *dev,\n''',
        "acpi_iort_ids_declaration",
    )

    # Add strict multi-ID helper after the existing single-ID exported API.
    helper = r'''

/*
 * A14_ACPI_DMA_IORT_IDS_V1
 * Configure all explicit IORT input IDs before DMA ops are activated.  This is
 * intentionally strict and IORT-specific; unlike the generic single-ID path,
 * a missing requested mapping is returned to the caller.
 */
int acpi_dma_configure_iort_ids(struct device *dev, enum dev_dma_attr attr,
				const u32 *input_ids, size_t num_ids)
{
	int ret = 0;
	size_t i;

	if (!input_ids || !num_ids)
		return -EINVAL;

	if (attr == DEV_DMA_NOT_SUPPORTED) {
		set_dma_ops(dev, &dma_dummy_ops);
		return 0;
	}

	acpi_arch_dma_setup(dev);

	mutex_lock(&iommu_probe_device_lock);
	if (dev_iommu_fwspec_get(dev)) {
		ret = -EBUSY;
		goto out_unlock;
	}

	for (i = 0; i < num_ids; i++) {
		ret = iort_iommu_configure_id(dev, &input_ids[i]);
		if (ret)
			break;
	}

out_unlock:
	mutex_unlock(&iommu_probe_device_lock);
	if (ret)
		return ret;

	arch_setup_dma_ops(dev, attr == DEV_DMA_COHERENT);
	return 0;
}
EXPORT_SYMBOL_GPL(acpi_dma_configure_iort_ids);
'''

    replace_once(
        scan,
        '''}\nEXPORT_SYMBOL_GPL(acpi_dma_configure_id);\n\nstatic void acpi_init_coherency''',
        '''}\nEXPORT_SYMBOL_GPL(acpi_dma_configure_id);''' + helper + '''\n\nstatic void acpi_init_coherency''',
        "acpi_iort_ids_implementation",
    )

    # GPU: configure both firmware input IDs in one pre-DMA transaction.
    old_gpu = '''\tu32 input0 = 0x03030000;\n\tu32 input1 = 0x03030020;\n\tint ret;\n\n\tif (!adev)\n\t\treturn -ENODEV;\n\n\tattr = adev->flags.coherent_dma ? DEV_DMA_COHERENT :\n\t\t\t\t\t      DEV_DMA_NON_COHERENT;\n\tret = acpi_dma_configure_id(&gpu->dev, attr, &input0);\n\tif (ret)\n\t\treturn ret;\n\n\t/* Append the second GPU firmware input mapping to the same fwspec. */\n\tret = iort_iommu_configure_id(&gpu->dev, &input1);\n\tif (ret)\n\t\treturn ret;\n\n\tdev_info(&parent->dev,\n\t\t "A14GPU-TOPOLOGY: GPU child IORT inputs 0x%08x,0x%08x configured\\n",\n\t\t input0, input1);\n\treturn 0;\n'''
    new_gpu = '''\tconst u32 inputs[] = { 0x03030000, 0x03030020 };\n\tint ret;\n\n\tif (!adev)\n\t\treturn -ENODEV;\n\n\tattr = adev->flags.coherent_dma ? DEV_DMA_COHERENT :\n\t\t\t\t\t      DEV_DMA_NON_COHERENT;\n\tret = acpi_dma_configure_iort_ids(&gpu->dev, attr, inputs, ARRAY_SIZE(inputs));\n\tif (ret)\n\t\treturn ret;\n\n\tdev_info(&parent->dev,\n\t\t "A14GPU-TOPOLOGY: GPU child IORT inputs 0x%08x,0x%08x configured before DMA ops\\n",\n\t\t inputs[0], inputs[1]);\n\treturn 0;\n'''
    replace_once(msm, old_gpu, new_gpu, "gpu_pre_dma_iort_ids")

    old_gmu = '''\tu32 input = 0x03030060;\n\tint ret;\n\n\tif (!adev)\n\t\treturn -ENODEV;\n\n\tattr = adev->flags.coherent_dma ? DEV_DMA_COHERENT :\n\t\t\t\t\t      DEV_DMA_NON_COHERENT;\n\tret = acpi_dma_configure_id(&gmu->dev, attr, &input);\n\tif (ret)\n\t\treturn ret;\n\n\tdev_info(&parent->dev,\n\t\t "A14GPU-TOPOLOGY: GMU child IORT input 0x%08x configured\\n",\n\t\t input);\n\treturn 0;\n'''
    new_gmu = '''\tconst u32 inputs[] = { 0x03030060 };\n\tint ret;\n\n\tif (!adev)\n\t\treturn -ENODEV;\n\n\tattr = adev->flags.coherent_dma ? DEV_DMA_COHERENT :\n\t\t\t\t\t      DEV_DMA_NON_COHERENT;\n\tret = acpi_dma_configure_iort_ids(&gmu->dev, attr, inputs, ARRAY_SIZE(inputs));\n\tif (ret)\n\t\treturn ret;\n\n\tdev_info(&parent->dev,\n\t\t "A14GPU-TOPOLOGY: GMU child IORT input 0x%08x configured before DMA ops\\n",\n\t\t inputs[0]);\n\treturn 0;\n'''
    replace_once(msm, old_gmu, new_gmu, "gmu_pre_dma_iort_ids")

    verify(root)
    print("A14_QCOM0C36_TOPOLOGY_V3=APPLIED")
    print("gpu_iort_order=all_ids_before_dma_ops")
    print("gpu_iort_inputs=0x03030000,0x03030020")
    print("gmu_iort_input=0x03030060")
    print("direct_iort_export=false")
    print("hardware_driver_binding=disabled_this_layer")
    print("gpu_mmio_access=none")


if __name__ == "__main__":
    main()
