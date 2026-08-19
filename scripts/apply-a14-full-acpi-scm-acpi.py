#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Add the UX3407RA/X1E80100 ACPI SCM binding to Linux 7.1.5.

The firmware exposes the secure-channel manager as:

    \\_SB.SCM0  _HID QCOM04DD

with no MMIO resources of its own. Upstream qcom_scm is OF-only: it has no
ACPI match table and its probe performs several DT-only resource lookups.
Consequently qcom_scm_is_available() never becomes true in the A14 ACPI-only
boot and the Qualcomm arm-smmu implementation remains deferred with
"qcom_scm not ready".

This transform is intentionally narrow:
  * add ACPI HID QCOM04DD to qcom_scm;
  * skip only DT-only dload-mode, interconnect, and reserved-memory lookups
    when the SCM platform device has no OF node;
  * keep the existing OF behavior byte-for-byte equivalent for DT boots.

No SMC IDs, calling convention, clocks, reset semantics, SMMU code, GPU code,
or ACPI namespace are changed here.
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

    # ACPI declarations / ACPI_PTR().
    replace_once(
        scm,
        '#include <linux/arm-smccc.h>\n',
        '#include <linux/acpi.h>\n#include <linux/arm-smccc.h>\n',
        "acpi_header",
    )

    # qcom_scm_find_dload_address() is a DT helper. of_parse_phandle(NULL, ...)
    # is not an ACPI resource lookup, so make the non-OF case explicit.
    replace_once(
        scm,
        '''\tstruct resource res;\n\tu32 offset;\n\tint ret;\n\n\ttcsr = of_parse_phandle(np, "qcom,dload-mode", 0);\n''',
        '''\tstruct resource res;\n\tu32 offset;\n\tint ret;\n\n\t/* A14_QCOM_SCM_ACPI_QCOM04DD: no DT dload-mode phandle on ACPI SCM0. */\n\tif (!np) {\n\t\t*addr = 0;\n\t\treturn 0;\n\t}\n\n\ttcsr = of_parse_phandle(np, "qcom,dload-mode", 0);\n''',
        "acpi_dload_bypass",
    )

    # The ACPI SCM node has no DT interconnect property. Keep the normal OF
    # path exactly as before, while treating the absent ACPI ICC path as a
    # legitimate no-bandwidth-vote configuration. qcom_scm_bw_enable() already
    # treats scm->path == NULL as no-op.
    old_icc = '''\tmutex_init(&scm->scm_bw_lock);\n\n\tscm->path = devm_of_icc_get(&pdev->dev, NULL);\n\tif (IS_ERR(scm->path))\n\t\treturn dev_err_probe(&pdev->dev, PTR_ERR(scm->path),\n\t\t\t\t     "failed to acquire interconnect path\\n");\n'''
    new_icc = '''\tmutex_init(&scm->scm_bw_lock);\n\n\t/* A14_QCOM_SCM_ACPI_QCOM04DD\n\t * Qualcomm WoA firmware exposes SCM0 as ACPI QCOM04DD without an\n\t * OF interconnect description. Secure calls themselves do not need\n\t * that DT-only lookup; qcom_scm_bw_enable() already accepts NULL.\n\t */\n\tif (pdev->dev.of_node) {\n\t\tscm->path = devm_of_icc_get(&pdev->dev, NULL);\n\t\tif (IS_ERR(scm->path))\n\t\t\treturn dev_err_probe(&pdev->dev, PTR_ERR(scm->path),\n\t\t\t\t\t     "failed to acquire interconnect path\\n");\n\t} else {\n\t\tscm->path = NULL;\n\t\tdev_info(&pdev->dev,\n\t\t\t "A14 ACPI: SCM0 QCOM04DD, DT-only resources skipped\\n");\n\t}\n'''
    replace_once(scm, old_icc, new_icc, "acpi_icc_bypass")

    # of_reserved_mem_device_init() passes dev->of_node to the OF reserved
    # memory core. With a NULL node Linux 7.1.5 returns -EINVAL, which SCM
    # treats as fatal. ACPI SCM0 supplies no DT memory-region, so skip exactly
    # that lookup while preserving the existing DT behavior.
    replace_once(
        scm,
        '''\tret = of_reserved_mem_device_init(scm->dev);\n\tif (ret && ret != -ENODEV)\n\t\treturn dev_err_probe(scm->dev, ret,\n\t\t\t\t     "Failed to setup the reserved memory region for TZ mem\\n");\n''',
        '''\tif (pdev->dev.of_node) {\n\t\tret = of_reserved_mem_device_init(scm->dev);\n\t\tif (ret && ret != -ENODEV)\n\t\t\treturn dev_err_probe(scm->dev, ret,\n\t\t\t\t\t     "Failed to setup the reserved memory region for TZ mem\\n");\n\t}\n''',
        "acpi_reserved_mem_bypass",
    )

    # Add the actual firmware HID and wire it into the same platform driver.
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
        'if (!np)',
        '*addr = 0;',
        'if (pdev->dev.of_node)',
        'scm->path = NULL;',
    ]
    missing = [x for x in required if x not in body]
    if missing:
        fail(f"post-transform verification missing: {missing}")

    # Guard the key safety property: each original OF operation still exists
    # exactly once and is merely gated for the ACPI/non-OF device.
    for token, expected in (
        ('devm_of_icc_get(&pdev->dev, NULL)', 1),
        ('of_reserved_mem_device_init(scm->dev)', 1),
        ('of_parse_phandle(np, "qcom,dload-mode", 0)', 1),
    ):
        if body.count(token) != expected:
            fail(f"unexpected count for {token}: {body.count(token)}")

    print(f"{MARKER}=APPLIED")
    print("acpi_hid=QCOM04DD")
    print("acpi_dload_mode=none")
    print("acpi_interconnect=none")
    print("acpi_reserved_memory=none")
    print("of_behavior=preserved")
    print("smc_calling_convention=unchanged")
    print("smmu_code=unchanged")
    print("gpu_code=unchanged")


if __name__ == "__main__":
    main()
