#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Avoid the proven-fatal eager TLMM direction scan on UX3407RA GIO0.

The v7.1.5 gpiolib registration path calls gpio_chip.get_direction() for every
valid line.  On the audited UX3407RA ACPI GIO0 controller, V2 tracing proves
native GPIO 44's control-register read (phys 0x0f12c000) hard-resets the
machine during that registration scan.

This board-scoped quirk suppresses get_direction only while QCOM0C0C:00 is
being registered, then restores the callback immediately.  It does not mark
GPIO 44 (or any other line) invalid and does not change runtime GPIO direction
operations for actually requested consumers.

The separate WoA ACPI GpioInt translator remains responsible for converting
firmware virtual PDC slots (for example ECKB 0x0180) to native TLMM GPIOs.
"""

from pathlib import Path
import sys

MARKER = "A14_GIO0_SAFE_REGISTRATION_V1"


def die(msg: str) -> None:
    raise SystemExit(f"A14 GIO0 safe registration: {msg}")


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text()
    if new in text:
        print(f"{label}=current")
        return
    n = text.count(old)
    if n != 1:
        die(f"{label}: expected one anchor in {path}, found {n}")
    path.write_text(text.replace(old, new, 1))
    print(f"{label}=applied")


def main() -> None:
    if len(sys.argv) != 2:
        die("usage: apply-a14-74c9-gio0-safe-registration.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    msm = root / "drivers/pinctrl/qcom/pinctrl-msm.c"
    x1 = root / "drivers/pinctrl/qcom/pinctrl-x1e80100.c"
    acpi_gpio = root / "drivers/gpio/gpiolib-acpi-core.c"
    for path in (msm, x1, acpi_gpio):
        if not path.is_file():
            die(f"missing source: {path}")

    # This fix is intentionally layered on the already-proven V1/V2 tree so
    # its scope is exactly the controller that produced the GPIO44 trace.
    mb = msm.read_text()
    if "A14_GIO0_PROBE_TRACE_V1" not in mb:
        die("V1 GIO0 binding/probe marker missing")
    if "A14_GIO0_PROBE_TRACE_V2" not in mb:
        die("V2 per-read proof marker missing")
    if "A14_QCOM_WOA_ACPI_GPIO_XLATE" not in acpi_gpio.read_text():
        die("WoA ACPI GpioInt translator must be applied first")

    table = x1.read_text().split("x1e80100_pinctrl_acpi_match[]", 1)[1].split("};", 1)[0]
    if "QCOM0C0C" not in table or "QCOMFFEB" not in table or "QCOM0C0D" in table:
        die("X1E TLMM ACPI table is not the audited GIO0-only form")

    # Add a saved callback slot to msm_gpio_init().
    replace_once(
        msm,
        '''static int msm_gpio_init(struct msm_pinctrl *pctrl)\n{\n\tstruct gpio_chip *chip;\n\tstruct gpio_irq_chip *girq;\n\tint i, ret;\n\tunsigned gpio, ngpio = pctrl->soc->ngpios;\n\tstruct device_node *np;\n\tbool skip;\n''',
        '''static int msm_gpio_init(struct msm_pinctrl *pctrl)\n{\n\tint (*a14_saved_get_direction)(struct gpio_chip *, unsigned int) = NULL;\n\tstruct gpio_chip *chip;\n\tstruct gpio_irq_chip *girq;\n\tint i, ret;\n\tunsigned gpio, ngpio = pctrl->soc->ngpios;\n\tstruct device_node *np;\n\tbool skip;\n''',
        "saved_get_direction_slot",
    )

    # V1 placed sparse breadcrumbs around devm_gpiochip_add_data().  Keep those
    # breadcrumbs and insert the real behavior change directly around the
    # registration call, so the source remains easy to audit against the V2
    # proof image.
    replace_once(
        msm,
        '''\tdev_info(pctrl->dev, "A14GIO0: before-gpiochip-add parent_irq=%d ngpio=%u\\n",\n\t\t pctrl->irq, chip->ngpio);\n\tret = devm_gpiochip_add_data(pctrl->dev, &pctrl->chip, pctrl);\n\tdev_info(pctrl->dev, "A14GIO0: after-gpiochip-add ret=%d\\n", ret);\n''',
        '''\tdev_info(pctrl->dev, "A14GIO0: before-gpiochip-add parent_irq=%d ngpio=%u\\n",\n\t\t pctrl->irq, chip->ngpio);\n\n\t/* A14_GIO0_SAFE_REGISTRATION_V1\n\t * v7.1.5 gpiolib eagerly calls get_direction() for every valid GPIO\n\t * while registering a gpio_chip.  UX3407RA ACPI tracing proves the\n\t * read for native GPIO44 (0x0f12c000) hard-resets the platform.\n\t * Windows/ACPI consumers do not require that eager native-line scan.\n\t * Suppress only that registration-time scan on the audited GIO0 ACPI\n\t * device, then restore the real callback immediately for requested\n\t * GPIOs.  Do not blacklist GPIO44 or alter other controllers.\n\t */\n\tif (pctrl->dev && dev_name(pctrl->dev) &&\n\t    !strcmp(dev_name(pctrl->dev), "QCOM0C0C:00")) {\n\t\ta14_saved_get_direction = pctrl->chip.get_direction;\n\t\tpctrl->chip.get_direction = NULL;\n\t\tdev_info(pctrl->dev,\n\t\t\t "A14GIO0FIX: suppressing registration-time eager direction scan\\n");\n\t}\n\n\tret = devm_gpiochip_add_data(pctrl->dev, &pctrl->chip, pctrl);\n\n\tif (a14_saved_get_direction) {\n\t\tpctrl->chip.get_direction = a14_saved_get_direction;\n\t\tdev_info(pctrl->dev,\n\t\t\t "A14GIO0FIX: restored runtime get_direction callback ret=%d\\n", ret);\n\t}\n\tdev_info(pctrl->dev, "A14GIO0: after-gpiochip-add ret=%d\\n", ret);\n''',
        "registration_scan_suppression",
    )

    mb = msm.read_text()
    for token in (
        MARKER,
        "A14GIO0FIX: suppressing registration-time eager direction scan",
        "A14GIO0FIX: restored runtime get_direction callback",
        "a14_saved_get_direction = pctrl->chip.get_direction",
        "pctrl->chip.get_direction = NULL",
        "pctrl->chip.get_direction = a14_saved_get_direction",
    ):
        if token not in mb:
            die(f"missing final marker/token: {token}")

    print(f"{MARKER}=APPLIED")
    print("scope=QCOM0C0C:00-registration-only")
    print("fatal_proof=native-GPIO44-read-0x0f12c000")
    print("eager_get_direction_scan=suppressed")
    print("runtime_get_direction=restored")
    print("native_gpio_blacklist=none")
    print("generic_gpiolib_behavior=unchanged")


if __name__ == "__main__":
    main()
