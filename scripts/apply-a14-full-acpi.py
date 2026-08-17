#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Patch Linux v7.1.5 for the UX3407RA experimental ACPI-only boot.

The resulting kernel uses normal arm64 ACPI boot (acpi=force, no DTB supplied).
This transform only adds Linux-side bindings missing for the Windows-on-ARM
firmware ABI found in the UX3407RA DSDT. It does not replace or override ACPI
AML and it deliberately does not guess the firmware's TPM start-method 9.
"""
from pathlib import Path
import shutil
import sys

KERNEL_VERSION = "7.1.5"
MARKER = "A14_FULL_ACPI_V0"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 full ACPI: {msg}")


def version(root: Path) -> str:
    vals = {}
    for line in (root / "Makefile").read_text().splitlines():
        for key in ("VERSION", "PATCHLEVEL", "SUBLEVEL"):
            if line.startswith(key + " ="):
                vals[key] = line.split("=", 1)[1].strip()
    try:
        return ".".join(vals[k] for k in ("VERSION", "PATCHLEVEL", "SUBLEVEL"))
    except KeyError as e:
        fail(f"cannot determine kernel version: {e}")


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text()
    if new in text:
        print(f"{label}=current")
        return
    n = text.count(old)
    if n != 1:
        fail(f"{label}: expected one anchor in {path}, found {n}")
    path.write_text(text.replace(old, new, 1))
    print(f"{label}=applied")


def append_once(path: Path, marker: str, text: str, label: str) -> None:
    cur = path.read_text()
    if marker in cur:
        print(f"{label}=current")
        return
    path.write_text(cur.rstrip() + "\n\n" + text.rstrip() + "\n")
    print(f"{label}=applied")


def write_if_changed(path: Path, text: str, label: str) -> None:
    if path.exists() and path.read_text() == text:
        print(f"{label}=current")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    print(f"{label}=written")


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: apply-a14-full-acpi.py /path/to/linux-7.1.5")
    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file():
        fail(f"not a kernel source tree: {root}")
    found = version(root)
    if found != KERNEL_VERSION:
        fail(f"targets exactly {KERNEL_VERSION}; found {found}")

    wmi_k = root / "drivers/platform/wmi/Kconfig"
    replace_once(wmi_k,
        '\tdepends on ACPI && X86\n',
        '\tdepends on ACPI && (X86 || ARM64)\n',
        "wmi_arm64")

    platform_k = root / "drivers/platform/Kconfig"
    replace_once(platform_k,
        'source "drivers/platform/wmi/Kconfig"\n',
        'source "drivers/platform/wmi/Kconfig"\n\nsource "drivers/platform/asus/Kconfig"\n',
        "asus_platform_kconfig")
    platform_m = root / "drivers/platform/Makefile"
    append_once(platform_m, "# A14 full ACPI: ARM64 ASUS WMI",
        "# A14 full ACPI: ARM64 ASUS WMI\nobj-$(CONFIG_ARM64)\t\t+= asus/",
        "asus_platform_makefile")

    asus_dir = root / "drivers/platform/asus"
    asus_dir.mkdir(parents=True, exist_ok=True)
    for name in ("asus-wmi.c", "asus-nb-wmi.c", "asus-wmi.h"):
        src = root / "drivers/platform/x86" / name
        if not src.is_file():
            fail(f"missing ASUS source {src}")
        shutil.copyfile(src, asus_dir / name)
    write_if_changed(asus_dir / "Makefile", '''# SPDX-License-Identifier: GPL-2.0
obj-$(CONFIG_ASUS_WMI) += asus-wmi.o
obj-$(CONFIG_ASUS_NB_WMI) += asus-nb-wmi.o
''', "asus_makefile")
    # Reuse the established symbols because include/linux/platform_data/x86/asus-wmi.h
    # gates its real declarations on CONFIG_ASUS_WMI. The x86 definitions are under
    # `if X86_PLATFORM_DEVICES`; this second definition supplies an ARM64-visible prompt.
    write_if_changed(asus_dir / "Kconfig", '''# SPDX-License-Identifier: GPL-2.0-only

config ASUS_WMI
\ttristate "ASUS WMI Driver on ARM64 (experimental)"
\tdepends on ARM64 && ACPI_WMI
\tdepends on ACPI_BATTERY
\tdepends on INPUT
\tdepends on HWMON
\tdepends on BACKLIGHT_CLASS_DEVICE
\tdepends on RFKILL || RFKILL = n
\tdepends on HOTPLUG_PCI
\tdepends on ACPI_VIDEO || ACPI_VIDEO = n
\tdepends on SERIO_I8042 || SERIO_I8042 = n
\tselect INPUT_SPARSEKMAP
\tselect LEDS_CLASS
\tselect NEW_LEDS
\tselect ACPI_PLATFORM_PROFILE
\thelp
\t  Experimental architecture-neutral build of the existing ASUS WMI
\t  driver for Windows-on-ARM ASUS laptops. The UX3407RA firmware exposes
\t  the same ASUS management GUID and device IDs used by this driver.

config ASUS_NB_WMI
\ttristate "ASUS notebook WMI Driver on ARM64 (experimental)"
\tdepends on ARM64 && ASUS_WMI
\thelp
\t  Build the existing ASUS notebook WMI event driver on ARM64.
''', "asus_kconfig")

    i2c = root / "drivers/i2c/busses/i2c-qcom-geni.c"
    replace_once(i2c,
        'static const struct acpi_device_id geni_i2c_acpi_match[] = {\n\t{ "QCOM0220"},\n\t{ "QCOM0411" },\n',
        'static const struct acpi_device_id geni_i2c_acpi_match[] = {\n\t{ "QCOM0220"},\n\t{ "QCOM0411" },\n\t{ "QCOM0C10" }, /* Snapdragon X WoA GENI I2C */\n',
        "geni_qcom0c10")
    replace_once(i2c,
        '\tif (clk_get_rate(gi2c->se.clk) == 32 * HZ_PER_MHZ)\n\t\titr = geni_i2c_clk_map_32mhz;\n\telse\n\t\titr = geni_i2c_clk_map_19p2mhz;\n',
        '\t/* WoA ACPI owns the SE clock; no Linux clk handle is required. */\n\tif (has_acpi_companion(gi2c->se.dev))\n\t\titr = geni_i2c_clk_map_19p2mhz;\n\telse if (clk_get_rate(gi2c->se.clk) == 32 * HZ_PER_MHZ)\n\t\titr = geni_i2c_clk_map_32mhz;\n\telse\n\t\titr = geni_i2c_clk_map_19p2mhz;\n',
        "geni_acpi_clock_map")
    replace_once(i2c,
        '\tret = device_property_read_u32(dev, "clock-frequency",\n\t\t\t\t       &gi2c->clk_freq_out);\n\tif (ret) {\n\t\tdev_info(dev, "Bus frequency not specified, default to 100kHz.\\n");\n\t\tgi2c->clk_freq_out = I2C_MAX_STANDARD_MODE_FREQ;\n\t}\n',
        '\tret = device_property_read_u32(dev, "clock-frequency",\n\t\t\t\t       &gi2c->clk_freq_out);\n\tif (ret && has_acpi_companion(dev))\n\t\tgi2c->clk_freq_out = i2c_acpi_find_bus_speed(dev);\n\tif (ret && !gi2c->clk_freq_out) {\n\t\tdev_info(dev, "Bus frequency not specified, default to 100kHz.\\n");\n\t\tgi2c->clk_freq_out = I2C_MAX_STANDARD_MODE_FREQ;\n\t}\n',
        "geni_acpi_bus_speed")

    pk = root / "drivers/pinctrl/qcom/Kconfig"
    replace_once(pk,
        '\t# OF for pinconf_generic_dt_node_to_map_group() from GENERIC_PINCONF\n\tdepends on OF\n',
        '\t# Keep OF compiled for generic pinconf helpers; runtime may be ACPI-only.\n\tdepends on OF || ACPI\n',
        "pinctrl_msm_acpi")
    px = root / "drivers/pinctrl/qcom/pinctrl-x1e80100.c"
    replace_once(px,
        '#include <linux/module.h>\n#include <linux/of.h>\n',
        '#include <linux/acpi.h>\n#include <linux/module.h>\n#include <linux/of.h>\n',
        "x1e_pinctrl_acpi_include")
    replace_once(px,
        'static const struct of_device_id x1e80100_pinctrl_of_match[] = {\n\t{ .compatible = "qcom,x1e80100-tlmm", },\n\t{ },\n};\n\nstatic struct platform_driver x1e80100_pinctrl_driver = {\n',
        'static const struct of_device_id x1e80100_pinctrl_of_match[] = {\n\t{ .compatible = "qcom,x1e80100-tlmm", },\n\t{ },\n};\n\n#ifdef CONFIG_ACPI\nstatic const struct acpi_device_id x1e80100_pinctrl_acpi_match[] = {\n\t{ "QCOM0C0D", 0 },\n\t{ }\n};\nMODULE_DEVICE_TABLE(acpi, x1e80100_pinctrl_acpi_match);\n#endif\n\nstatic struct platform_driver x1e80100_pinctrl_driver = {\n',
        "x1e_pinctrl_acpi_ids")
    replace_once(px,
        '\t\t.name = "x1e80100-tlmm",\n\t\t.of_match_table = x1e80100_pinctrl_of_match,\n',
        '\t\t.name = "x1e80100-tlmm",\n\t\t.of_match_table = x1e80100_pinctrl_of_match,\n\t\t.acpi_match_table = ACPI_PTR(x1e80100_pinctrl_acpi_match),\n',
        "x1e_pinctrl_acpi_driver")

    armk = root / "drivers/platform/arm64/Kconfig"
    replace_once(armk,
        'if ARM64_PLATFORM_DEVICES\n\n',
        'if ARM64_PLATFORM_DEVICES\n\nconfig QCOM_WOA_PEP_COMPAT\n\tbool "Qualcomm WoA ACPI PEP dependency compatibility"\n\tdepends on ACPI && ARCH_QCOM\n\tdefault y\n\thelp\n\t  Experimental dependency bridge for current Windows-on-ARM Qualcomm\n\t  firmware. It makes the QCOM0C17/PNP0D80 PEP provider ready for ACPI\n\t  _DEP consumers; it does not implement Windows PEP power policy.\n\n',
        "pep_kconfig")
    armm = root / "drivers/platform/arm64/Makefile"
    append_once(armm, "CONFIG_QCOM_WOA_PEP_COMPAT", "obj-$(CONFIG_QCOM_WOA_PEP_COMPAT) += qcom-woa-pep-compat.o", "pep_makefile")
    write_if_changed(root / "drivers/platform/arm64/qcom-woa-pep-compat.c", '''// SPDX-License-Identifier: GPL-2.0-only
#include <linux/acpi.h>
#include <linux/module.h>
#include <linux/platform_device.h>

static int qcom_woa_pep_probe(struct platform_device *pdev)
{
\tstruct acpi_device *adev = ACPI_COMPANION(&pdev->dev);

\tif (!adev)
\t\treturn -ENODEV;

\tdev_warn(&pdev->dev,
\t\t "A14 full-ACPI experiment: satisfying PEP _DEP only; Windows PEP power policy is not implemented\\n");
\tacpi_dev_clear_dependencies(adev);
\treturn 0;
}

static const struct acpi_device_id qcom_woa_pep_ids[] = {
\t{ "QCOM0C17", 0 },
\t{ "PNP0D80", 0 },
\t{ }
};
MODULE_DEVICE_TABLE(acpi, qcom_woa_pep_ids);

static struct platform_driver qcom_woa_pep_driver = {
\t.probe = qcom_woa_pep_probe,
\t.driver = {
\t\t.name = "qcom-woa-pep-compat",
\t\t.acpi_match_table = qcom_woa_pep_ids,
\t},
};
module_platform_driver(qcom_woa_pep_driver);

MODULE_DESCRIPTION("Qualcomm WoA ACPI PEP dependency compatibility");
MODULE_LICENSE("GPL");
''', "pep_driver")

    marker_h = root / "include/linux/a14_full_acpi.h"
    write_if_changed(marker_h, '''/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef _LINUX_A14_FULL_ACPI_H
#define _LINUX_A14_FULL_ACPI_H
#define A14_FULL_ACPI_V0 1
#endif
''', "marker_header")

    checks = {
        wmi_k: ['ACPI && (X86 || ARM64)'],
        i2c: ['QCOM0C10', 'i2c_acpi_find_bus_speed', 'has_acpi_companion(gi2c->se.dev)'],
        px: ['QCOM0C0D', 'acpi_match_table'],
        armk: ['QCOM_WOA_PEP_COMPAT'],
        root / 'drivers/platform/arm64/qcom-woa-pep-compat.c': ['QCOM0C17', 'acpi_dev_clear_dependencies'],
        asus_dir / 'Makefile': ['CONFIG_ASUS_WMI', 'CONFIG_ASUS_NB_WMI'],
        asus_dir / 'asus-wmi.c': ['ASUS_WMI_MGMT_GUID'],
        asus_dir / 'asus-nb-wmi.c': ['ASUS_NB_WMI_EVENT_GUID'],
    }
    for path, tokens in checks.items():
        text = path.read_text()
        missing = [x for x in tokens if x not in text]
        if missing:
            fail(f"post-transform check failed for {path}: {missing}")

    print(f"{MARKER}=APPLIED")
    print("firmware_authority=ACPI")
    print("grub_expected=acpi=force,no-devicetree")
    print("qcom_i2c_hid=QCOM0C10")
    print("qcom_tlmm_hid=QCOM0C0D")
    print("qcom_pep_hid=QCOM0C17")
    print("asus_wmi_arm64=existing-CONFIG_ASUS_WMI")
    print("tpm_start_method_9=left-unmodified")

if __name__ == '__main__':
    main()
