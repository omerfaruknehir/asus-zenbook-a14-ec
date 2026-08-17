#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Add targeted checkpoints inside Linux 7.1.5 ARM SMMU init/probe."""
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

    text = smmu.read_text()
    full_inc = (
        '#include <linux/acpi.h>\n'
        '#include <linux/a14_full_acpi.h>\n'
        '#include <linux/atomic.h>\n'
        '#include <linux/kernel.h>\n'
    )
    if full_inc in text:
        print('smmu_checkpoint_include=current')
    elif '#include <linux/acpi.h>\n#include <linux/a14_full_acpi.h>\n' in text:
        smmu.write_text(text.replace(
            '#include <linux/acpi.h>\n#include <linux/a14_full_acpi.h>\n',
            full_inc,
            1,
        ))
        print('smmu_checkpoint_include=upgraded')
    else:
        replace_once(
            smmu,
            '#include <linux/acpi.h>\n',
            full_inc,
            'smmu_checkpoint_include',
        )

    old_init = '''static int __init arm_smmu_init(void)\n{\n\tint ret;\n\n\tret = platform_driver_register(&arm_smmu_driver);\n\tif (ret)\n\t\treturn ret;\n\n\tret = arm_smmu_impl_module_init();\n\tif (ret)\n\t\tplatform_driver_unregister(&arm_smmu_driver);\n\n\treturn ret;\n}\n'''
    new_init = '''static int __init arm_smmu_init(void)\n{\n\tint ret;\n\n\ta14_acpi_checkpoint("smmu-init-enter");\n\n\tret = platform_driver_register(&arm_smmu_driver);\n\tif (ret)\n\t\treturn ret;\n\n\ta14_acpi_checkpoint("smmu-driver-registered");\n\n\tret = arm_smmu_impl_module_init();\n\tif (ret)\n\t\tplatform_driver_unregister(&arm_smmu_driver);\n\n\ta14_acpi_checkpoint("smmu-impl-registered");\n\n\treturn ret;\n}\n'''
    replace_once(smmu, old_init, new_init, 'smmu_init_checkpoints')

    # Number each actual arm-smmu platform probe.  Dynamic checkpoint names stay
    # below the base helper's 40-byte early-param buffer, e.g.
    # smmu-probe2-before-reset.
    probe_helper = '''static atomic_t a14_smmu_probe_seq = ATOMIC_INIT(0);\n\nstatic void a14_smmu_probe_checkpoint(int seq, const char *point)\n{\n\tchar stage[40];\n\n\tscnprintf(stage, sizeof(stage), "smmu-probe%d-%s", seq, point);\n\ta14_acpi_checkpoint(stage);\n}\n\n'''
    replace_once(
        smmu,
        'static int arm_smmu_device_probe(struct platform_device *pdev)\n',
        probe_helper + 'static int arm_smmu_device_probe(struct platform_device *pdev)\n',
        'smmu_probe_checkpoint_helper',
    )

    replace_once(
        smmu,
        '\tirqreturn_t (*global_fault)(int irq, void *dev);\n\n'
        '\tsmmu = devm_kzalloc(dev, sizeof(*smmu), GFP_KERNEL);\n',
        '\tirqreturn_t (*global_fault)(int irq, void *dev);\n'
        '\tint a14_probe_seq = atomic_inc_return(&a14_smmu_probe_seq);\n\n'
        '\ta14_smmu_probe_checkpoint(a14_probe_seq, "enter");\n\n'
        '\tsmmu = devm_kzalloc(dev, sizeof(*smmu), GFP_KERNEL);\n',
        'smmu_probe_enter',
    )

    replace_once(
        smmu,
        '\tif (err)\n\t\treturn err;\n\n'
        '\tsmmu->base = devm_platform_get_and_ioremap_resource(pdev, 0, &res);\n',
        '\tif (err)\n\t\treturn err;\n\n'
        '\ta14_smmu_probe_checkpoint(a14_probe_seq, "after-fwdata");\n\n'
        '\tsmmu->base = devm_platform_get_and_ioremap_resource(pdev, 0, &res);\n',
        'smmu_probe_after_fwdata',
    )

    replace_once(
        smmu,
        '\tif (IS_ERR(smmu->base))\n\t\treturn PTR_ERR(smmu->base);\n'
        '\tsmmu->ioaddr = res->start;\n\n',
        '\tif (IS_ERR(smmu->base))\n\t\treturn PTR_ERR(smmu->base);\n'
        '\tsmmu->ioaddr = res->start;\n\n'
        '\ta14_smmu_probe_checkpoint(a14_probe_seq, "after-ioremap");\n\n',
        'smmu_probe_after_ioremap',
    )

    replace_once(
        smmu,
        '\tsmmu = arm_smmu_impl_init(smmu);\n'
        '\tif (IS_ERR(smmu))\n\t\treturn PTR_ERR(smmu);\n\n'
        '\tnum_irqs = platform_irq_count(pdev);\n',
        '\tsmmu = arm_smmu_impl_init(smmu);\n'
        '\tif (IS_ERR(smmu))\n\t\treturn PTR_ERR(smmu);\n\n'
        '\ta14_smmu_probe_checkpoint(a14_probe_seq, "after-impl");\n\n'
        '\tnum_irqs = platform_irq_count(pdev);\n',
        'smmu_probe_after_impl',
    )

    replace_once(
        smmu,
        '\terr = clk_bulk_prepare_enable(smmu->num_clks, smmu->clks);\n'
        '\tif (err)\n\t\treturn err;\n\n'
        '\terr = arm_smmu_device_cfg_probe(smmu);\n'
        '\tif (err)\n\t\treturn err;\n\n',
        '\terr = clk_bulk_prepare_enable(smmu->num_clks, smmu->clks);\n'
        '\tif (err)\n\t\treturn err;\n\n'
        '\ta14_smmu_probe_checkpoint(a14_probe_seq, "before-cfg");\n'
        '\terr = arm_smmu_device_cfg_probe(smmu);\n'
        '\tif (err)\n\t\treturn err;\n'
        '\ta14_smmu_probe_checkpoint(a14_probe_seq, "after-cfg");\n\n',
        'smmu_probe_cfg',
    )

    replace_once(
        smmu,
        '\tplatform_set_drvdata(pdev, smmu);\n\n'
        '\t/* Check for RMRs and install bypass SMRs if any */\n'
        '\tarm_smmu_rmr_install_bypass_smr(smmu);\n\n'
        '\tarm_smmu_device_reset(smmu);\n'
        '\tarm_smmu_test_smr_masks(smmu);\n\n',
        '\tplatform_set_drvdata(pdev, smmu);\n\n'
        '\t/* Check for RMRs and install bypass SMRs if any */\n'
        '\ta14_smmu_probe_checkpoint(a14_probe_seq, "before-rmr");\n'
        '\tarm_smmu_rmr_install_bypass_smr(smmu);\n'
        '\ta14_smmu_probe_checkpoint(a14_probe_seq, "after-rmr");\n\n'
        '\ta14_smmu_probe_checkpoint(a14_probe_seq, "before-reset");\n'
        '\tarm_smmu_device_reset(smmu);\n'
        '\ta14_smmu_probe_checkpoint(a14_probe_seq, "after-reset");\n'
        '\tarm_smmu_test_smr_masks(smmu);\n'
        '\ta14_smmu_probe_checkpoint(a14_probe_seq, "after-smr-test");\n\n',
        'smmu_probe_rmr_reset',
    )

    text = smmu.read_text()
    expected = (
        "smmu-init-enter",
        "smmu-driver-registered",
        "smmu-impl-registered",
        '"after-fwdata"',
        '"after-ioremap"',
        '"after-impl"',
        '"before-cfg"',
        '"after-cfg"',
        '"before-rmr"',
        '"after-rmr"',
        '"before-reset"',
        '"after-reset"',
        '"after-smr-test"',
    )
    missing = [stage for stage in expected if stage not in text]
    if missing:
        fail(f"verification failed: {missing}")

    print("A14_FULL_ACPI_SMMU_CHECKPOINTS=APPLIED")
    print("init_stages=smmu-init-enter,smmu-driver-registered,smmu-impl-registered")
    print("probe_stages=smmu-probeN-enter,after-fwdata,after-ioremap,after-impl,before-cfg,after-cfg,before-rmr,after-rmr,before-reset,after-reset,after-smr-test")


if __name__ == "__main__":
    main()
