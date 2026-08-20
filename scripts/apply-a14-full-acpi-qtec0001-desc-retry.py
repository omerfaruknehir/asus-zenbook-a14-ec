#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Retry the A14 QTEC0001 HID descriptor read only on transient I2C NACK.

The ACPI-only A14 boot can reach QTEC0001 with the GENI controller and IRQ/GPIO
translation working, then receive -ENXIO (GENI NACK) on the 30-byte HID
descriptor transaction. Linux i2c-hid already retries the preceding one-byte
address probe, but does not retry the descriptor transaction.

This transform adds a machine/device-scoped fallback in i2c-hid-core:
- only an ACPI companion with HID QTEC0001
- only when the descriptor read returns -ENXIO
- up to 20 retries at 50 ms intervals (1 s total)
- no behavior change for any other device/error
"""

from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"
MARKER = "A14_QTEC0001_HID_DESC_RETRY_V1"
LOG_OK = "A14QTEC: HID descriptor ACK after"
LOG_FAIL = "A14QTEC: HID descriptor still NACKing after"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 QTEC0001 descriptor-retry transform: {msg}")


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


def verify(path: Path) -> None:
    body = path.read_text()
    required = [
        MARKER,
        '#include <linux/acpi.h>',
        'acpi_dev_hid_uid_match(adev, "QTEC0001", NULL)',
        'error == -ENXIO',
        'attempt < 20',
        'msleep(50)',
        LOG_OK,
        LOG_FAIL,
    ]
    missing = [x for x in required if x not in body]
    if missing:
        fail(f"verification missing: {missing}")
    if body.count(MARKER) != 1:
        fail(f"expected exactly one {MARKER}")


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: apply-a14-full-acpi-qtec0001-desc-retry.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file():
        fail(f"not a kernel source tree: {root}")
    found = kernel_version(root)
    if found != KERNEL_VERSION:
        fail(f"targets exactly {KERNEL_VERSION}; found {found}")

    path = root / "drivers/hid/i2c-hid/i2c-hid-core.c"
    body = path.read_text()

    if MARKER in body:
        verify(path)
        print("qtec0001_descriptor_retry=current")
        print("A14_QTEC0001_HID_DESC_RETRY_V1=APPLIED")
        return

    inc_old = '#include <linux/module.h>\n#include <linux/i2c.h>\n'
    inc_new = '#include <linux/module.h>\n#include <linux/acpi.h>\n#include <linux/i2c.h>\n'
    if body.count(inc_old) != 1:
        fail("include anchor not found exactly once")
    body = body.replace(inc_old, inc_new, 1)

    helper_anchor = '''static int i2c_hid_probe_address(struct i2c_hid *ihid)\n{\n'''
    helper = '''/*\n * A14_QTEC0001_HID_DESC_RETRY_V1\n *\n * The A14 keyboard EC can ACK the generic address probe while still NACKing\n * the immediately following HID descriptor transaction. Keep this workaround\n * restricted to the exact ACPI QTEC0001 device.\n */\nstatic bool i2c_hid_is_a14_qtec0001(struct i2c_hid *ihid)\n{\n#if IS_ENABLED(CONFIG_ACPI)\n\tstruct acpi_device *adev = ACPI_COMPANION(&ihid->client->dev);\n\n\treturn adev && acpi_dev_hid_uid_match(adev, "QTEC0001", NULL);\n#else\n\treturn false;\n#endif\n}\n\nstatic int i2c_hid_probe_address(struct i2c_hid *ihid)\n{\n'''
    if body.count(helper_anchor) != 1:
        fail("probe-address anchor not found exactly once")
    body = body.replace(helper_anchor, helper, 1)

    old = '''\t\terror = i2c_hid_read_register(ihid,\n\t\t\t\t\t      ihid->wHIDDescRegister,\n\t\t\t\t\t      &ihid->hdesc,\n\t\t\t\t\t      sizeof(ihid->hdesc));\n\t\tif (error) {\n\t\t\tdev_err(&ihid->client->dev,\n\t\t\t\t"failed to fetch HID descriptor: %d\\n",\n\t\t\t\terror);\n\t\t\treturn -ENODEV;\n\t\t}\n'''
    new = '''\t\terror = i2c_hid_read_register(ihid,\n\t\t\t\t\t      ihid->wHIDDescRegister,\n\t\t\t\t\t      &ihid->hdesc,\n\t\t\t\t\t      sizeof(ihid->hdesc));\n\t\tif (error == -ENXIO && i2c_hid_is_a14_qtec0001(ihid)) {\n\t\t\tint attempt;\n\n\t\t\tfor (attempt = 0; attempt < 20 && error == -ENXIO; attempt++) {\n\t\t\t\tmsleep(50);\n\t\t\t\terror = i2c_hid_read_register(ihid,\n\t\t\t\t\t\t      ihid->wHIDDescRegister,\n\t\t\t\t\t\t      &ihid->hdesc,\n\t\t\t\t\t\t      sizeof(ihid->hdesc));\n\t\t\t}\n\n\t\t\tif (!error)\n\t\t\t\tdev_info(&ihid->client->dev,\n\t\t\t\t\t "A14QTEC: HID descriptor ACK after %d retry(s)\\n",\n\t\t\t\t\t attempt);\n\t\t\telse if (error == -ENXIO)\n\t\t\t\tdev_warn(&ihid->client->dev,\n\t\t\t\t\t "A14QTEC: HID descriptor still NACKing after %d retry(s)\\n",\n\t\t\t\t\t attempt);\n\t\t}\n\t\tif (error) {\n\t\t\tdev_err(&ihid->client->dev,\n\t\t\t\t"failed to fetch HID descriptor: %d\\n",\n\t\t\t\terror);\n\t\t\treturn -ENODEV;\n\t\t}\n'''
    if body.count(old) != 1:
        fail(f"descriptor-read anchor count is {body.count(old)}, expected 1")
    body = body.replace(old, new, 1)

    path.write_text(body)
    verify(path)
    print("qtec0001_descriptor_retry=applied")
    print("A14_QTEC0001_HID_DESC_RETRY_V1=APPLIED")
    print("scope=ACPI_QTEC0001_ENXIO_only")
    print("retry_count=20")
    print("retry_interval_ms=50")
    print("max_retry_window_ms=1000")
    print("gpu_code_change=none")
    print("gpio_code_change=none")


if __name__ == "__main__":
    main()
