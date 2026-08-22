#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Add a trace-only Qualcomm ACPI Bridge Device (QCOM0427) GSBUS handler.

This targets Linux 7.1.5 and the factory ACPI ABI used by Qualcomm WoA.
The handler is intentionally trace-only: it decodes the GenericSerialBus
Connection() descriptor and logs the logical provider ID, but returns
AE_SUPPORT instead of fabricating provider data.
"""

from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"
MARKER = "A14_QCOM_ABD_GSBUS_TRACE_V1"

DRIVER = r'''// SPDX-License-Identifier: GPL-2.0-only
/*
 * Qualcomm ACPI Bridge Device (ABD) trace-only GenericSerialBus handler.
 *
 * QCOM0427 is the Qualcomm ACPI Bridge Device used by Windows on WoA.
 * Firmware exposes GenericSerialBus OperationRegions whose Connection()
 * descriptors point back to the ABD device with logical provider IDs.
 *
 * This first-stage Linux implementation deliberately does not emulate any
 * provider. It installs the correct ACPICA address-space handler boundary,
 * decodes every live Connection() descriptor and logs the provider ID and
 * access shape, then returns AE_SUPPORT. That is safer than inventing RTC,
 * power or other provider data while the provider ABI is still being mapped.
 */

#include <linux/acpi.h>
#include <linux/atomic.h>
#include <linux/init.h>
#include <linux/errno.h>
#include <linux/kernel.h>
#include <linux/slab.h>

#define A14_QCOM_ABD_GSBUS_TRACE_V1 1
#define QCOM_ABD_MAX_TRACE_REQUESTS 128

struct qcom_abd {
	/* ACPICA populates this by treating handler_context as this type. */
	struct acpi_connection_info info;
	atomic_t requests;
};

struct qcom_abd_gsb_buffer {
	u8 status;
	u8 len;
	union {
		u16 wdata;
		u8 bdata;
		DECLARE_FLEX_ARRAY(u8, data);
	};
} __packed;

static struct qcom_abd *qcom_abd_ctx;

static acpi_status qcom_abd_space_handler(u32 function,
					 acpi_physical_address command,
					 u32 bits, u64 *value64,
					 void *handler_context,
					 void *region_context)
{
	struct qcom_abd *abd = handler_context;
	struct qcom_abd_gsb_buffer *gsb = (void *)value64;
	struct acpi_connection_info *info = &abd->info;
	struct acpi_resource_i2c_serialbus *sb;
	struct acpi_resource *ares = NULL;
	u32 accessor = function >> 16;
	u8 action = function & ACPI_IO_MASK;
	unsigned int request;
	acpi_status status;

	if (!info->connection || !info->length)
		return AE_BAD_PARAMETER;

	status = acpi_buffer_to_resource(info->connection, info->length, &ares);
	if (ACPI_FAILURE(status))
		return status;

	if (ares->type != ACPI_RESOURCE_TYPE_SERIAL_BUS) {
		status = AE_BAD_PARAMETER;
		goto out;
	}

	sb = &ares->data.i2c_serial_bus;
	if (sb->type != ACPI_RESOURCE_SERIAL_TYPE_I2C) {
		status = AE_BAD_PARAMETER;
		goto out;
	}

	request = atomic_inc_return(&abd->requests);
	if (request <= QCOM_ABD_MAX_TRACE_REQUESTS) {
		pr_info("A14 ABD: request=%u provider=0x%04x action=%s accessor=0x%x command=0x%llx bits=%u access_len=%u speed=%u\n",
			request, sb->slave_address,
			action == ACPI_READ ? "read" : "write",
			accessor, (unsigned long long)command, bits,
			info->access_length, sb->connection_speed);
	} else if (request == QCOM_ABD_MAX_TRACE_REQUESTS + 1) {
		pr_info("A14 ABD: further requests suppressed after %u entries\n",
			QCOM_ABD_MAX_TRACE_REQUESTS);
	}

	/* Make failure explicit if AML inspects the GSBUS status byte. */
	if (gsb)
		gsb->status = 0xff;

	/* Trace only: provider backends are intentionally not fabricated. */
	status = AE_SUPPORT;

out:
	ACPI_FREE(ares);
	return status;
}

static acpi_status qcom_abd_install_one(acpi_handle handle, u32 level,
					void *context, void **return_value)
{
	struct qcom_abd *abd;
	acpi_status status;

	if (qcom_abd_ctx)
		return AE_OK;

	abd = kzalloc(sizeof(*abd), GFP_KERNEL);
	if (!abd)
		return AE_NO_MEMORY;

	atomic_set(&abd->requests, 0);

	status = acpi_install_address_space_handler(handle,
			ACPI_ADR_SPACE_GSBUS,
			qcom_abd_space_handler,
			NULL, abd);
	if (ACPI_FAILURE(status)) {
		pr_err("A14 ABD: failed to install QCOM0427 GSBUS handler: %s\n",
			acpi_format_exception(status));
		kfree(abd);
		return status;
	}

	qcom_abd_ctx = abd;
	pr_info("A14 ABD: QCOM0427 GenericSerialBus handler installed (trace-only)\n");
	return AE_OK;
}

static int __init qcom_abd_init(void)
{
	acpi_status status;

	if (acpi_disabled)
		return 0;

	/*
	 * Run after normal ACPI subsystem init but before device_initcall I2C
	 * controller bring-up. This avoids depending on platform-device creation
	 * order and installs the handler before dependent _REG methods execute.
	 */
	status = acpi_get_devices("QCOM0427", qcom_abd_install_one,
				  NULL, NULL);
	if (ACPI_FAILURE(status) && status != AE_NOT_FOUND) {
		pr_err("A14 ABD: QCOM0427 enumeration failed: %s\n",
			acpi_format_exception(status));
		return -ENODEV;
	}

	if (!qcom_abd_ctx) {
		pr_info("A14 ABD: QCOM0427 not present\n");
		return 0;
	}

	return 0;
}
subsys_initcall_sync(qcom_abd_init);
'''


def fail(msg: str) -> None:
    raise SystemExit(f"A14 ROOT3 ABD: {msg}")


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


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: apply-a14-acpi-root3-abd.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file():
        fail(f"not a kernel source tree: {root}")
    found = version(root)
    if found != KERNEL_VERSION:
        fail(f"targets exactly {KERNEL_VERSION}; found {found}")

    makefile = root / "drivers/acpi/arm64/Makefile"
    driver = root / "drivers/acpi/arm64/qcom_abd.c"
    if not makefile.is_file():
        fail(f"missing {makefile}")

    existing = driver.read_text() if driver.exists() else ""
    if MARKER in existing:
        print("qcom_abd_driver=current")
    else:
        driver.write_text(DRIVER)
        print("qcom_abd_driver=applied")

    m = makefile.read_text()
    line = "obj-y\t\t\t\t+= qcom_abd.o\n"
    if "qcom_abd.o" not in m:
        if not m.endswith("\n"):
            m += "\n"
        m += line
        makefile.write_text(m)
        print("qcom_abd_makefile=applied")
    else:
        print("qcom_abd_makefile=current")

    body = driver.read_text()
    required = (
        MARKER,
        'acpi_get_devices("QCOM0427"',
        "ACPI_ADR_SPACE_GSBUS",
        "acpi_buffer_to_resource",
        "sb->slave_address",
        "A14 ABD: request=",
        "status = AE_SUPPORT",
        "subsys_initcall_sync(qcom_abd_init)",
    )
    missing = [x for x in required if x not in body]
    if missing:
        fail(f"post-transform verification missing: {missing}")
    if "qcom_abd.o" not in makefile.read_text():
        fail("Makefile did not retain qcom_abd.o")

    print(f"{MARKER}=APPLIED")
    print("acpi_hid=QCOM0427")
    print("address_space=GenericSerialBus")
    print("provider_id_source=Connection_I2cSerialBus_slave_address")
    print("backend=trace_only_AE_SUPPORT")
    print("fabricated_provider_data=false")


if __name__ == "__main__":
    main()
