#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Add a second-stage GIO0 trace on top of the 74c9 GIO0-ID probe.

V2 keeps the functional change identical to V1 (bind X1E80100 TLMM only to
UX3407RA GIO0 QCOM0C0C/QCOMFFEB).  It adds diagnostics only:

* stage breadcrumbs inside gpiochip_add_data_with_key(), restricted to the
  QCOM0C0C:00 gpiochip;
* before/after breadcrumbs around every msm_gpio_get_direction() TLMM control
  register read for QCOM0C0C:00.

The per-read trace is intentionally synchronous printk/dev_info output.  If a
particular MMIO read wedges the machine, the last visible "before" line names
that GPIO and register address exactly.
"""
from pathlib import Path
import sys

MARKER = "A14_GIO0_PROBE_TRACE_V2"


def die(msg: str) -> None:
    raise SystemExit(f"A14 GIO0 V2 transform: {msg}")


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
        die("usage: apply-a14-74c9-gio0-probe-v2.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    msm = root / "drivers/pinctrl/qcom/pinctrl-msm.c"
    gpiolib = root / "drivers/gpio/gpiolib.c"
    acpi_core = root / "drivers/gpio/gpiolib-acpi-core.c"
    for p in (msm, gpiolib, acpi_core):
        if not p.is_file():
            die(f"missing source: {p}")

    if "A14_GIO0_PROBE_TRACE_V1" not in msm.read_text():
        die("V1 GIO0 probe marker missing; apply apply-a14-74c9-gio0-probe.py first")
    if "A14_QCOM_WOA_ACPI_GPIO_XLATE" in acpi_core.read_text():
        die("later WoA virtual GPIO translation is present; refusing mixed test")

    # pinctrl-msm.c already includes string_choices.h, but include string.h
    # explicitly because the V2 guard uses strcmp().
    replace_once(
        msm,
        '''#include <linux/spinlock.h>\n#include <linux/string_choices.h>\n''',
        '''#include <linux/spinlock.h>\n#include <linux/string.h>\n#include <linux/string_choices.h>\n''',
        "msm_string_include",
    )

    replace_once(
        msm,
        '''static int msm_gpio_get_direction(struct gpio_chip *chip, unsigned int offset)\n{\n\tstruct msm_pinctrl *pctrl = gpiochip_get_data(chip);\n\tconst struct msm_pingroup *g;\n\tu32 val;\n\n\tg = &pctrl->soc->groups[offset];\n\n\tval = msm_readl_ctl(pctrl, g);\n\n\treturn val & BIT(g->oe_bit) ? GPIO_LINE_DIRECTION_OUT :\n\t\t\t\t      GPIO_LINE_DIRECTION_IN;\n}\n''',
        '''static int msm_gpio_get_direction(struct gpio_chip *chip, unsigned int offset)\n{\n\tstruct msm_pinctrl *pctrl = gpiochip_get_data(chip);\n\tconst struct msm_pingroup *g;\n\tbool a14_trace;\n\tu32 val;\n\n\tg = &pctrl->soc->groups[offset];\n\ta14_trace = pctrl->dev && dev_name(pctrl->dev) &&\n\t\t    !strcmp(dev_name(pctrl->dev), "QCOM0C0C:00");\n\n\tif (a14_trace)\n\t\tdev_info(pctrl->dev,\n\t\t\t "A14GIO0DIR: before gpio=%u tile=%u ctl=0x%05x phys=0x%08x "\n\t\t\t "A14_GIO0_PROBE_TRACE_V2\\n",\n\t\t\t offset, g->tile, g->ctl_reg,\n\t\t\t pctrl->phys_base[g->tile] + g->ctl_reg);\n\n\tval = msm_readl_ctl(pctrl, g);\n\n\tif (a14_trace)\n\t\tdev_info(pctrl->dev,\n\t\t\t "A14GIO0DIR: after gpio=%u tile=%u ctl=0x%05x phys=0x%08x "\n\t\t\t "val=0x%08x oe_bit=%u\\n",\n\t\t\t offset, g->tile, g->ctl_reg,\n\t\t\t pctrl->phys_base[g->tile] + g->ctl_reg, val, g->oe_bit);\n\n\treturn val & BIT(g->oe_bit) ? GPIO_LINE_DIRECTION_OUT :\n\t\t\t\t      GPIO_LINE_DIRECTION_IN;\n}\n''',
        "direction_mmio_trace",
    )

    # Restrict generic gpiolib tracing to this exact ACPI platform device.
    replace_once(
        gpiolib,
        '''int gpiochip_add_data_with_key(struct gpio_chip *gc, void *data,\n\t\t\t       struct lock_class_key *lock_key,\n\t\t\t       struct lock_class_key *request_key)\n{\n\tstruct gpio_device *gdev;\n\tunsigned int desc_index;\n\tint base = 0;\n\tint ret;\n\n\tgdev = kzalloc(sizeof(*gdev), GFP_KERNEL);\n''',
        '''int gpiochip_add_data_with_key(struct gpio_chip *gc, void *data,\n\t\t\t       struct lock_class_key *lock_key,\n\t\t\t       struct lock_class_key *request_key)\n{\n\tstruct gpio_device *gdev;\n\tunsigned int desc_index;\n\tbool a14_trace;\n\tint base = 0;\n\tint ret;\n\n\ta14_trace = gc->parent && dev_name(gc->parent) &&\n\t\t    !strcmp(dev_name(gc->parent), "QCOM0C0C:00");\n\tif (a14_trace)\n\t\tpr_info("A14GIO0V2: gpiochip-enter ngpio=%u label=%s "\n\t\t\t"A14_GIO0_PROBE_TRACE_V2\\n",\n\t\t\tgc->ngpio, gc->label ?: "unknown");\n\n\tgdev = kzalloc(sizeof(*gdev), GFP_KERNEL);\n''',
        "gpiochip_enter_trace",
    )

    replace_once(
        gpiolib,
        '''\tret = gpiochip_get_ngpios(gc, &gdev->dev);\n\tif (ret)\n''',
        '''\tif (a14_trace)\n\t\tpr_info("A14GIO0V2: before-get-ngpios\\n");\n\tret = gpiochip_get_ngpios(gc, &gdev->dev);\n\tif (a14_trace)\n\t\tpr_info("A14GIO0V2: after-get-ngpios ret=%d ngpio=%u\\n", ret, gc->ngpio);\n\tif (ret)\n''',
        "get_ngpios_trace",
    )

    replace_once(
        gpiolib,
        '''\tret = gpiochip_init_valid_mask(gc);\n\tif (ret)\n\t\tgoto err_remove_from_list;\n\n\tfor (desc_index = 0; desc_index < gc->ngpio; desc_index++) {\n''',
        '''\tif (a14_trace)\n\t\tpr_info("A14GIO0V2: before-valid-mask\\n");\n\tret = gpiochip_init_valid_mask(gc);\n\tif (a14_trace)\n\t\tpr_info("A14GIO0V2: after-valid-mask ret=%d\\n", ret);\n\tif (ret)\n\t\tgoto err_remove_from_list;\n\n\tif (a14_trace)\n\t\tpr_info("A14GIO0V2: direction-scan-before ngpio=%u\\n", gc->ngpio);\n\tfor (desc_index = 0; desc_index < gc->ngpio; desc_index++) {\n''',
        "valid_mask_direction_before_trace",
    )

    replace_once(
        gpiolib,
        '''\t}\n\n\tret = of_gpiochip_add(gc);\n\tif (ret)\n\t\tgoto err_free_valid_mask;\n\n\tret = gpiochip_add_pin_ranges(gc);\n\tif (ret)\n\t\tgoto err_remove_of_chip;\n\n\tacpi_gpiochip_add(gc);\n\n\tret = gpiochip_hog_lines(gc);\n''',
        '''\t}\n\n\tif (a14_trace)\n\t\tpr_info("A14GIO0V2: direction-scan-after\\n");\n\n\tif (a14_trace)\n\t\tpr_info("A14GIO0V2: before-of-gpiochip-add\\n");\n\tret = of_gpiochip_add(gc);\n\tif (a14_trace)\n\t\tpr_info("A14GIO0V2: after-of-gpiochip-add ret=%d\\n", ret);\n\tif (ret)\n\t\tgoto err_free_valid_mask;\n\n\tif (a14_trace)\n\t\tpr_info("A14GIO0V2: before-pin-ranges\\n");\n\tret = gpiochip_add_pin_ranges(gc);\n\tif (a14_trace)\n\t\tpr_info("A14GIO0V2: after-pin-ranges ret=%d\\n", ret);\n\tif (ret)\n\t\tgoto err_remove_of_chip;\n\n\tif (a14_trace)\n\t\tpr_info("A14GIO0V2: before-acpi-gpiochip-add\\n");\n\tacpi_gpiochip_add(gc);\n\tif (a14_trace)\n\t\tpr_info("A14GIO0V2: after-acpi-gpiochip-add\\n");\n\n\tif (a14_trace)\n\t\tpr_info("A14GIO0V2: before-hog-lines\\n");\n\tret = gpiochip_hog_lines(gc);\n''',
        "post_direction_registration_trace",
    )

    replace_once(
        gpiolib,
        '''\tret = gpiochip_hog_lines(gc);\n\tif (ret)\n\t\tgoto err_free_hogs;\n\n\tret = gpiochip_irqchip_init_valid_mask(gc);\n\tif (ret)\n\t\tgoto err_free_hogs;\n\n\tret = gpiochip_irqchip_init_hw(gc);\n\tif (ret)\n\t\tgoto err_remove_irqchip_mask;\n\n\tret = gpiochip_add_irqchip(gc, lock_key, request_key);\n\tif (ret)\n\t\tgoto err_remove_irqchip_mask;\n\n\tret = gpiochip_setup_shared(gc);\n\tif (ret)\n\t\tgoto err_remove_irqchip;\n''',
        '''\tret = gpiochip_hog_lines(gc);\n\tif (a14_trace)\n\t\tpr_info("A14GIO0V2: after-hog-lines ret=%d\\n", ret);\n\tif (ret)\n\t\tgoto err_free_hogs;\n\n\tif (a14_trace)\n\t\tpr_info("A14GIO0V2: before-irq-valid-mask\\n");\n\tret = gpiochip_irqchip_init_valid_mask(gc);\n\tif (a14_trace)\n\t\tpr_info("A14GIO0V2: after-irq-valid-mask ret=%d\\n", ret);\n\tif (ret)\n\t\tgoto err_free_hogs;\n\n\tif (a14_trace)\n\t\tpr_info("A14GIO0V2: before-irq-init-hw\\n");\n\tret = gpiochip_irqchip_init_hw(gc);\n\tif (a14_trace)\n\t\tpr_info("A14GIO0V2: after-irq-init-hw ret=%d\\n", ret);\n\tif (ret)\n\t\tgoto err_remove_irqchip_mask;\n\n\tif (a14_trace)\n\t\tpr_info("A14GIO0V2: before-add-irqchip\\n");\n\tret = gpiochip_add_irqchip(gc, lock_key, request_key);\n\tif (a14_trace)\n\t\tpr_info("A14GIO0V2: after-add-irqchip ret=%d\\n", ret);\n\tif (ret)\n\t\tgoto err_remove_irqchip_mask;\n\n\tif (a14_trace)\n\t\tpr_info("A14GIO0V2: before-setup-shared\\n");\n\tret = gpiochip_setup_shared(gc);\n\tif (a14_trace)\n\t\tpr_info("A14GIO0V2: after-setup-shared ret=%d\\n", ret);\n\tif (ret)\n\t\tgoto err_remove_irqchip;\n''',
        "irqchip_stage_trace",
    )

    replace_once(
        gpiolib,
        '''\tif (gpiolib_initialized) {\n\t\tret = gpiochip_setup_dev(gc);\n\t\tif (ret)\n\t\t\tgoto err_teardown_shared;\n\t}\n\n\treturn 0;\n''',
        '''\tif (gpiolib_initialized) {\n\t\tif (a14_trace)\n\t\t\tpr_info("A14GIO0V2: before-setup-dev\\n");\n\t\tret = gpiochip_setup_dev(gc);\n\t\tif (a14_trace)\n\t\t\tpr_info("A14GIO0V2: after-setup-dev ret=%d\\n", ret);\n\t\tif (ret)\n\t\t\tgoto err_teardown_shared;\n\t}\n\n\tif (a14_trace)\n\t\tpr_info("A14GIO0V2: gpiochip-success\\n");\n\treturn 0;\n''',
        "gpiochip_success_trace",
    )

    mb = msm.read_text()
    gb = gpiolib.read_text()
    for token in (
        MARKER,
        "A14GIO0DIR: before gpio=",
        "A14GIO0DIR: after gpio=",
    ):
        if token not in mb:
            die(f"missing final msm trace token: {token}")
    for token in (
        MARKER,
        "A14GIO0V2: gpiochip-enter",
        "A14GIO0V2: before-valid-mask",
        "A14GIO0V2: direction-scan-before",
        "A14GIO0V2: direction-scan-after",
        "A14GIO0V2: before-acpi-gpiochip-add",
        "A14GIO0V2: before-add-irqchip",
        "A14GIO0V2: gpiochip-success",
    ):
        if token not in gb:
            die(f"missing final gpiolib trace token: {token}")

    print(f"{MARKER}=APPLIED")
    print("functional_change=none_beyond_v1_gio0_id_binding")
    print("trace_scope=QCOM0C0C:00_only")
    print("direction_mmio_reads=before_and_after_each_gpio")
    print("gpiochip_substages=enabled")
    print("virtual_gpio_translation=false")


if __name__ == "__main__":
    main()
