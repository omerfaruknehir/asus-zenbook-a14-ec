#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Keep the UX3407RA GIO0 TLMM ACPI IDs without WoA GPIO translation.

This is diagnostic variant A:
  - GIO0/TLMM ACPI match: QCOM0C0C + QCOMFFEB
  - IPC0/QCOM0C0D must NOT match TLMM
  - gpiolib WoA virtual-pin translation is intentionally absent
"""
from pathlib import Path
import sys


def die(msg: str) -> None:
    raise SystemExit(f"A14 GIO0 IDs-only: {msg}")


def main() -> None:
    if len(sys.argv) != 2:
        die("usage: apply-a14-full-acpi-gio0-ids-only.py /path/to/linux-7.1.5")
    root = Path(sys.argv[1]).resolve()
    x1 = root / "drivers/pinctrl/qcom/pinctrl-x1e80100.c"
    if not x1.is_file():
        die(f"missing {x1}")

    text = x1.read_text()
    wanted = '''static const struct acpi_device_id x1e80100_pinctrl_acpi_match[] = {\n\t{ "QCOM0C0C", 0 }, /* UX3407RA GIO0 _HID */\n\t{ "QCOMFFEB", 0 }, /* UX3407RA GIO0 _CID */\n\t{ }\n};\n'''
    variants = [
        '''static const struct acpi_device_id x1e80100_pinctrl_acpi_match[] = {\n\t{ "QCOM0C0D", 0 },\n\t{ }\n};\n''',
        '''static const struct acpi_device_id x1e80100_pinctrl_acpi_match[] = {\n\t{ "QCOM0C0C", 0 }, /* UX3407RA GIO0 _HID */\n\t{ "QCOMFFEB", 0 }, /* UX3407RA GIO0 _CID */\n\t{ "QCOM0C0D", 0 }, /* Earlier WoA TLMM firmware ID */\n\t{ }\n};\n''',
    ]

    if wanted in text:
        print("gio0_ids_only=current")
    else:
        hits = [v for v in variants if v in text]
        if len(hits) != 1:
            die(f"expected exactly one known TLMM ACPI match table, found {len(hits)}")
        x1.write_text(text.replace(hits[0], wanted, 1))
        print("gio0_ids_only=applied")

    body = x1.read_text()
    table = body.split("x1e80100_pinctrl_acpi_match[]", 1)[1].split("};", 1)[0]
    if "QCOM0C0C" not in table or "QCOMFFEB" not in table:
        die("required GIO0 IDs missing")
    if "QCOM0C0D" in table:
        die("IPC0/QCOM0C0D still matches TLMM")
    if ".acpi_match_table" not in body:
        die("TLMM ACPI match table is not wired to the driver")

    print("A14_GPIO_AB_VARIANT=A_IDS_ONLY")
    print("gio0_ids=QCOM0C0C,QCOMFFEB")
    print("ipc0_qcom0c0d_match=false")
    print("woa_virtual_gpio_translation=false")


if __name__ == "__main__":
    main()
