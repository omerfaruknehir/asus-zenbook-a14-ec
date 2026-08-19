#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Add the UX3407RA/X1E80100 ACPI SCM binding to Linux 7.1.5.

Firmware exposes the secure-channel manager as:

    \\_SB.SCM0  _HID QCOM04DD

Upstream qcom_scm is OF-only: it has no ACPI match table and its probe performs
several DT-only operations.  On the A14 ACPI-only boot that first meant no SCM
binding at all; after adding the HID, the first unguarded OF reset-controller
registration dereferenced a NULL of_node in reset_controller_register().

This transform is intentionally narrow:
  * bind ACPI HID QCOM04DD to qcom_scm;
  * skip DT-only dload-mode, ICC, reserved-memory and reset-controller provider
    setup when the SCM platform device has no OF node;
  * skip the OF parent-IRQ discovery for the SCM waitqueue under ACPI, while
    still allowing a real ACPI/platform IRQ resource via platform_get_irq_optional();
  * guard the DT-only qcom,sdi-enabled property lookup;
  * preserve the existing OF/DT behavior for normal DT boots.

No SMC IDs, SMC calling convention, SMMU code, GPU code, GIO0 code, or ACPI
namespace are changed here.
"""

from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"
MARKER = "A14_QCOM_SCM_ACPI_QCOM04DD"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 SCM ACPI transform: {msg}")


def version(root: Path) -> str:
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
        fail("usage: apply-a14-full-acpi-scm-acpi.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file():
        fail(f"not a kernel source tree: {root}")
    found = version(root)
    if found != KERNEL_VERSION:
        fail(f"targets exactly {KERNEL_VERSION}; found {found}")

    scm = root / "drivers/firmware/qcom/qcom_scm.c"
    if not scm.is_file():
        fail(f"missing source file: {scm}")

    replace_once(
        scm,
        '#include <linux/arm-smccc.h>\n',
        '#include <linux/acpi.h>\n#include <linux/arm-smccc.h>\n',
        "acpi_header",
    )

    # No DT qcom,dload-mode phandle exists for ACPI SCM0.
    replace_once(
        scm,
        '''\tstruct resource res;\n\tu32 offset;\n\tint ret;\n\n\ttcsr = of_parse_phandle(np, "qcom,dload-mode", 0);\n''',
        '''\tstruct resource res;\n\tu32 offset;\n\tint ret;\n\n\t/* A14_QCOM_SCM_ACPI_QCOM04DD: no DT dload-mode phandle on ACPI SCM0. */\n\tif (!np) {\n\t\t*addr = 0;\n\t\treturn 0;\n\t}\n\n\ttcsr = of_parse_phandle(np, "qcom,dload-mode", 0);\n''',
        "acpi_dload_bypass",
    )

    # No DT interconnect property exists for ACPI SCM0. qcom_scm_bw_enable()
    # already treats scm->path == NULL as a valid no-vote configuration.
    old_icc = '''\tmutex_init(&scm->scm_bw_lock);\n\n\tscm->path = devm_of_icc_get(&pdev->dev, NULL);\n\tif (IS_ERR(scm->path))\n\t\treturn dev_err_probe(&pdev->dev, PTR_ERR(scm->path),\n\t\t\t\t     "failed to acquire interconnect path\\n");\n'''
    new_icc = '''\tmutex_init(&scm->scm_bw_lock);\n\n\t/* A14_QCOM_SCM_ACPI_QCOM04DD */\n\tif (pdev->dev.of_node) {\n\t\tscm->path = devm_of_icc_get(&pdev->dev, NULL);\n\t\tif (IS_ERR(scm->path))\n\t\t\treturn dev_err_probe(&pdev->dev, PTR_ERR(scm->path),\n\t\t\t\t\t     "failed to acquire interconnect path\\n");\n\t} else {\n\t\tscm->path = NULL;\n\t\tdev_info(&pdev->dev,\n\t\t\t "A14 ACPI: SCM0 QCOM04DD, DT-only resources skipped\\n");\n\t}\n'''
    replace_once(scm, old_icc, new_icc, "acpi_icc_bypass")

    # The reset controller exported by qcom_scm is described through DT.
    # Registering it with reset.of_node == NULL crashes reset core on this
    # 7.1.5 ACPI-only boot. ACPI SCM consumers use the exported qcom_scm APIs,
    # not this OF reset-provider facade, so keep it DT-only.
    replace_once(
        scm,
        '''\tscm->reset.ops = &qcom_scm_pas_reset_ops;\n\tscm->reset.nr_resets = 1;\n\tscm->reset.of_node = pdev->dev.of_node;\n\tret = devm_reset_controller_register(&pdev->dev, &scm->reset);\n\tif (ret)\n\t\treturn ret;\n''',
        '''\tif (pdev->dev.of_node) {\n\t\tscm->reset.ops = &qcom_scm_pas_reset_ops;\n\t\tscm->reset.nr_resets = 1;\n\t\tscm->reset.of_node = pdev->dev.of_node;\n\t\tret = devm_reset_controller_register(&pdev->dev, &scm->reset);\n\t\tif (ret)\n\t\t\treturn ret;\n\t} else {\n\t\tdev_info(&pdev->dev,\n\t\t\t "A14 ACPI: SCM OF reset-controller provider skipped\\n");\n\t}\n''',
        "acpi_reset_provider_bypass",
    )

    # of_reserved_mem_device_init() returns -EINVAL for dev->of_node == NULL
    # in 7.1.5, and qcom_scm treats that as a fatal probe failure.
    replace_once(
        scm,
        '''\tret = of_reserved_mem_device_init(scm->dev);\n\tif (ret && ret != -ENODEV)\n\t\treturn dev_err_probe(scm->dev, ret,\n\t\t\t\t     "Failed to setup the reserved memory region for TZ mem\\n");\n''',
        '''\tif (pdev->dev.of_node) {\n\t\tret = of_reserved_mem_device_init(scm->dev);\n\t\tif (ret && ret != -ENODEV)\n\t\t\treturn dev_err_probe(scm->dev, ret,\n\t\t\t\t\t     "Failed to setup the reserved memory region for TZ mem\\n");\n\t}\n''',
        "acpi_reserved_mem_bypass",
    )

    # qcom_scm_get_waitq_irq() constructs the interrupt fwspec through
    # of_irq_find_parent(scm->dev->of_node). Do not call that OF helper for an
    # ACPI SCM device. Still fall back to platform_get_irq_optional(), which is
    # the correct firmware-neutral way to consume a platform IRQ resource if
    # firmware supplies one.
    replace_once(
        scm,
        '''\tirq = qcom_scm_get_waitq_irq(scm);\n\tif (irq < 0)\n\t\tirq = platform_get_irq_optional(pdev, 0);\n''',
        '''\tif (scm->dev->of_node)\n\t\tirq = qcom_scm_get_waitq_irq(scm);\n\telse\n\t\tirq = -ENODEV;\n\n\tif (irq < 0)\n\t\tirq = platform_get_irq_optional(pdev, 0);\n''',
        "acpi_waitq_irq_bypass",
    )

    # The qcom,sdi-enabled knob is a DT property. The !download_mode branch is
    # unchanged, so normal default SDI handling is preserved under ACPI too.
    replace_once(
        scm,
        '''\tif (of_property_read_bool(pdev->dev.of_node, "qcom,sdi-enabled") || !download_mode)\n\t\tqcom_scm_disable_sdi();\n''',
        '''\tif ((pdev->dev.of_node &&\n\t     of_property_read_bool(pdev->dev.of_node, "qcom,sdi-enabled")) ||\n\t    !download_mode)\n\t\tqcom_scm_disable_sdi();\n''',
        "acpi_sdi_property_guard",
    )

    # Bind the actual firmware HID.
    old_table = '''MODULE_DEVICE_TABLE(of, qcom_scm_dt_match);\n\nstatic struct platform_driver qcom_scm_driver = {\n\t.driver = {\n\t\t.name\t= "qcom_scm",\n\t\t.of_match_table = qcom_scm_dt_match,\n\t\t.suppress_bind_attrs = true,\n\t},\n'''
    new_table = '''MODULE_DEVICE_TABLE(of, qcom_scm_dt_match);\n\n#ifdef CONFIG_ACPI\nstatic const struct acpi_device_id qcom_scm_acpi_match[] = {\n\t{ "QCOM04DD", 0 }, /* UX3407RA / Qualcomm WoA SCM0 */\n\t{ }\n};\nMODULE_DEVICE_TABLE(acpi, qcom_scm_acpi_match);\n#endif\n\nstatic struct platform_driver qcom_scm_driver = {\n\t.driver = {\n\t\t.name\t= "qcom_scm",\n\t\t.of_match_table = qcom_scm_dt_match,\n\t\t.acpi_match_table = ACPI_PTR(qcom_scm_acpi_match),\n\t\t.suppress_bind_attrs = true,\n\t},\n'''
    replace_once(scm, old_table, new_table, "qcom04dd_acpi_match")

    body = scm.read_text()
    required = [
        MARKER,
        '"QCOM04DD", 0',
        'MODULE_DEVICE_TABLE(acpi, qcom_scm_acpi_match)',
        '.acpi_match_table = ACPI_PTR(qcom_scm_acpi_match)',
        'A14 ACPI: SCM0 QCOM04DD, DT-only resources skipped',
        'A14 ACPI: SCM OF reset-controller provider skipped',
        'if (!np)',
        '*addr = 0;',
        'if (pdev->dev.of_node)',
        'if (scm->dev->of_node)',
        'scm->path = NULL;',
        'irq = -ENODEV;',
    ]
    missing = [x for x in required if x not in body]
    if missing:
        fail(f"post-transform verification missing: {missing}")

    # Original OF operations must still exist exactly once, gated rather than
    # deleted, to preserve the DT boot path.
    for token, expected in (
        ('devm_of_icc_get(&pdev->dev, NULL)', 1),
        ('devm_reset_controller_register(&pdev->dev, &scm->reset)', 1),
        ('of_reserved_mem_device_init(scm->dev)', 1),
        ('qcom_scm_get_waitq_irq(scm)', 1),
        ('of_parse_phandle(np, "qcom,dload-mode", 0)', 1),
        ('of_property_read_bool(pdev->dev.of_node, "qcom,sdi-enabled")', 1),
    ):
        if body.count(token) != expected:
            fail(f"unexpected count for {token}: {body.count(token)}")

    print(f"{MARKER}=APPLIED")
    print("acpi_hid=QCOM04DD")
    print("acpi_dload_mode=none")
    print("acpi_interconnect=none")
    print("acpi_reset_provider=skipped")
    print("acpi_reserved_memory=none")
    print("acpi_waitq_irq=platform_resource_only")
    print("acpi_sdi_property=guarded")
    print("of_behavior=preserved")
    print("smc_calling_convention=unchanged")
    print("smmu_code=unchanged")
    print("gpu_code=unchanged")


if __name__ == "__main__":
    main()
