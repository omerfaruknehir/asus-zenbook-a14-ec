#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Convert ROOT4 ABD provider-4 tracing into a protocol-level failure shim."""

from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"
ROOT3 = "A14_QCOM_ABD_GSBUS_TRACE_V1"
ROOT4 = "A14_QCOM_ABD_PROVIDER4_TRACE_V2"
ROOT5 = "A14_QCOM_ABD_PROVIDER4_STATUS_SHIM_V3"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 ROOT5 provider4: {msg}")


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
    if ROOT5 in body:
        print("abd_provider4_status_shim=current")
        return
    if ROOT3 not in body or ROOT4 not in body:
        fail("ROOT4 ABD provider-4 trace baseline missing")

    if "#include <linux/string.h>" not in body:
        body = body.replace("#include <linux/slab.h>\n", "#include <linux/slab.h>\n#include <linux/string.h>\n", 1)

    body = body.replace(f"#define {ROOT4} 1\n", f"#define {ROOT4} 1\n#define {ROOT5} 1\n", 1)

    anchor = "static struct qcom_abd *qcom_abd_ctx;\n"
    add = """static struct qcom_abd *qcom_abd_ctx;\n\n#define QCOM_ABD_P4_ACCESS_LEN 66\nstatic u8 qcom_abd_p4_last_write[QCOM_ABD_P4_ACCESS_LEN];\nstatic atomic_t qcom_abd_p4_last_write_valid = ATOMIC_INIT(0);\n"""
    if anchor not in body:
        fail("cannot locate qcom_abd_ctx anchor")
    body = body.replace(anchor, add, 1)

    old = """\tif (gsb && sb->slave_address == 0x0004 &&\n\t    action == ACPI_WRITE && info->access_length == 66) {\n\t\tpr_info(\"A14 ABD P4: write status_before=%#02x len=%u payload_bytes=%u\\n\",\n\t\t\tgsb->status, gsb->len, info->access_length);\n\t\tprint_hex_dump(KERN_INFO, \"A14 ABD P4 TX: \", DUMP_PREFIX_OFFSET,\n\t\t\t\t16, 1, gsb->data, info->access_length, false);\n\t}\n\n\t/* Make failure explicit if AML inspects the GSBUS status byte. */\n"""
    new = """\tif (gsb && sb->slave_address == 0x0004 &&\n\t    info->access_length == QCOM_ABD_P4_ACCESS_LEN) {\n\t\tif (action == ACPI_WRITE) {\n\t\t\tpr_info(\"A14 ABD P4: write-accepted status_before=%#02x len=%u payload_bytes=%u protocol_backend=missing\\n\",\n\t\t\t\tgsb->status, gsb->len, info->access_length);\n\t\t\tmemcpy(qcom_abd_p4_last_write, gsb->data, QCOM_ABD_P4_ACCESS_LEN);\n\t\t\tatomic_set(&qcom_abd_p4_last_write_valid, 1);\n\t\t\tprint_hex_dump(KERN_INFO, \"A14 ABD P4 TX: \", DUMP_PREFIX_OFFSET,\n\t\t\t\t\t16, 1, qcom_abd_p4_last_write, QCOM_ABD_P4_ACCESS_LEN, false);\n\t\t\tgsb->status = 0x00;\n\t\t\tstatus = AE_OK;\n\t\t\tgoto out;\n\t\t}\n\n\t\tif (action == ACPI_READ) {\n\t\t\tpr_info(\"A14 ABD P4: read-status-failure len_before=%u payload_bytes=%u last_write_valid=%d\\n\",\n\t\t\t\tgsb->len, info->access_length, atomic_read(&qcom_abd_p4_last_write_valid));\n\t\t\tif (atomic_read(&qcom_abd_p4_last_write_valid))\n\t\t\t\tprint_hex_dump(KERN_INFO, \"A14 ABD P4 LAST_TX: \", DUMP_PREFIX_OFFSET,\n\t\t\t\t\t16, 1, qcom_abd_p4_last_write, QCOM_ABD_P4_ACCESS_LEN, false);\n\t\t\tmemset(gsb->data, 0, QCOM_ABD_P4_ACCESS_LEN);\n\t\t\tgsb->len = 0;\n\t\t\tgsb->status = 0xff;\n\t\t\tstatus = AE_OK;\n\t\t\tgoto out;\n\t\t}\n\t}\n\n\t/* Make failure explicit if AML inspects the GSBUS status byte. */\n"""
    if old not in body:
        fail("cannot locate ROOT4 provider-4 trace block")
    body = body.replace(old, new, 1)
    path.write_text(body)
    print("abd_provider4_status_shim=applied")


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: apply-a14-acpi-root5-provider4-status.py /path/to/linux-7.1.5")
    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file():
        fail(f"not a kernel source tree: {root}")
    found = version(root)
    if found != KERNEL_VERSION:
        fail(f"targets exactly {KERNEL_VERSION}; found {found}")
    abd = root / "drivers/acpi/arm64/qcom_abd.c"
    if not abd.is_file():
        fail("qcom_abd.c missing; run ROOT4 baseline first")
    patch_abd(abd)
    body = abd.read_text()
    required = (
        ROOT3, ROOT4, ROOT5,
        "QCOM_ABD_P4_ACCESS_LEN 66",
        "write-accepted",
        "read-status-failure",
        "gsb->status = 0xff",
        "status = AE_OK",
        "protocol_backend=missing",
    )
    missing = [x for x in required if x not in body]
    if missing:
        fail(f"post-transform verification missing: {missing}")
    print(f"{ROOT5}=APPLIED")
    print("provider4_write=accepted_and_recorded")
    print("provider4_read=protocol_failure_status_0xff")
    print("provider4_fake_power_data=false")
    print("provider4_acpica_AE_SUPPORT=false_for_provider4")


if __name__ == "__main__":
    main()
