#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Extend ROOT4 with the proven qcpmicglink provider-4 write-cache behavior.

This is deliberately a narrow stage:
  - provider 0x0004 RawBytes writes whose first payload byte is 0xff are
    handled exactly like the Windows qcpmicglink8380.sys cache path;
  - the 66-byte cache is zeroed and only min(declared_len + 2, 66) bytes are
    copied, where declared_len is payload byte 1 (Windows uses 66 when it is
    greater than 0x40);
  - the GSB status byte is set to success and AE_OK is returned for that
    proven write form;
  - provider-4 reads are only logged and still return AE_SUPPORT;
  - no PMIC-GLINK packet is sent and SOSI remains read-only.

The exact Windows path was recovered from qcpmicglink8380.sys:
  classifier: first payload byte == 0xff
  cache size: 66 bytes
  copied length: payload[1] > 0x40 ? 66 : payload[1] + 2
The later provider read performs the actual PMIC-GLINK transaction; that is
intentionally left for the next stage.
"""

from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"
ROOT4_V2 = "A14_QCOM_ABD_PROVIDER4_TRACE_V2"
MARKER = "A14_QCOM_ABD_PROVIDER4_CACHE_V3"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 ROOT5 P4 cache: {msg}")


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


def replace_once(text: str, old: str, new: str, what: str) -> str:
    count = text.count(old)
    if count != 1:
        fail(f"{what}: expected exactly one anchor, found {count}")
    return text.replace(old, new, 1)


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: apply-a14-acpi-root5-p4-cache.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file():
        fail(f"not a kernel source tree: {root}")
    found = version(root)
    if found != KERNEL_VERSION:
        fail(f"targets exactly {KERNEL_VERSION}; found {found}")

    abd = root / "drivers/acpi/arm64/qcom_abd.c"
    if not abd.is_file():
        fail("ROOT4 qcom_abd.c missing")

    body = abd.read_text()
    if MARKER in body:
        print("abd_provider4_write_cache=current")
        return
    if ROOT4_V2 not in body:
        fail("ROOT4 provider-4 trace marker missing; apply ROOT4 first")

    # Keep ROOT4's V2 marker so the ROOT4 one-go transformer remains
    # idempotent and does not overwrite this later-stage file.
    define_anchor = f"#define {ROOT4_V2} 1\n"
    body = replace_once(
        body,
        define_anchor,
        define_anchor
        + f"#define {MARKER} 1\n"
        + "#define QCOM_ABD_P4_CACHE_SIZE 66\n",
        "provider4 V3 marker",
    )

    include_anchor = "#include <linux/kernel.h>\n#include <linux/slab.h>\n"
    body = replace_once(
        body,
        include_anchor,
        "#include <linux/kernel.h>\n"
        "#include <linux/mutex.h>\n"
        "#include <linux/slab.h>\n"
        "#include <linux/string.h>\n",
        "mutex/string includes",
    )

    struct_anchor = "\tstruct acpi_connection_info info;\n\tatomic_t requests;\n};\n"
    body = replace_once(
        body,
        struct_anchor,
        "\tstruct acpi_connection_info info;\n"
        "\tatomic_t requests;\n"
        "\tstruct mutex p4_lock;\n"
        "\tu8 p4_cache[QCOM_ABD_P4_CACHE_SIZE];\n"
        "\tu8 p4_cache_len;\n"
        "\tbool p4_cache_valid;\n"
        "};\n",
        "qcom_abd cache fields",
    )

    handler_anchor = "\t/* Make failure explicit if AML inspects the GSBUS status byte. */\n"
    handler_insert = r'''	/*
	 * qcpmicglink8380.sys provider 4 has a special two-phase OEM path.
	 * A write whose first byte is 0xff is not transmitted. Windows zeroes a
	 * 66-byte cache, copies payload[1] + 2 bytes (or all 66 when payload[1]
	 * is > 0x40), and completes the write successfully. The later read is
	 * what performs PMIC-GLINK owner 0x800e / opcode 0x104.
	 *
	 * Reproduce only that proven cache stage here. Reads remain explicit
	 * AE_SUPPORT until the Linux PMIC-GLINK transport is wired up.
	 */
	if (gsb && sb->slave_address == 0x0004) {
		if (action == ACPI_WRITE && info->access_length == QCOM_ABD_P4_CACHE_SIZE &&
		    gsb->data[0] == 0xff) {
			u8 declared = gsb->data[1];
			u8 copy_len = declared > 0x40 ? QCOM_ABD_P4_CACHE_SIZE : declared + 2;

			mutex_lock(&abd->p4_lock);
			memset(abd->p4_cache, 0, sizeof(abd->p4_cache));
			memcpy(abd->p4_cache, gsb->data, copy_len);
			abd->p4_cache_len = copy_len;
			abd->p4_cache_valid = true;
			mutex_unlock(&abd->p4_lock);

			gsb->status = 0x00;
			pr_info("A14 ABD P4 CACHE: windows-deferred write accepted declared=%u copy_len=%u cache_size=%u status=0\n",
				declared, copy_len, QCOM_ABD_P4_CACHE_SIZE);
			print_hex_dump(KERN_INFO, "A14 ABD P4 CACHE DATA: ", DUMP_PREFIX_OFFSET,
					16, 1, abd->p4_cache, sizeof(abd->p4_cache), false);
			status = AE_OK;
			goto out;
		}

		if (action == ACPI_READ) {
			mutex_lock(&abd->p4_lock);
			pr_info("A14 ABD P4 READ-DEFERRED: access_len=%u cache_valid=%u cached_len=%u backend=AE_SUPPORT\n",
				info->access_length, abd->p4_cache_valid, abd->p4_cache_len);
			if (abd->p4_cache_valid)
				print_hex_dump(KERN_INFO, "A14 ABD P4 READ CACHED TX: ",
						DUMP_PREFIX_OFFSET, 16, 1, abd->p4_cache,
						sizeof(abd->p4_cache), false);
			mutex_unlock(&abd->p4_lock);
		}
	}

	/* Make failure explicit if AML inspects the GSBUS status byte. */
'''
    body = replace_once(body, handler_anchor, handler_insert, "provider4 cache handler")

    init_anchor = "\tatomic_set(&abd->requests, 0);\n"
    body = replace_once(
        body,
        init_anchor,
        init_anchor + "\tmutex_init(&abd->p4_lock);\n",
        "provider4 cache mutex init",
    )

    abd.write_text(body)

    verify = abd.read_text()
    required = (
        ROOT4_V2,
        MARKER,
        "QCOM_ABD_P4_CACHE_SIZE 66",
        "gsb->data[0] == 0xff",
        "declared > 0x40 ? QCOM_ABD_P4_CACHE_SIZE : declared + 2",
        "A14 ABD P4 CACHE:",
        "A14 ABD P4 READ-DEFERRED:",
        "gsb->status = 0x00",
        "status = AE_OK",
        "status = AE_SUPPORT",
    )
    missing = [item for item in required if item not in verify]
    if missing:
        fail(f"post-transform verification missing: {missing}")

    print("abd_provider4_write_cache=applied")
    print(f"{MARKER}=APPLIED")
    print("provider4_write_ff=windows_cache_semantics")
    print("provider4_cache_size=66")
    print("provider4_read=trace_then_AE_SUPPORT")
    print("pmic_glink_tx=false")
    print("fabricated_provider_data=false")
    print("sosi_writes=0")


if __name__ == "__main__":
    main()
