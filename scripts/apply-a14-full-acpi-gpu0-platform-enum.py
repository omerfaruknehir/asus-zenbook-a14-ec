#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Let the Snapdragon X Elite ACPI GPU0 become a real platform device.

On the A14 firmware GPU0 has _HID QCOM0C36 and PCI display-class _CLS. Linux
7.1.5 consequently tags the ACPI object as a backlight/video device and
acpi_default_enumeration() routes it through acpi_create_video_bus_device().
That helper requires a physical node on GPU0's ACPI parent; the A14 parent has
none. The helper therefore creates nothing, but GPU0 is still marked enumerated.
The result is the live state already observed on this machine:

    /sys/bus/acpi/devices/QCOM0C36:00      exists
    modalias includes LNXVIDEO
    physical_node*                         absent
    /sys/bus/platform/devices/QCOM0C36:00 absent

GPU0 has a real IORT Named Component entry, so the correct first step is to
create the physical platform device for the *same ACPI object*, preserving its
ACPI/IORT identity. This transform changes only the enumeration choice for the
exact HID QCOM0C36. It does not bind MSM/Adreno and performs no GPU MMIO.
"""

from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"
MARKER = "A14_QCOM0C36_PLATFORM_ENUM_V1"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 GPU0 platform-enum transform: {msg}")


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


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: apply-a14-full-acpi-gpu0-platform-enum.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file():
        fail(f"not a kernel source tree: {root}")
    found = kernel_version(root)
    if found != KERNEL_VERSION:
        fail(f"targets exactly {KERNEL_VERSION}; found {found}")

    path = root / "drivers/acpi/scan.c"
    text = path.read_text()

    marker_block = '''\t} else if (device->pnp.type.backlight &&\n\t\t   strcmp(acpi_device_hid(device), "QCOM0C36")) {\n'''
    if marker_block in text and MARKER in text:
        print("qcom0c36_video_exception=current")
    else:
        old = '''\t} else if (device->pnp.type.backlight) {\n\t\tstruct acpi_device *parent;\n\n\t\tparent = acpi_dev_parent(device);\n\t\tif (parent)\n\t\t\tacpi_create_video_bus_device(device, parent);\n\t} else {\n\t\t/* For a regular device object, create a platform device. */\n\t\tacpi_create_platform_device(device, NULL);\n\t}\n'''
        new = '''\t} else if (device->pnp.type.backlight &&\n\t\t   strcmp(acpi_device_hid(device), "QCOM0C36")) {\n\t\tstruct acpi_device *parent;\n\n\t\tparent = acpi_dev_parent(device);\n\t\tif (parent)\n\t\t\tacpi_create_video_bus_device(device, parent);\n\t} else {\n\t\t/*\n\t\t * A14_QCOM0C36_PLATFORM_ENUM_V1\n\t\t * Snapdragon X Elite GPU0 is a combined Windows graphics ACPI\n\t\t * object. Its display-class _CLS makes ACPI tag it as LNXVIDEO,\n\t\t * but the video-bus auxiliary path cannot instantiate it because\n\t\t * its ACPI parent has no physical node. Keep the real ACPI object\n\t\t * as DMA/IORT owner and create the normal platform device instead.\n\t\t * MSM/Adreno binding is deliberately a separate later layer.\n\t\t */\n\t\tif (!strcmp(acpi_device_hid(device), "QCOM0C36"))\n\t\t\tdev_info(&device->dev,\n\t\t\t\t "A14 ACPI: QCOM0C36 GPU0 using platform enumeration\\n");\n\n\t\t/* For a regular device object, create a platform device. */\n\t\tacpi_create_platform_device(device, NULL);\n\t}\n'''
        count = text.count(old)
        if count != 1:
            fail(f"expected one acpi_default_enumeration anchor, found {count}")
        text = text.replace(old, new, 1)
        path.write_text(text)
        print("qcom0c36_video_exception=applied")

    body = path.read_text()
    required = [
        MARKER,
        'strcmp(acpi_device_hid(device), "QCOM0C36")',
        'A14 ACPI: QCOM0C36 GPU0 using platform enumeration',
        'acpi_create_platform_device(device, NULL);',
    ]
    missing = [x for x in required if x not in body]
    if missing:
        fail(f"post-transform verification missing: {missing}")

    # Safety: only one special-case HID and no MSM/GPU register code here.
    if body.count('"QCOM0C36"') != 2:
        fail(f"unexpected QCOM0C36 occurrence count: {body.count(chr(34) + 'QCOM0C36' + chr(34))}")

    print(f"{MARKER}=APPLIED")
    print("scope=ACPI_default_enumeration_QCOM0C36_only")
    print("physical_device=real_GPU0_platform_device")
    print("iort_identity=preserved")
    print("msm_adreno_binding=unchanged")
    print("gpu_mmio_access=none")
    print("gpu_power_change=none")
    print("display_kms_change=none")


if __name__ == "__main__":
    main()
