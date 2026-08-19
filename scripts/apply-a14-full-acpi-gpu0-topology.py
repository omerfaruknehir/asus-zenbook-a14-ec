#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Stage a no-MMIO QCOM0C36 GPU/GMU topology bridge for Linux 7.1.5.

Prerequisite: the earlier QCOM0C36 ACPI enumeration fix has already made the
real \\_SB.GPU0 object a platform device.  This layer does NOT bind Adreno or
GPUCC and does NOT touch graphics registers.  It only reconstructs the Linux
GPU/GMU/GPUCC child topology from firmware resources and configures the exact
IORT input IDs published by firmware.

Firmware IORT mappings used here (\\_SB.GPU0 Named Component):
  GPU input 0x03030000 -> SMMU StreamID 0
  GPU input 0x03030020 -> SMMU StreamID 1
  GMU input 0x03030060 -> SMMU StreamID 5

The bridge child devices intentionally have no own ACPI fwnode.  Their parent
is QCOM0C36:00.  Linux IORT matching walks parent devices until it finds the
ACPI companion, so explicit IORT input-ID configuration still resolves the
real \\_SB.GPU0 Named Component while platform-bus DMA setup cannot
accidentally apply all 22 GPU0 mappings to each child.
"""

from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"
MARKER = "A14_QCOM0C36_TOPOLOGY_V1"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 GPU topology transform: {msg}")


def kernel_version(root: Path) -> str:
    vals = {}
    for line in (root / "Makefile").read_text().splitlines():
        for key in ("VERSION", "PATCHLEVEL", "SUBLEVEL"):
            if line.startswith(key + " ="):
                vals[key] = line.split("=", 1)[1].strip()
    return ".".join(vals.get(k, "?") for k in ("VERSION", "PATCHLEVEL", "SUBLEVEL"))


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
        fail("usage: apply-a14-full-acpi-gpu0-topology.py /path/to/linux-7.1.5")
    root = Path(sys.argv[1]).resolve()
    if kernel_version(root) != KERNEL_VERSION:
        fail(f"targets exactly {KERNEL_VERSION}; found {kernel_version(root)}")

    scan = root / "drivers/acpi/arm64/iort.c"
    msm = root / "drivers/gpu/drm/msm/msm_drv.c"
    acpi_scan = root / "drivers/acpi/scan.c"
    for path in (scan, msm, acpi_scan):
        if not path.is_file():
            fail(f"missing {path}")

    # iort_iommu_configure_id() is already declared in the public IORT header.
    # Export the existing implementation so the GPL MSM module can append the
    # GPU's second explicit firmware mapping after acpi_dma_configure_id() has
    # configured the first one and installed the DMA ops.
    replace_once(
        scan,
        '''int iort_iommu_configure_id(struct device *dev, const u32 *id_in)\n{\n''',
        '''/* A14_QCOM0C36_TOPOLOGY_V1: exported for explicit ACPI child IDs. */\nint iort_iommu_configure_id(struct device *dev, const u32 *id_in)\n{\n''',
        "iort_export_marker",
    )
    replace_once(
        scan,
        '''\treturn err;\n}\n\n#else\nvoid iort_iommu_get_resv_regions''',
        '''\treturn err;\n}\nEXPORT_SYMBOL_GPL(iort_iommu_configure_id);\n\n#else\nvoid iort_iommu_get_resv_regions''',
        "iort_export_symbol",
    )

    # MSM bridge needs ACPI/IORT interfaces and explicit platform children.
    replace_once(
        msm,
        '''#include <linux/dma-mapping.h>\n''',
        '''#include <linux/acpi.h>\n#include <linux/acpi_iort.h>\n#include <linux/dma-mapping.h>\n#include <linux/platform_device.h>\n#include <acpi/acpi_bus.h>\n''',
        "msm_acpi_headers",
    )

    bridge = r'''
#ifdef CONFIG_ACPI
/*
 * A14_QCOM0C36_TOPOLOGY_V1
 *
 * Qualcomm WoA firmware describes display, Adreno, GMU and video as one ACPI
 * device (QCOM0C36).  Linux's native X1-85 driver models GPU, GMU and GPUCC as
 * separate devices.  Recreate only that topology here.  These child names are
 * deliberately NOT "adreno" or "gpucc-x1e80100", so no hardware driver can
 * bind in this staging layer and no graphics MMIO is performed.
 */
struct a14_gpu0_topology {
	struct platform_device *gpu;
	struct platform_device *gmu;
	struct platform_device *gpucc;
};

#define A14_GPU0_GFX_BASE	0x03d00000ULL
#define A14_GPU0_GFX_END	0x03d9efffULL
#define A14_GPU0_PDC_BASE	0x0b280000ULL
#define A14_GPU0_PDC_END	0x0b28ffffULL

static void a14_gpu0_unregister_child(struct platform_device **child)
{
	if (*child) {
		platform_device_unregister(*child);
		*child = NULL;
	}
}

static struct platform_device *
a14_gpu0_add_child(struct platform_device *parent, const char *name,
			   const struct resource *resources, unsigned int count)
{
	struct platform_device *child;
	int ret;

	child = platform_device_alloc(name, PLATFORM_DEVID_NONE);
	if (!child)
		return ERR_PTR(-ENOMEM);

	child->dev.parent = &parent->dev;
	child->dev.coherent_dma_mask = DMA_BIT_MASK(64);
	child->dev.dma_mask = &child->dev.coherent_dma_mask;

	ret = platform_device_add_resources(child, resources, count);
	if (ret)
		goto err_put;

	ret = platform_device_add(child);
	if (ret)
		goto err_put;

	return child;

err_put:
	platform_device_put(child);
	return ERR_PTR(ret);
}

static int a14_gpu0_configure_gpu_dma(struct platform_device *parent,
				       struct platform_device *gpu)
{
	struct acpi_device *adev = ACPI_COMPANION(&parent->dev);
	enum dev_dma_attr attr;
	u32 input0 = 0x03030000;
	u32 input1 = 0x03030020;
	int ret;

	if (!adev)
		return -ENODEV;

	attr = acpi_get_dma_attr(adev);
	ret = acpi_dma_configure_id(&gpu->dev, attr, &input0);
	if (ret)
		return ret;

	/* Append the second GPU firmware input mapping to the same fwspec. */
	ret = iort_iommu_configure_id(&gpu->dev, &input1);
	if (ret)
		return ret;

	dev_info(&parent->dev,
		 "A14GPU-TOPOLOGY: GPU child IORT inputs 0x%08x,0x%08x configured\n",
		 input0, input1);
	return 0;
}

static int a14_gpu0_configure_gmu_dma(struct platform_device *parent,
				       struct platform_device *gmu)
{
	struct acpi_device *adev = ACPI_COMPANION(&parent->dev);
	enum dev_dma_attr attr;
	u32 input = 0x03030060;
	int ret;

	if (!adev)
		return -ENODEV;

	attr = acpi_get_dma_attr(adev);
	ret = acpi_dma_configure_id(&gmu->dev, attr, &input);
	if (ret)
		return ret;

	dev_info(&parent->dev,
		 "A14GPU-TOPOLOGY: GMU child IORT input 0x%08x configured\n",
		 input);
	return 0;
}

static int a14_gpu0_topology_probe(struct platform_device *pdev)
{
	struct a14_gpu0_topology *topo;
	struct resource *gfx, *pdc;
	int gfx_irq, hfi_irq;
	int ret;
	struct resource gpu_res[4] = {
		DEFINE_RES_MEM_NAMED(0x03d00000, 0x00040000, "kgsl_3d0_reg_memory"),
		DEFINE_RES_MEM_NAMED(0x03d9e000, 0x00001000, "cx_mem"),
		DEFINE_RES_MEM_NAMED(0x03d61000, 0x00000800, "cx_dbgc"),
		{ .name = "kgsl_3d0_irq", .flags = IORESOURCE_IRQ },
	};
	struct resource gmu_res[4] = {
		DEFINE_RES_MEM_NAMED(0x03d6a000, 0x00035000, "gmu"),
		DEFINE_RES_MEM_NAMED(0x03d50000, 0x00010000, "rscc"),
		DEFINE_RES_MEM_NAMED(0x0b280000, 0x00010000, "gmu_pdc"),
		{ .name = "hfi", .flags = IORESOURCE_IRQ },
	};
	struct resource gpucc_res =
		DEFINE_RES_MEM_NAMED(0x03d90000, 0x0000a000, "gpucc");

	/* Validate the firmware resource container before deriving subranges. */
	gfx = platform_get_resource(pdev, IORESOURCE_MEM, 2);
	pdc = platform_get_resource(pdev, IORESOURCE_MEM, 3);
	if (!gfx || gfx->start != A14_GPU0_GFX_BASE || gfx->end < A14_GPU0_GFX_END) {
		dev_err(&pdev->dev, "A14GPU-TOPOLOGY: unexpected GFX_REGS parent aperture\n");
		return -EINVAL;
	}
	if (!pdc || pdc->start != A14_GPU0_PDC_BASE || pdc->end < A14_GPU0_PDC_END) {
		dev_err(&pdev->dev, "A14GPU-TOPOLOGY: unexpected GPU_PDC_REGS parent aperture\n");
		return -EINVAL;
	}

	/* Seven display IRQ resources precede GFX in GPU0._CRS. */
	gfx_irq = platform_get_irq(pdev, 7);
	hfi_irq = platform_get_irq(pdev, 8);
	if (gfx_irq < 0)
		return gfx_irq;
	if (hfi_irq < 0)
		return hfi_irq;

	gpu_res[3].start = gpu_res[3].end = gfx_irq;
	gmu_res[3].start = gmu_res[3].end = hfi_irq;

	topo = devm_kzalloc(&pdev->dev, sizeof(*topo), GFP_KERNEL);
	if (!topo)
		return -ENOMEM;
	platform_set_drvdata(pdev, topo);

	topo->gpu = a14_gpu0_add_child(pdev, "a14-adreno-x185-acpi-topology",
				       gpu_res, ARRAY_SIZE(gpu_res));
	if (IS_ERR(topo->gpu)) {
		ret = PTR_ERR(topo->gpu);
		topo->gpu = NULL;
		return ret;
	}

	ret = a14_gpu0_configure_gpu_dma(pdev, topo->gpu);
	if (ret)
		goto err_gpu;

	topo->gmu = a14_gpu0_add_child(pdev, "a14-gmu-x185-acpi-topology",
				       gmu_res, ARRAY_SIZE(gmu_res));
	if (IS_ERR(topo->gmu)) {
		ret = PTR_ERR(topo->gmu);
		topo->gmu = NULL;
		goto err_gpu;
	}

	ret = a14_gpu0_configure_gmu_dma(pdev, topo->gmu);
	if (ret)
		goto err_gmu;

	topo->gpucc = a14_gpu0_add_child(pdev, "a14-gpucc-x1e80100-acpi-topology",
					 &gpucc_res, 1);
	if (IS_ERR(topo->gpucc)) {
		ret = PTR_ERR(topo->gpucc);
		topo->gpucc = NULL;
		goto err_gmu;
	}

	dev_info(&pdev->dev,
		 "A14GPU-TOPOLOGY: READY gpu_irq=%d hfi_irq=%d gmu_watchdog_irq=firmware-unexposed no_mmio=true\n",
		 gfx_irq, hfi_irq);
	return 0;

err_gmu:
	a14_gpu0_unregister_child(&topo->gmu);
err_gpu:
	a14_gpu0_unregister_child(&topo->gpu);
	return ret;
}

static void a14_gpu0_topology_remove(struct platform_device *pdev)
{
	struct a14_gpu0_topology *topo = platform_get_drvdata(pdev);

	if (!topo)
		return;
	a14_gpu0_unregister_child(&topo->gpucc);
	a14_gpu0_unregister_child(&topo->gmu);
	a14_gpu0_unregister_child(&topo->gpu);
}

static const struct acpi_device_id a14_gpu0_topology_acpi_match[] = {
	{ "QCOM0C36", 0 },
	{ }
};
MODULE_DEVICE_TABLE(acpi, a14_gpu0_topology_acpi_match);

static struct platform_driver a14_gpu0_topology_driver = {
	.probe = a14_gpu0_topology_probe,
	.remove = a14_gpu0_topology_remove,
	.driver = {
		.name = "a14-qcom0c36-topology",
		.acpi_match_table = ACPI_PTR(a14_gpu0_topology_acpi_match),
	},
};
#endif /* CONFIG_ACPI */

'''

    replace_once(
        msm,
        '''static int __init msm_drm_register(void)\n{\n''',
        bridge + '''static int __init msm_drm_register(void)\n{\n''',
        "msm_gpu0_topology_bridge",
    )

    replace_once(
        msm,
        '''\tDBG("init");\n\tmsm_mdp_register();\n''',
        '''\tDBG("init");\n#ifdef CONFIG_ACPI\n\t{\n\t\tint ret = platform_driver_register(&a14_gpu0_topology_driver);\n\n\t\tif (ret)\n\t\t\treturn ret;\n\t}\n#endif\n\tmsm_mdp_register();\n''',
        "msm_gpu0_topology_register",
    )

    replace_once(
        msm,
        '''\tmsm_dpu_unregister();\n}\n\nmodule_init(msm_drm_register);\n''',
        '''\tmsm_dpu_unregister();\n#ifdef CONFIG_ACPI\n\tplatform_driver_unregister(&a14_gpu0_topology_driver);\n#endif\n}\n\nmodule_init(msm_drm_register);\n''',
        "msm_gpu0_topology_unregister",
    )

    # The enumeration prerequisite must remain in scan.c.
    scan_main = root / "drivers/acpi/scan.c"
    if "A14_QCOM0C36_PLATFORM_ENUM_V1" not in scan_main.read_text():
        fail("working QCOM0C36 platform-enumeration prerequisite missing")

    iort_body = scan.read_text()
    msm_body = msm.read_text()
    required_iort = [
        MARKER,
        "EXPORT_SYMBOL_GPL(iort_iommu_configure_id);",
    ]
    required_msm = [
        MARKER,
        '"QCOM0C36", 0',
        "0x03030000",
        "0x03030020",
        "0x03030060",
        "a14-adreno-x185-acpi-topology",
        "a14-gmu-x185-acpi-topology",
        "a14-gpucc-x1e80100-acpi-topology",
        "gmu_watchdog_irq=firmware-unexposed",
        "no_mmio=true",
    ]
    missing = [x for x in required_iort if x not in iort_body]
    missing += [x for x in required_msm if x not in msm_body]
    if missing:
        fail(f"post-transform verification missing: {missing}")

    print(f"{MARKER}=APPLIED")
    print("parent_acpi_hid=QCOM0C36")
    print("gpu_iort_inputs=0x03030000,0x03030020")
    print("gmu_iort_input=0x03030060")
    print("gpu_streamids=0,1_firmware_derived")
    print("gmu_streamid=5_firmware_derived")
    print("gmu_watchdog_irq=not_in_acpi_crs")
    print("hardware_driver_binding=disabled_this_layer")
    print("gpu_mmio_access=none")
    print("gpu_power_change=none")


if __name__ == "__main__":
    main()
