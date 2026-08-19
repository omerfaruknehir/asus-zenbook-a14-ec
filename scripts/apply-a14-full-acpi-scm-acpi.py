#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Add the UX3407RA/X1E80100 ACPI SCM binding to Linux 7.1.5.

The firmware exposes the secure-channel manager as:

    \\_SB.SCM0  _HID QCOM04DD

with no MMIO resources of its own.  Upstream qcom_scm is currently OF-only:
it has no ACPI match table and unconditionally asks the OF interconnect core
for an ICC path during probe.  Consequently qcom_scm_is_available() never
becomes true in the A14 ACPI-only boot and the Qualcomm arm-smmu implementation
remains deferred with "qcom_scm not ready".

This transform is intentionally narrow:
  * add ACPI HID QCOM04DD to qcom_scm;
  * do not perform devm_of_icc_get() for a non-OF ACPI SCM device;
  * keep the existing OF path byte-for-byte equivalent for DT boots.

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

    # The ACPI SCM node has no DT interconnect property.  Keep the normal OF
    # path exactly as before, while treating the absent ACPI ICC path as a
    # legitimate no-bandwidth-vote configuration. qcom_scm_bw_enable() already
    # treats scm->path == NULL as no-op.
    old_icc = '''\tmutex_init(&scm->scm_bw_lock);\n\n\tscm->path = devm_of_icc_get(&pdev->dev, NULL);\n\tif (IS_ERR(scm->path))\n\t\treturn dev_err_probe(&pdev->dev, PTR_ERR(scm->path),\n\t\t\t\t     "failed to acquire interconnect path\\n");\n'''
    new_icc = '''\tmutex_init(&scm->scm_bw_lock);\n\n\t/* A14_QCOM_SCM_ACPI_QCOM04DD\n\t * Qualcomm WoA firmware exposes SCM0 as ACPI QCOM04DD without an\n\t * OF interconnect description.  Secure calls themselves do not need\n\t * that DT-only lookup; qcom_scm_bw_enable() already accepts NULL.\n\t */\n\tif (pdev->dev.of_node) {\n\t\tscm->path = devm_of_icc_get(&pdev->dev, NULL);\n\t\tif (IS_ERR(scm->path))\n\t\t\treturn dev_err_probe(&pdev->dev, PTR_ERR(scm->path),\n\t\t\t\t\t     "failed to acquire interconnect path\\n");\n\t} else {\n\t\tscm->path = NULL;\n\t\tdev_info(&pdev->dev,\n\t\t\t "A14 ACPI: SCM0 QCOM04DD, DT interconnect lookup skipped\\n");\n\t}\n'''
    replace_once(scm, old_icc, new_icc, "acpi_icc_bypass")

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
        'A14 ACPI: SCM0 QCOM04DD, DT interconnect lookup skipped',
        'if (pdev->dev.of_node)',
        'scm->path = NULL;',
    ]
    missing = [x for x in required if x not in body]
    if missing:
        fail(f"post-transform verification missing: {missing}")

    # Guard the key safety property: the OF lookup still exists and is now
    # nested under the OF-only branch rather than being removed globally.
    if body.count('devm_of_icc_get(&pdev->dev, NULL)') != 1:
        fail("unexpected devm_of_icc_get count after transform")

    print(f"{MARKER}=APPLIED")
    print("acpi_hid=QCOM04DD")
    print("of_interconnect_behavior=unchanged")
    print("acpi_interconnect=none")
    print("smc_calling_convention=unchanged")
    print("smmu_code=unchanged")
    print("gpu_code=unchanged")


if __name__ == "__main__":
    main()
