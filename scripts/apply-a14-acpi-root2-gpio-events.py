#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Extend the existing Qualcomm WoA ACPI GpioInt translation to ACPI GPIO events.

ROOT1 proved consumer GpioInt translation via qcom_woa_acpi_gpio_xlate(), but
ACPICA's controller-owned event setup (acpi_gpiochip_alloc_event()) still used
the firmware virtual pin directly for gpiochip operations. On UX3407RA that
leaves events such as 0x0340 and 0x0140 failing with -EINVAL.

Keep two identities deliberately:
  * event->pin remains the original firmware/AML pin. _EVT and OpRegion event
    matching depend on that value.
  * event->gpio_pin is the translated physical TLMM GPIO and is used only for
    gpiochip ownership/IRQ lock/unlock.

The mapping remains firmware-derived from GIO0 _CRS + Qualcomm PDC _DSM CIPR.
There are no board-specific GPIO-number tables here.
"""

from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"
MARKER = "A14_QCOM_WOA_ACPI_GPIO_EVENT_XLATE"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 ROOT2 GPIO-event xlate: {msg}")


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
        fail("usage: apply-a14-acpi-root2-gpio-events.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file():
        fail(f"not a kernel source tree: {root}")
    found = version(root)
    if found != KERNEL_VERSION:
        fail(f"targets exactly {KERNEL_VERSION}; found {found}")

    path = root / "drivers/gpio/gpiolib-acpi-core.c"
    if not path.is_file():
        fail(f"missing source: {path}")

    text = path.read_text()
    required_root1 = (
        "A14_QCOM_WOA_ACPI_GPIO_XLATE",
        "qcom_woa_acpi_gpio_xlate",
        "qcom_woa_pdc_dsm_guid",
    )
    missing = [x for x in required_root1 if x not in text]
    if missing:
        fail(f"ROOT1 WoA translator prerequisite missing: {missing}")

    replace_once(
        path,
        "\tunsigned int pin;\n\tunsigned int irq;\n",
        "\tunsigned int pin;      /* firmware/AML pin */\n"
        "\tunsigned int gpio_pin; /* physical gpiochip pin */\n"
        "\tunsigned int irq;\n",
        "event_gpio_pin_field",
    )

    replace_once(
        path,
        "static struct gpio_desc *acpi_request_own_gpiod(struct gpio_chip *chip,\n"
        "\t\t\t\t\t\tstruct acpi_resource_gpio *agpio,\n"
        "\t\t\t\t\t\tunsigned int index,\n"
        "\t\t\t\t\t\tconst char *label)\n"
        "{\n"
        "\tint polarity = GPIO_ACTIVE_HIGH;\n"
        "\tenum gpiod_flags flags = acpi_gpio_to_gpiod_flags(agpio, polarity);\n"
        "\tunsigned int pin = agpio->pin_table[index];\n"
        "\tstruct gpio_desc *desc;\n",
        "static struct gpio_desc *acpi_request_own_gpiod(struct gpio_chip *chip,\n"
        "\t\t\t\t\t\tstruct acpi_resource_gpio *agpio,\n"
        "\t\t\t\t\t\tunsigned int pin,\n"
        "\t\t\t\t\t\tconst char *label)\n"
        "{\n"
        "\tint polarity = GPIO_ACTIVE_HIGH;\n"
        "\tenum gpiod_flags flags = acpi_gpio_to_gpiod_flags(agpio, polarity);\n"
        "\tstruct gpio_desc *desc;\n",
        "own_gpiod_accept_physical_pin",
    )

    replace_once(
        path,
        "\tstruct gpio_desc *desc;\n\tunsigned int pin;\n\tint ret, irq;\n",
        "\tstruct gpio_desc *desc;\n"
        "\tunsigned int pin, gpio_pin;\n"
        "\tint ret, irq;\n",
        "alloc_event_gpio_pin_local",
    )

    replace_once(
        path,
        "\thandle = ACPI_HANDLE(chip->parent);\n\tpin = agpio->pin_table[0];\n",
        "\thandle = ACPI_HANDLE(chip->parent);\n"
        "\tpin = agpio->pin_table[0];\n"
        "\t/* A14_QCOM_WOA_ACPI_GPIO_EVENT_XLATE: keep AML pin separate. */\n"
        "\tgpio_pin = qcom_woa_acpi_gpio_xlate(handle, pin);\n",
        "event_translate_physical_pin",
    )

    replace_once(
        path,
        "\tdesc = acpi_request_own_gpiod(chip, agpio, 0, \"ACPI:Event\");\n",
        "\tdesc = acpi_request_own_gpiod(chip, agpio, gpio_pin, \"ACPI:Event\");\n",
        "event_request_physical_pin",
    )

    replace_once(
        path,
        "\tret = gpiochip_lock_as_irq(chip, pin);\n",
        "\tret = gpiochip_lock_as_irq(chip, gpio_pin);\n",
        "event_lock_physical_pin",
    )

    replace_once(
        path,
        "\tevent->pin = pin;\n\tevent->desc = desc;\n",
        "\tevent->pin = pin;\n"
        "\tevent->gpio_pin = gpio_pin;\n"
        "\tevent->desc = desc;\n",
        "event_store_both_pins",
    )

    replace_once(
        path,
        "fail_unlock_irq:\n\tgpiochip_unlock_as_irq(chip, pin);\n",
        "fail_unlock_irq:\n\tgpiochip_unlock_as_irq(chip, gpio_pin);\n",
        "event_fail_unlock_physical_pin",
    )

    replace_once(
        path,
        "\t\tgpiochip_unlock_as_irq(chip, event->pin);\n"
        "\t\tgpiochip_free_own_desc(event->desc);\n",
        "\t\tgpiochip_unlock_as_irq(chip, event->gpio_pin);\n"
        "\t\tgpiochip_free_own_desc(event->desc);\n",
        "event_teardown_physical_pin",
    )

    replace_once(
        path,
        "\t\t\tdesc = acpi_request_own_gpiod(chip, agpio, i, \"ACPI:OpRegion\");\n",
        "\t\t\tdesc = acpi_request_own_gpiod(chip, agpio,\n"
        "\t\t\t\t\t\t      agpio->pin_table[i], \"ACPI:OpRegion\");\n",
        "opregion_pass_literal_pin",
    )

    body = path.read_text()
    required = (
        MARKER,
        "unsigned int gpio_pin; /* physical gpiochip pin */",
        "gpio_pin = qcom_woa_acpi_gpio_xlate(handle, pin);",
        'acpi_request_own_gpiod(chip, agpio, gpio_pin, "ACPI:Event")',
        "gpiochip_lock_as_irq(chip, gpio_pin)",
        "event->pin = pin;",
        "event->gpio_pin = gpio_pin;",
        "gpiochip_unlock_as_irq(chip, event->gpio_pin)",
        "agpio->pin_table[i], \"ACPI:OpRegion\"",
    )
    missing = [x for x in required if x not in body]
    if missing:
        fail(f"post-transform verification missing: {missing}")

    if "gpiochip_unlock_as_irq(chip, event->pin)" in body:
        fail("teardown still unlocks firmware pin")

    print(f"{MARKER}=APPLIED")
    print("event_aml_pin=preserved")
    print("event_gpiochip_pin=firmware_translated")
    print("mapping_source=GIO0_CRS_plus_PDC_DSM_CIPR")
    print("board_specific_gpio_table=false")
    print("opregion_behavior=preserved")


if __name__ == "__main__":
    main()
