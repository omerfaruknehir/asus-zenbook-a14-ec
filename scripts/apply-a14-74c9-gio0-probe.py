#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""On the restored 74c9bd5 kernel, bind X1E80100 TLMM only to the audited
UX3407RA GIO0 ACPI IDs and add sparse one-shot probe breadcrumbs.

This deliberately DOES NOT add the later WoA virtual GPIO translation.  Its
only functional change is QCOM0C0D (IPC0) -> QCOM0C0C/QCOMFFEB (GIO0).
"""
from pathlib import Path
import sys

MARKER = "A14_GIO0_PROBE_TRACE_V1"


def die(msg: str) -> None:
    raise SystemExit(f"A14 GIO0 probe transform: {msg}")


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
        die("usage: apply-a14-74c9-gio0-probe.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    x1 = root / "drivers/pinctrl/qcom/pinctrl-x1e80100.c"
    msm = root / "drivers/pinctrl/qcom/pinctrl-msm.c"
    gpio = root / "drivers/gpio/gpiolib-acpi-core.c"
    for p in (x1, msm, gpio):
        if not p.is_file():
            die(f"missing source: {p}")

    # Safety: this test must start from the recovered 74c9 state and must not
    # contain the later virtual-GPIO translator.
    if "A14_QCOM_WOA_ACPI_GPIO_XLATE" in gpio.read_text():
        die("later WoA virtual GPIO translation is present; refusing mixed test")

    old_ids = '''static const struct acpi_device_id x1e80100_pinctrl_acpi_match[] = {\n\t{ "QCOM0C0D", 0 },\n\t{ }\n};\n'''
    new_ids = '''static const struct acpi_device_id x1e80100_pinctrl_acpi_match[] = {\n\t{ "QCOM0C0C", 0 }, /* UX3407RA GIO0 _HID */\n\t{ "QCOMFFEB", 0 }, /* UX3407RA GIO0 _CID */\n\t{ }\n};\n'''
    replace_once(x1, old_ids, new_ids, "gio0_acpi_ids")

    # One-shot breadcrumbs only. No namespace-wide tracing and no delays.
    replace_once(
        msm,
        '''int msm_pinctrl_probe(struct platform_device *pdev,\n\t\t      const struct msm_pinctrl_soc_data *soc_data)\n{\n\tconst struct pinfunction *func;\n\tstruct msm_pinctrl *pctrl;\n\tstruct resource *res;\n\tint ret;\n\tint i;\n\n\tpctrl = devm_kzalloc(&pdev->dev, sizeof(*pctrl), GFP_KERNEL);\n''',
        '''int msm_pinctrl_probe(struct platform_device *pdev,\n\t\t      const struct msm_pinctrl_soc_data *soc_data)\n{\n\tconst struct pinfunction *func;\n\tstruct msm_pinctrl *pctrl;\n\tstruct resource *res;\n\tint ret;\n\tint i;\n\n\tdev_info(&pdev->dev, "A14GIO0: probe-enter " "A14_GIO0_PROBE_TRACE_V1\\n");\n\tpctrl = devm_kzalloc(&pdev->dev, sizeof(*pctrl), GFP_KERNEL);\n''',
        "probe_enter",
    )

    replace_once(
        msm,
        '''\tmsm_pinctrl_setup_pm_reset(pctrl);\n\n\tpctrl->irq = platform_get_irq(pdev, 0);\n''',
        '''\tdev_info(&pdev->dev, "A14GIO0: mmio-mapped\\n");\n\tdev_info(&pdev->dev, "A14GIO0: before-pm-reset-setup\\n");\n\tmsm_pinctrl_setup_pm_reset(pctrl);\n\tdev_info(&pdev->dev, "A14GIO0: after-pm-reset-setup\\n");\n\n\tdev_info(&pdev->dev, "A14GIO0: before-platform-get-irq\\n");\n\tpctrl->irq = platform_get_irq(pdev, 0);\n\tdev_info(&pdev->dev, "A14GIO0: after-platform-get-irq irq=%d\\n", pctrl->irq);\n''',
        "probe_resource_irq_trace",
    )

    replace_once(
        msm,
        '''\tpctrl->pctrl = devm_pinctrl_register(&pdev->dev, &pctrl->desc, pctrl);\n\tif (IS_ERR(pctrl->pctrl)) {\n''',
        '''\tdev_info(&pdev->dev, "A14GIO0: before-pinctrl-register\\n");\n\tpctrl->pctrl = devm_pinctrl_register(&pdev->dev, &pctrl->desc, pctrl);\n\tdev_info(&pdev->dev, "A14GIO0: after-pinctrl-register err=%d\\n",\n\t\t IS_ERR(pctrl->pctrl) ? (int)PTR_ERR(pctrl->pctrl) : 0);\n\tif (IS_ERR(pctrl->pctrl)) {\n''',
        "probe_pinctrl_register_trace",
    )

    replace_once(
        msm,
        '''\tret = msm_gpio_init(pctrl);\n\tif (ret)\n\t\treturn ret;\n\n\tplatform_set_drvdata(pdev, pctrl);\n''',
        '''\tdev_info(&pdev->dev, "A14GIO0: before-msm-gpio-init\\n");\n\tret = msm_gpio_init(pctrl);\n\tdev_info(&pdev->dev, "A14GIO0: after-msm-gpio-init ret=%d\\n", ret);\n\tif (ret)\n\t\treturn ret;\n\n\tplatform_set_drvdata(pdev, pctrl);\n\tdev_info(&pdev->dev, "A14GIO0: probe-complete\\n");\n''',
        "probe_gpio_init_trace",
    )

    replace_once(
        msm,
        '''\tret = devm_gpiochip_add_data(pctrl->dev, &pctrl->chip, pctrl);\n\tif (ret) {\n''',
        '''\tdev_info(pctrl->dev, "A14GIO0: before-gpiochip-add parent_irq=%d ngpio=%u\\n",\n\t\t pctrl->irq, chip->ngpio);\n\tret = devm_gpiochip_add_data(pctrl->dev, &pctrl->chip, pctrl);\n\tdev_info(pctrl->dev, "A14GIO0: after-gpiochip-add ret=%d\\n", ret);\n\tif (ret) {\n''',
        "gpiochip_add_trace",
    )

    replace_once(
        msm,
        '''\tif (!of_property_present(pctrl->dev->of_node, "gpio-ranges")) {\n\t\tret = gpiochip_add_pin_range(&pctrl->chip,\n''',
        '''\tif (!of_property_present(pctrl->dev->of_node, "gpio-ranges")) {\n\t\tdev_info(pctrl->dev, "A14GIO0: before-gpio-pin-range\\n");\n\t\tret = gpiochip_add_pin_range(&pctrl->chip,\n''',
        "gpio_pin_range_before_trace",
    )

    # msm_gpio_init() returns directly after this block.  Do not anchor this
    # breadcrumb to msm_pinctrl_probe()'s later dev_dbg(): that is a different
    # function and caused the first version of this transform to fail after
    # partially applying all previous edits.
    replace_once(
        msm,
        '''\t\tret = gpiochip_add_pin_range(&pctrl->chip,\n\t\t\tdev_name(pctrl->dev), 0, 0, chip->ngpio);\n\t\tif (ret) {\n\t\t\tdev_err(pctrl->dev, "Failed to add pin range\\n");\n\t\t\treturn ret;\n\t\t}\n\t}\n\n\treturn 0;\n}\n''',
        '''\t\tret = gpiochip_add_pin_range(&pctrl->chip,\n\t\t\tdev_name(pctrl->dev), 0, 0, chip->ngpio);\n\t\tdev_info(pctrl->dev, "A14GIO0: after-gpio-pin-range ret=%d\\n", ret);\n\t\tif (ret) {\n\t\t\tdev_err(pctrl->dev, "Failed to add pin range\\n");\n\t\t\treturn ret;\n\t\t}\n\t}\n\n\treturn 0;\n}\n''',
        "gpio_pin_range_after_trace",
    )

    xb = x1.read_text()
    table = xb.split("x1e80100_pinctrl_acpi_match[]", 1)[1].split("};", 1)[0]
    if "QCOM0C0C" not in table or "QCOMFFEB" not in table or "QCOM0C0D" in table:
        die("final X1E ACPI match table is not GIO0-only")
    mb = msm.read_text()
    for token in (MARKER, "A14GIO0: mmio-mapped", "A14GIO0: after-platform-get-irq",
                  "A14GIO0: after-pinctrl-register", "A14GIO0: after-gpiochip-add",
                  "A14GIO0: after-gpio-pin-range", "A14GIO0: after-msm-gpio-init",
                  "A14GIO0: probe-complete"):
        if token not in mb:
            die(f"missing final trace token: {token}")

    print(f"{MARKER}=APPLIED")
    print("functional_change=GIO0_ACPI_ID_binding_only")
    print("gio0_ids=QCOM0C0C,QCOMFFEB")
    print("ipc0_qcom0c0d_match=false")
    print("virtual_gpio_translation=false")
    print("trace_scope=msm_pinctrl_probe_one_shot")


if __name__ == "__main__":
    main()
