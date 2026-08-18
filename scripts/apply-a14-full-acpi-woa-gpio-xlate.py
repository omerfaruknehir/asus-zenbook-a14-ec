#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Add Qualcomm WoA ACPI virtual-GPIO translation to Linux v7.1.5.

The UX3407RA firmware exposes TLMM as ACPI GIO0. GpioInt consumers do not
always contain literal TLMM GPIO numbers: PDC-routed pins are encoded as an
index into GIO0's ordered _CRS Interrupt resources, multiplied by 0x40.
GIO0's Qualcomm PDC _DSM then exposes CIPR tuples mapping each GSI back to the
physical TLMM GPIO.

Example from the audited UX3407RA DSDT and known-good DT:
  ECKB GpioInt 0x0180 -> _CRS IRQ index 6 -> GSI 0x253
                       -> CIPR { 0x58, 0x43, 0x253 }
                       -> TLMM GPIO 67

The UX3407RA also uses ACPI _HID QCOM0C0D for IPC0, a GLINK dependency device
with no MMIO _CRS.  Upstream's older X1E WoA TLMM ACPI match for QCOM0C0D must
therefore not match this machine: doing so binds the pinctrl driver to IPC0 and
fails with "invalid resource (null)".  This transform replaces the ACPI match
set with the IDs actually exposed by GIO0 on the audited UX3407RA:
QCOM0C0C / QCOMFFEB.

The virtual-pin transform is deliberately fail-closed and only translates
GpioInt resources on a Qualcomm GIO0 controller exposing those expected ACPI
IDs and PDC _DSM. GpioIo resources and ordinary ACPI GPIO controllers are
unchanged.
"""

from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"
MARKER = "A14_QCOM_WOA_ACPI_GPIO_XLATE"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 WoA GPIO xlate: {msg}")


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
        fail("usage: apply-a14-full-acpi-woa-gpio-xlate.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file():
        fail(f"not a kernel source tree: {root}")
    found = version(root)
    if found != KERNEL_VERSION:
        fail(f"targets exactly {KERNEL_VERSION}; found {found}")

    # Audited UX3407RA namespace:
    #   GIO0 = _HID QCOM0C0C, _CID QCOMFFEB, with TLMM MMIO in _CRS.
    #   IPC0 = _HID QCOM0C0D, no MMIO _CRS.
    # Do not retain QCOM0C0D as a TLMM match on this board: it binds the
    # pinctrl driver to IPC0 and qcom_pinctrl_probe() then sees resource NULL.
    x1 = root / "drivers/pinctrl/qcom/pinctrl-x1e80100.c"
    text = x1.read_text()
    old_variants = (
        '''static const struct acpi_device_id x1e80100_pinctrl_acpi_match[] = {\n\t{ "QCOM0C0D", 0 },\n\t{ }\n};\n''',
        '''static const struct acpi_device_id x1e80100_pinctrl_acpi_match[] = {\n\t{ "QCOM0C0C", 0 }, /* UX3407RA GIO0 _HID */\n\t{ "QCOMFFEB", 0 }, /* UX3407RA GIO0 _CID */\n\t{ "QCOM0C0D", 0 }, /* Earlier WoA TLMM firmware ID */\n\t{ }\n};\n''',
    )
    new_match = '''static const struct acpi_device_id x1e80100_pinctrl_acpi_match[] = {\n\t{ "QCOM0C0C", 0 }, /* UX3407RA GIO0 _HID */\n\t{ "QCOMFFEB", 0 }, /* UX3407RA GIO0 _CID */\n\t{ }\n};\n'''
    if new_match in text:
        print("x1e_gio0_acpi_ids=current")
    else:
        hits = [old for old in old_variants if old in text]
        if len(hits) != 1:
            fail(f"x1e_gio0_acpi_ids: expected one known ACPI match-table form, found {len(hits)}")
        x1.write_text(text.replace(hits[0], new_match, 1))
        print("x1e_gio0_acpi_ids=applied")

    gpio = root / "drivers/gpio/gpiolib-acpi-core.c"
    text = gpio.read_text()

    helper = r'''/* A14_QCOM_WOA_ACPI_GPIO_XLATE
 *
 * Windows-on-ARM Qualcomm firmware can encode PDC-routed GpioInt pins as
 *   virtual_pin = GIO0 _CRS interrupt index * 0x40
 * rather than as literal TLMM GPIO offsets. The controller's Qualcomm PDC
 * _DSM (function 2) returns CIPR tuples { pdc, tlmm_gpio, gsi } which let us
 * recover the physical TLMM GPIO without board-specific pin tables.
 *
 * Keep this in the ACPI GPIO lookup path for the experiment so the registered
 * Qualcomm gpio_chip continues to expose only its normal physical GPIO range.
 */
static const guid_t qcom_woa_pdc_dsm_guid =
	GUID_INIT(0x921b0fd4, 0x567c, 0x43a0,
		  0xbb, 0x14, 0x26, 0x48, 0xf7, 0xb2, 0xa1, 0x8c);

static const struct acpi_device_id qcom_woa_gpio_controller_ids[] = {
	{ "QCOM0C0C", 0 },
	{ "QCOMFFEB", 0 },
	{ }
};

struct qcom_woa_irq_index_ctx {
	unsigned int index;
	u32 gsi;
	bool found;
};

static acpi_status qcom_woa_irq_index_cb(struct acpi_resource *ares, void *context)
{
	struct qcom_woa_irq_index_ctx *ctx = context;
	struct acpi_resource_extended_irq *eirq;
	struct acpi_resource_irq *irq;

	switch (ares->type) {
	case ACPI_RESOURCE_TYPE_IRQ:
		irq = &ares->data.irq;
		if (ctx->index >= irq->interrupt_count) {
			ctx->index -= irq->interrupt_count;
			return AE_OK;
		}
		ctx->gsi = irq->interrupts[ctx->index];
		ctx->found = true;
		return AE_CTRL_TERMINATE;

	case ACPI_RESOURCE_TYPE_EXTENDED_IRQ:
		eirq = &ares->data.extended_irq;
		if (eirq->producer_consumer == ACPI_PRODUCER)
			return AE_OK;
		if (ctx->index >= eirq->interrupt_count) {
			ctx->index -= eirq->interrupt_count;
			return AE_OK;
		}
		ctx->gsi = eirq->interrupts[ctx->index];
		ctx->found = true;
		return AE_CTRL_TERMINATE;
	}

	return AE_OK;
}

static unsigned int qcom_woa_acpi_gpio_xlate(acpi_handle handle,
					     unsigned int pin)
{
	struct qcom_woa_irq_index_ctx ctx = { .index = pin / 0x40 };
	struct acpi_device *adev;
	union acpi_object *cipr;
	unsigned int i;

	/* Direct GPIO numbers coexist with virtual PDC slots in WoA tables. */
	if (pin < 0x100 || pin % 0x40)
		return pin;

	adev = acpi_fetch_acpi_dev(handle);
	if (!adev || !acpi_match_acpi_device(qcom_woa_gpio_controller_ids, adev))
		return pin;

	acpi_walk_resources(handle, METHOD_NAME__CRS, qcom_woa_irq_index_cb, &ctx);
	if (!ctx.found)
		return pin;

	cipr = acpi_evaluate_dsm(handle, &qcom_woa_pdc_dsm_guid, 0, 2, NULL);
	if (!cipr || cipr->type != ACPI_TYPE_PACKAGE)
		goto out;

	for (i = 0; i < cipr->package.count; i++) {
		union acpi_object *tuple = &cipr->package.elements[i];
		u64 mapped;

		if (tuple->type != ACPI_TYPE_PACKAGE || tuple->package.count < 3)
			continue;
		if (tuple->package.elements[1].type != ACPI_TYPE_INTEGER ||
		    tuple->package.elements[2].type != ACPI_TYPE_INTEGER)
			continue;
		if (tuple->package.elements[2].integer.value != ctx.gsi)
			continue;

		mapped = tuple->package.elements[1].integer.value;
		/* Qualcomm TLMMs are far smaller than 16-bit; reject nonsense. */
		if (mapped > 0xffff)
			break;

		pr_info("ACPI: QCOM WoA GPIO: virtual 0x%x -> TLMM GPIO %llu (GSI 0x%x)\n",
			pin, (unsigned long long)mapped, ctx.gsi);
		pin = (unsigned int)mapped;
		break;
	}

out:
	ACPI_FREE(cipr);
	return pin;
}

'''

    if MARKER in text:
        print("qcom_woa_gpio_helper=current")
    else:
        anchor = "struct acpi_gpio_info {\n"
        if text.count(anchor) != 1:
            fail(f"qcom_woa_gpio_helper: expected one insertion anchor, found {text.count(anchor)}")
        text = text.replace(anchor, helper + anchor, 1)
        gpio.write_text(text)
        print("qcom_woa_gpio_helper=applied")

    # If an earlier experiment already inserted the helper with QCOM0C0D in
    # its local controller-ID table, remove only that one A14-invalid entry.
    text = gpio.read_text()
    old_ids = '''static const struct acpi_device_id qcom_woa_gpio_controller_ids[] = {\n\t{ "QCOM0C0C", 0 },\n\t{ "QCOMFFEB", 0 },\n\t{ "QCOM0C0D", 0 },\n\t{ }\n};\n'''
    new_ids = '''static const struct acpi_device_id qcom_woa_gpio_controller_ids[] = {\n\t{ "QCOM0C0C", 0 },\n\t{ "QCOMFFEB", 0 },\n\t{ }\n};\n'''
    if old_ids in text:
        gpio.write_text(text.replace(old_ids, new_ids, 1))
        print("qcom_woa_gpio_ids_drop_ipc0=applied")
    elif new_ids in text:
        print("qcom_woa_gpio_ids_drop_ipc0=current")
    else:
        fail("qcom_woa_gpio_ids_drop_ipc0: expected helper ACPI ID table not found")

    # Pass GpioInt-vs-GpioIo knowledge into acpi_get_gpiod(). Only GpioInt is
    # eligible for virtual-PDC translation.
    replace_once(
        gpio,
        '''static struct gpio_desc *acpi_get_gpiod(char *path, unsigned int pin)\n{\n\tacpi_handle handle;\n\tacpi_status status;\n''',
        '''static struct gpio_desc *acpi_get_gpiod(char *path, unsigned int pin, bool gpioint)\n{\n\tacpi_handle handle;\n\tacpi_status status;\n''',
        "acpi_get_gpiod_gpioint_arg",
    )

    replace_once(
        gpio,
        '''\tstruct gpio_device *gdev __free(gpio_device_put) =\n\t\t\t\tgpio_device_find(handle, acpi_gpiochip_find);\n\tif (!gdev)\n\t\treturn ERR_PTR(-EPROBE_DEFER);\n\n\t/*\n\t * FIXME: keep track of the reference to the GPIO device somehow\n\t * instead of putting it here.\n\t */\n\treturn gpio_device_get_desc(gdev, pin);\n''',
        '''\tstruct gpio_device *gdev __free(gpio_device_put) =\n\t\t\t\tgpio_device_find(handle, acpi_gpiochip_find);\n\tif (!gdev)\n\t\treturn ERR_PTR(-EPROBE_DEFER);\n\n\tif (gpioint)\n\t\tpin = qcom_woa_acpi_gpio_xlate(handle, pin);\n\n\t/*\n\t * FIXME: keep track of the reference to the GPIO device somehow\n\t * instead of putting it here.\n\t */\n\treturn gpio_device_get_desc(gdev, pin);\n''',
        "acpi_get_gpiod_virtual_xlate",
    )

    replace_once(
        gpio,
        '''\t\telse\n\t\t\tdesc = acpi_get_gpiod(agpio->resource_source.string_ptr,\n\t\t\t\t\t      agpio->pin_table[pin_index]);\n''',
        '''\t\telse\n\t\t\tdesc = acpi_get_gpiod(agpio->resource_source.string_ptr,\n\t\t\t\t\t      agpio->pin_table[pin_index], gpioint);\n''',
        "acpi_gpio_lookup_pass_gpioint",
    )

    checks = {
        x1: ["QCOM0C0C", "QCOMFFEB"],
        gpio: [
            MARKER,
            "qcom_woa_pdc_dsm_guid",
            "qcom_woa_irq_index_cb",
            "qcom_woa_acpi_gpio_xlate",
            "virtual 0x%x -> TLMM GPIO",
            "pin_table[pin_index], gpioint",
        ],
    }
    for path, tokens in checks.items():
        body = path.read_text()
        missing = [token for token in tokens if token not in body]
        if missing:
            fail(f"post-transform check failed for {path}: {missing}")

    x1_body = x1.read_text()
    match_table = x1_body.split("x1e80100_pinctrl_acpi_match[]", 1)[1].split("};", 1)[0]
    if "QCOM0C0D" in match_table:
        fail("post-transform check failed: A14 IPC0 HID QCOM0C0D still matches TLMM")

    print(f"{MARKER}=APPLIED")
    print("scope=Qualcomm-WoA-GpioInt-only")
    print("virtual_encoding=crs-irq-index-times-0x40")
    print("mapping_source=QCOM-PDC-DSM-CIPR")
    print("gio0_hid=QCOM0C0C")
    print("gio0_cid=QCOMFFEB")
    print("ipc0_hid=QCOM0C0D")
    print("ipc0_tlmm_match=false")
    print("ordinary_gpioio=unchanged")
    print("fallback=original-pin")


if __name__ == "__main__":
    main()
