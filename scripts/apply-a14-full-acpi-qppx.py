#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Add the Qualcomm WoA QPPX ACPI dependency provider to Linux v7.1.5.

The UX3407RA firmware makes its PCI roots (including PCI6, which contains the
NVMe root disk) depend on \\_SB.QPPX. QPPX exposes HID QCOM0C96 and CID
QCOMFFE4. Upstream Linux has no driver for that supplier, so the consumer can
remain dependency-blocked and never reach normal ACPI PCI enumeration.

This bridge deliberately performs no raw MMIO/GPIO/reset operation. It only
marks QPPX's ACPI dependency contract satisfied, after QPPX itself has been
created as a platform device. Consumer ACPI power methods (_PSC/_PS0 etc.) and
the generic ACPI PCI stack remain responsible for the actual PCI root bring-up.
"""
from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 full ACPI QPPX: {msg}")


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


def append_once(path: Path, marker: str, text: str, label: str) -> None:
    current = path.read_text()
    if marker in current:
        print(f"{label}=current")
        return
    path.write_text(current.rstrip() + "\n" + text.rstrip() + "\n")
    print(f"{label}=applied")


def write_if_changed(path: Path, text: str, label: str) -> None:
    if path.exists() and path.read_text() == text:
        print(f"{label}=current")
        return
    path.write_text(text)
    print(f"{label}=written")


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: apply-a14-full-acpi-qppx.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file():
        fail(f"not a kernel tree: {root}")
    found = kernel_version(root)
    if found != KERNEL_VERSION:
        fail(f"targets exactly {KERNEL_VERSION}; found {found}")

    kconfig = root / "drivers/platform/arm64/Kconfig"
    qppx_kconfig = '''config QCOM_WOA_QPPX_COMPAT
\tbool "Qualcomm WoA ACPI QPPX dependency provider"
\tdepends on ACPI && ARCH_QCOM
\tdefault y
\thelp
\t  Experimental dependency provider for Qualcomm Windows-on-ARM ACPI
\t  firmware. QPPX (QCOM0C96/QCOMFFE4) is listed in _DEP by PCI roots
\t  on the ASUS UX3407RA. The bridge only releases ACPI consumers; it
\t  does not perform raw PCIe reset, GPIO or power-controller accesses.

'''
    replace_once(
        kconfig,
        "endif # ARM64_PLATFORM_DEVICES\n",
        qppx_kconfig + "endif # ARM64_PLATFORM_DEVICES\n",
        "qppx_kconfig",
    )

    makefile = root / "drivers/platform/arm64/Makefile"
    append_once(
        makefile,
        "CONFIG_QCOM_WOA_QPPX_COMPAT",
        "obj-$(CONFIG_QCOM_WOA_QPPX_COMPAT) += qcom-woa-qppx-compat.o",
        "qppx_makefile",
    )

    driver = root / "drivers/platform/arm64/qcom-woa-qppx-compat.c"
    write_if_changed(driver, '''// SPDX-License-Identifier: GPL-2.0-only
#include <linux/acpi.h>
#include <linux/module.h>
#include <linux/platform_device.h>

/*
 * Qualcomm's WoA firmware uses QPPX as an ACPI _DEP supplier for PCI roots.
 * The firmware itself owns the PCIe policy methods.  Linux only needs a real
 * supplier driver so the generic ACPI dependency machinery may continue with
 * the consumer once QPPX has been enumerated.
 */
static int qcom_woa_qppx_probe(struct platform_device *pdev)
{
\tstruct acpi_device *adev = ACPI_COMPANION(&pdev->dev);

\tif (!adev)
\t\treturn -ENODEV;

\tdev_info(&pdev->dev,
\t\t "WoA QPPX dependency provider ready; releasing ACPI consumers\\n");
\tacpi_dev_clear_dependencies(adev);
\treturn 0;
}

static const struct acpi_device_id qcom_woa_qppx_ids[] = {
\t{ "QCOM0C96", 0 },
\t{ "QCOMFFE4", 0 },
\t{ }
};
MODULE_DEVICE_TABLE(acpi, qcom_woa_qppx_ids);

static struct platform_driver qcom_woa_qppx_driver = {
\t.probe = qcom_woa_qppx_probe,
\t.driver = {
\t\t.name = "qcom-woa-qppx-compat",
\t\t.acpi_match_table = qcom_woa_qppx_ids,
\t},
};
module_platform_driver(qcom_woa_qppx_driver);

MODULE_DESCRIPTION("Qualcomm WoA ACPI QPPX dependency provider");
MODULE_LICENSE("GPL");
''', "qppx_driver")

    checks = {
        kconfig: ["QCOM_WOA_QPPX_COMPAT", "QCOM0C96/QCOMFFE4"],
        makefile: ["CONFIG_QCOM_WOA_QPPX_COMPAT"],
        driver: ["QCOM0C96", "QCOMFFE4", "acpi_dev_clear_dependencies"],
    }
    for path, tokens in checks.items():
        text = path.read_text()
        missing = [token for token in tokens if token not in text]
        if missing:
            fail(f"post-transform check failed for {path}: {missing}")

    print("A14_FULL_ACPI_QPPX=APPLIED")
    print("qppx_hid=QCOM0C96")
    print("qppx_cid=QCOMFFE4")
    print("raw_pcie_access=none")
    print("dependency_action=acpi_dev_clear_dependencies")


if __name__ == "__main__":
    main()
