#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Extend ROOT3 with provider-4 payload tracing and a read-only SOSI probe."""

from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"
ABD_V1 = "A14_QCOM_ABD_GSBUS_TRACE_V1"
ABD_V2 = "A14_QCOM_ABD_PROVIDER4_TRACE_V2"
SOSI_MARKER = "A14_QCOM_SOSI_READONLY_PROBE_V2"

SOSI_DRIVER = r'''// SPDX-License-Identifier: GPL-2.0-only
/*
 * Qualcomm WoA SOSI shared-structure read-only probe.
 *
 * The firmware publishes the physical address through the ACPI integer
 * object \\_SB.SOSI. Qualcomm's Windows qcabd.sys discovers the same value
 * from the DSDT, initially maps 0xb8 bytes, reads two DWORD counts at 0x9c
 * and 0xa4, then remaps 0xb8 + 4 * (count_a + count_b) bytes.
 *
 * This diagnostic follows that sizing algorithm but never writes the mapped
 * range and never treats any field as a provider backend until its semantics
 * are independently proven. It classifies each requested physical range
 * against Linux's System RAM resource tree before mapping it, avoiding an
 * uncached ioremap alias over ordinary RAM.
 */

#include <linux/acpi.h>
#include <linux/byteorder/generic.h>
#include <linux/init.h>
#include <linux/io.h>
#include <linux/ioport.h>
#include <linux/kernel.h>
#include <linux/mm.h>
#include <linux/printk.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/types.h>

#define A14_QCOM_SOSI_READONLY_PROBE_V1 1
#define A14_QCOM_SOSI_READONLY_PROBE_V2 1
#define QCOM_SOSI_HEADER_SIZE 0xb8
#define QCOM_SOSI_MAX_SIZE    0x4000
#define QCOM_SOSI_DUMP_LIMIT  0x100

static u32 qcom_sosi_get_le32(const u8 *p)
{
	__le32 value;

	memcpy(&value, p, sizeof(value));
	return le32_to_cpu(value);
}

static int qcom_sosi_copy_phys(phys_addr_t phys, size_t size, void *dst,
			       const char *phase)
{
	int ram_state;
	void *ram_mapping;
	void __iomem *io_mapping;

	ram_state = region_intersects((resource_size_t)phys, size,
				      IORESOURCE_SYSTEM_RAM, IORES_DESC_NONE);

	switch (ram_state) {
	case REGION_INTERSECTS:
		ram_mapping = memremap(phys, size, MEMREMAP_WB);
		if (!ram_mapping) {
			pr_err("A14 SOSI: %s memremap-wb failed phys=%pa size=%#zx\n",
				phase, &phys, size);
			return -ENOMEM;
		}
		memcpy(dst, ram_mapping, size);
		memunmap(ram_mapping);
		pr_info("A14 SOSI: %s mapping=memremap-wb system_ram=true size=%#zx writes=0\n",
			phase, size);
		return 0;

	case REGION_DISJOINT:
		io_mapping = ioremap(phys, size);
		if (!io_mapping) {
			pr_err("A14 SOSI: %s ioremap failed phys=%pa size=%#zx\n",
				phase, &phys, size);
			return -ENOMEM;
		}
		memcpy_fromio(dst, io_mapping, size);
		iounmap(io_mapping);
		pr_info("A14 SOSI: %s mapping=ioremap system_ram=false size=%#zx writes=0\n",
			phase, size);
		return 0;

	case REGION_MIXED:
	default:
		pr_err("A14 SOSI: %s mapping refused: mixed/unknown System RAM classification=%d phys=%pa size=%#zx\n",
			phase, ram_state, &phys, size);
		return -EINVAL;
	}
}

static void qcom_sosi_log_fields(const u8 *h)
{
	pr_info("A14 SOSI: f00=%#010x f04=%#010x f08=%#010x f2c=%#010x f30=%#010x\n",
		qcom_sosi_get_le32(h + 0x00), qcom_sosi_get_le32(h + 0x04),
		qcom_sosi_get_le32(h + 0x08), qcom_sosi_get_le32(h + 0x2c),
		qcom_sosi_get_le32(h + 0x30));
	pr_info("A14 SOSI: f5c=%#010x f60=%#010x f6c=%#010x f70=%#010x f74=%#010x f78=%#010x\n",
		qcom_sosi_get_le32(h + 0x5c), qcom_sosi_get_le32(h + 0x60),
		qcom_sosi_get_le32(h + 0x6c), qcom_sosi_get_le32(h + 0x70),
		qcom_sosi_get_le32(h + 0x74), qcom_sosi_get_le32(h + 0x78));
	pr_info("A14 SOSI: count_a_dwords=%u count_b_dwords=%u offset_b=%#x fB0=%#010x fB4=%#010x\n",
		qcom_sosi_get_le32(h + 0x9c), qcom_sosi_get_le32(h + 0xa4),
		qcom_sosi_get_le32(h + 0xa8), qcom_sosi_get_le32(h + 0xb0),
		qcom_sosi_get_le32(h + 0xb4));
	print_hex_dump(KERN_INFO, "A14 SOSI inline7c: ", DUMP_PREFIX_OFFSET,
			16, 1, h + 0x7c, 0x20, false);
}

static int __init qcom_sosi_probe_init(void)
{
	unsigned long long firmware_addr = 0;
	phys_addr_t phys;
	u8 header[QCOM_SOSI_HEADER_SIZE];
	u8 *full = NULL;
	u32 count_a, count_b, offset_b;
	u64 total64;
	size_t total, len;
	acpi_status status;
	int ret;

	if (acpi_disabled)
		return 0;

	status = acpi_evaluate_integer(NULL, "\\_SB.SOSI", NULL,
				       &firmware_addr);
	if (ACPI_FAILURE(status)) {
		pr_err("A14 SOSI: ACPI evaluate \\_SB.SOSI failed: %s\n",
			acpi_format_exception(status));
		return 0;
	}
	if (!firmware_addr) {
		pr_err("A14 SOSI: ACPI \\_SB.SOSI returned zero\n");
		return 0;
	}

	phys = (phys_addr_t)firmware_addr;
	if ((u64)phys != (u64)firmware_addr) {
		pr_err("A14 SOSI: physical address does not fit phys_addr_t: %#llx\n",
			firmware_addr);
		return 0;
	}

	pr_info("A14 SOSI: ACPI \\_SB.SOSI=%#llx read_only=true\n",
		firmware_addr);

	ret = qcom_sosi_copy_phys(phys, sizeof(header), header, "header");
	if (ret)
		return 0;

	pr_info("A14 SOSI: header mapped size=%#x writes=0\n",
		QCOM_SOSI_HEADER_SIZE);
	qcom_sosi_log_fields(header);
	print_hex_dump(KERN_INFO, "A14 SOSI hdr: ", DUMP_PREFIX_OFFSET,
			16, 1, header, sizeof(header), false);

	count_a = qcom_sosi_get_le32(header + 0x9c);
	count_b = qcom_sosi_get_le32(header + 0xa4);
	offset_b = qcom_sosi_get_le32(header + 0xa8);
	total64 = (u64)QCOM_SOSI_HEADER_SIZE +
		  4ULL * (u64)count_a + 4ULL * (u64)count_b;

	if (total64 < QCOM_SOSI_HEADER_SIZE || total64 > QCOM_SOSI_MAX_SIZE) {
		pr_err("A14 SOSI: derived size rejected total=%#llx cap=%#x count_a=%u count_b=%u\n",
			(unsigned long long)total64, QCOM_SOSI_MAX_SIZE, count_a, count_b);
		return 0;
	}

	total = (size_t)total64;
	pr_info("A14 SOSI: derived size accepted total=%#zx formula=0xb8+4*(%u+%u)\n",
		total, count_a, count_b);

	full = kzalloc(total, GFP_KERNEL);
	if (!full) {
		pr_err("A14 SOSI: allocation failed size=%#zx\n", total);
		return 0;
	}

	ret = qcom_sosi_copy_phys(phys, total, full, "full");
	if (ret)
		goto out;
	pr_info("A14 SOSI: full map copied size=%#zx writes=0\n", total);

	if (count_a && total > QCOM_SOSI_HEADER_SIZE) {
		len = min_t(size_t, 4ULL * (u64)count_a,
			    total - QCOM_SOSI_HEADER_SIZE);
		len = min_t(size_t, len, QCOM_SOSI_DUMP_LIMIT);
		print_hex_dump(KERN_INFO, "A14 SOSI blockA: ", DUMP_PREFIX_OFFSET,
				16, 1, full + QCOM_SOSI_HEADER_SIZE, len, false);
	}

	if (count_b && offset_b < total) {
		len = min_t(size_t, 4ULL * (u64)count_b, total - offset_b);
		len = min_t(size_t, len, QCOM_SOSI_DUMP_LIMIT);
		print_hex_dump(KERN_INFO, "A14 SOSI blockB: ", DUMP_PREFIX_OFFSET,
				16, 1, full + offset_b, len, false);
	} else if (count_b) {
		pr_warn("A14 SOSI: blockB offset outside mapped structure offset=%#x total=%#zx\n",
			offset_b, total);
	}

out:
	kfree(full);
	return 0;
}
subsys_initcall_sync(qcom_sosi_probe_init);
'''


def fail(msg: str) -> None:
    raise SystemExit(f"A14 ROOT4 SOSI: {msg}")


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


def patch_abd(path: Path) -> None:
    body = path.read_text()
    if ABD_V2 in body:
        print("abd_provider4_payload_trace=current")
        return
    if ABD_V1 not in body:
        fail("ROOT3 ABD V1 marker missing")

    marker = "#define A14_QCOM_ABD_GSBUS_TRACE_V1 1\n"
    body = body.replace(marker, marker + f"#define {ABD_V2} 1\n", 1)

    anchor = '''\t} else if (request == QCOM_ABD_MAX_TRACE_REQUESTS + 1) {\n\t\tpr_info("A14 ABD: further requests suppressed after %u entries\\n",\n\t\t\tQCOM_ABD_MAX_TRACE_REQUESTS);\n\t}\n\n\t/* Make failure explicit if AML inspects the GSBUS status byte. */\n'''
    insert = '''\t} else if (request == QCOM_ABD_MAX_TRACE_REQUESTS + 1) {\n\t\tpr_info("A14 ABD: further requests suppressed after %u entries\\n",\n\t\t\tQCOM_ABD_MAX_TRACE_REQUESTS);\n\t}\n\n\tif (gsb && sb->slave_address == 0x0004 &&\n\t    action == ACPI_WRITE && info->access_length == 66) {\n\t\tpr_info("A14 ABD P4: write status_before=%#02x len=%u payload_bytes=%u\\n",\n\t\t\tgsb->status, gsb->len, info->access_length);\n\t\tprint_hex_dump(KERN_INFO, "A14 ABD P4 TX: ", DUMP_PREFIX_OFFSET,\n\t\t\t\t16, 1, gsb->data, info->access_length, false);\n\t}\n\n\t/* Make failure explicit if AML inspects the GSBUS status byte. */\n'''
    if anchor not in body:
        fail("cannot locate ROOT3 ABD request trace anchor")
    body = body.replace(anchor, insert, 1)
    path.write_text(body)
    print("abd_provider4_payload_trace=applied")


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: apply-a14-acpi-root4-sosi.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file():
        fail(f"not a kernel source tree: {root}")
    found = version(root)
    if found != KERNEL_VERSION:
        fail(f"targets exactly {KERNEL_VERSION}; found {found}")

    arm64 = root / "drivers/acpi/arm64"
    makefile = arm64 / "Makefile"
    abd = arm64 / "qcom_abd.c"
    sosi = arm64 / "qcom_sosi_probe.c"
    if not abd.is_file():
        fail("ROOT3 qcom_abd.c missing")
    if not makefile.is_file():
        fail(f"missing {makefile}")

    patch_abd(abd)

    if sosi.exists() and SOSI_MARKER in sosi.read_text():
        print("qcom_sosi_probe=current")
    else:
        sosi.write_text(SOSI_DRIVER)
        print("qcom_sosi_probe=applied")

    m = makefile.read_text()
    if "qcom_sosi_probe.o" not in m:
        if not m.endswith("\n"):
            m += "\n"
        m += "obj-y\t\t\t\t+= qcom_sosi_probe.o\n"
        makefile.write_text(m)
        print("qcom_sosi_makefile=applied")
    else:
        print("qcom_sosi_makefile=current")

    abd_body = abd.read_text()
    sosi_body = sosi.read_text()
    required_abd = (ABD_V1, ABD_V2, "A14 ABD P4 TX:", "status = AE_SUPPORT")
    required_sosi = (
        "A14_QCOM_SOSI_READONLY_PROBE_V1",
        SOSI_MARKER,
        "acpi_evaluate_integer(NULL",
        "_SB.SOSI",
        "region_intersects((resource_size_t)phys, size",
        "IORESOURCE_SYSTEM_RAM",
        "REGION_INTERSECTS",
        "REGION_DISJOINT",
        "REGION_MIXED",
        "memremap(phys, size, MEMREMAP_WB)",
        "memcpy_fromio(dst",
        "QCOM_SOSI_MAX_SIZE",
        "count_a = qcom_sosi_get_le32(header + 0x9c)",
        "count_b = qcom_sosi_get_le32(header + 0xa4)",
        "offset_b = qcom_sosi_get_le32(header + 0xa8)",
        "mapping=memremap-wb",
        "mapping=ioremap",
        "writes=0",
    )
    missing = [x for x in required_abd if x not in abd_body]
    if missing:
        fail(f"ABD verification missing: {missing}")
    missing = [x for x in required_sosi if x not in sosi_body]
    if missing:
        fail(f"SOSI verification missing: {missing}")
    if "qcom_sosi_probe.o" not in makefile.read_text():
        fail("Makefile did not retain qcom_sosi_probe.o")

    print(f"{ABD_V2}=APPLIED")
    print(f"{SOSI_MARKER}=APPLIED")
    print("sosi_address_source=ACPI_\\_SB.SOSI")
    print("sosi_header_size=0xb8")
    print("sosi_derived_size_cap=0x4000")
    print("sosi_mapping_policy=SystemRAM_memremapWB__nonRAM_ioremap__mixed_refuse")
    print("sosi_writes=false")
    print("provider4_backend=still_trace_only_AE_SUPPORT")


if __name__ == "__main__":
    main()
