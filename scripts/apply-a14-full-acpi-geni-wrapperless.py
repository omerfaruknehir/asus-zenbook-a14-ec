#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Avoid the DT-only GENI wrapper assumption for WoA ACPI I2C devices.

Linux's GENI I2C probe normally obtains se.wrapper from dev->parent and then
calls geni_se_get_tx_fifo_depth(), which consults the QUP wrapper HW-version
register before reading the serial-engine HW_PARAM register.  On the A14 ACPI
namespace the QCOM0C10 serial-engine devices are instantiated without the DT
QUP-wrapper parent, leaving se.wrapper NULL.

For an ACPI GENI I2C device with no wrapper, read the TX FIFO depth directly
from the serial engine's SE_HW_PARAM_0 register using the full 8-bit depth
field.  Normal DT/wrapper-backed devices retain the upstream path unchanged.
"""

from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 GENI wrapperless ACPI: {msg}")


def kernel_version(root: Path) -> str:
    vals = {}
    for line in (root / "Makefile").read_text().splitlines():
        for key in ("VERSION", "PATCHLEVEL", "SUBLEVEL"):
            if line.startswith(key + " ="):
                vals[key] = line.split("=", 1)[1].strip()
    return ".".join(vals[k] for k in ("VERSION", "PATCHLEVEL", "SUBLEVEL"))


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: apply-a14-full-acpi-geni-wrapperless.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file() or kernel_version(root) != KERNEL_VERSION:
        fail(f"targets exactly Linux {KERNEL_VERSION}")

    path = root / "drivers/i2c/busses/i2c-qcom-geni.c"
    text = path.read_text()

    old = '''\t\ttx_depth = geni_se_get_tx_fifo_depth(&gi2c->se);\n\n\t\t/* I2C Master Hub Serial Elements doesn't have the HW_PARAM_0 register */\n'''
    new = '''\t\t/*\n\t\t * DT normally supplies a QUP-wrapper parent and\n\t\t * geni_se_get_tx_fifo_depth() reads that wrapper's HW version before\n\t\t * decoding SE_HW_PARAM_0.  WoA ACPI QCOM0C10 devices do not have that\n\t\t * Linux wrapper parent, so se.wrapper is NULL.  The serial engine still\n\t\t * exposes its own HW_PARAM_0 register; decode the full depth field\n\t\t * directly rather than dereferencing a missing wrapper.\n\t\t */\n\t\tif (has_acpi_companion(dev) && !gi2c->se.wrapper) {\n\t\t\tu32 hw_param = readl_relaxed(gi2c->se.base + SE_HW_PARAM_0);\n\n\t\t\ttx_depth = (hw_param & TX_FIFO_DEPTH_MSK_256_BYTES) >>\n\t\t\t\t   TX_FIFO_DEPTH_SHFT;\n\t\t\tdev_info(dev,\n\t\t\t\t "A14 ACPI: wrapperless GENI SE, TX FIFO depth %u from HW_PARAM_0\\n",\n\t\t\t\t tx_depth);\n\t\t} else {\n\t\t\ttx_depth = geni_se_get_tx_fifo_depth(&gi2c->se);\n\t\t}\n\n\t\t/* I2C Master Hub Serial Elements doesn't have the HW_PARAM_0 register */\n'''

    if new in text:
        print("geni_wrapperless_fifo_depth=current")
    else:
        count = text.count(old)
        if count != 1:
            fail(f"expected one TX FIFO-depth probe anchor, found {count}")
        path.write_text(text.replace(old, new, 1))
        print("geni_wrapperless_fifo_depth=applied")

    final = path.read_text()
    required = (
        'has_acpi_companion(dev) && !gi2c->se.wrapper',
        'SE_HW_PARAM_0',
        'TX_FIFO_DEPTH_MSK_256_BYTES',
        'A14 ACPI: wrapperless GENI SE, TX FIFO depth',
        'geni_se_get_tx_fifo_depth(&gi2c->se)',
    )
    missing = [x for x in required if x not in final]
    if missing:
        fail(f"verification missing: {missing}")
    if final.count('A14 ACPI: wrapperless GENI SE, TX FIFO depth') != 1:
        fail("wrapperless FIFO fallback duplicated")

    print("A14_FULL_ACPI_GENI_WRAPPERLESS=APPLIED")
    print("scope=ACPI-GENI-I2C-with-null-wrapper")
    print("dt_wrapper_path=unchanged")
    print("fallback_source=SE_HW_PARAM_0")
    print("fallback_field=TX_FIFO_DEPTH_MSK_256_BYTES")


if __name__ == "__main__":
    main()
