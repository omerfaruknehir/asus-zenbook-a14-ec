#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Upgrade the ROOT3 QCOM0427 ABD GSBUS handler to status-preserving trace mode.

ROOT3 deliberately returned AE_SUPPORT, which proved handler ownership but aborted
AML at the first ABD request. ROOT4 follows normal GenericSerialBus handler
semantics instead: return AE_OK and report transaction failure in gsb->status.
This lets AML execute its own error handling without fabricating provider success.
It also emits bounded payload hex dumps for live ABI reconstruction.
"""

from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"
OLD_MARKER = "A14_QCOM_ABD_GSBUS_TRACE_V1"
NEW_MARKER = "A14_QCOM_ABD_GSBUS_TRACE_V2"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 ROOT4 ABD: {msg}")


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


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        fail(f"missing expected anchor for {label}")
    if text.count(old) != 1:
        fail(f"expected exactly one anchor for {label}, found {text.count(old)}")
    return text.replace(old, new, 1)


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: apply-a14-acpi-root4-abd-status-trace.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file():
        fail(f"not a kernel source tree: {root}")
    found = version(root)
    if found != KERNEL_VERSION:
        fail(f"targets exactly {KERNEL_VERSION}; found {found}")

    driver = root / "drivers/acpi/arm64/qcom_abd.c"
    if not driver.is_file():
        fail("ROOT3 qcom_abd.c is missing")

    text = driver.read_text()
    if NEW_MARKER in text:
        print("qcom_abd_status_trace=current")
    else:
        if OLD_MARKER not in text:
            fail("ROOT3 ABD marker missing; expected ROOT3 source baseline")

        text = replace_once(
            text,
            f"#define {OLD_MARKER} 1",
            f"#define {NEW_MARKER} 1\n#define QCOM_ABD_MAX_DUMP_BYTES 96",
            "marker",
        )

        old = '''\tif (!info->connection || !info->length)\n\t\treturn AE_BAD_PARAMETER;\n'''
        new = '''\tif (!info->connection || !info->length || !gsb)\n\t\treturn AE_BAD_PARAMETER;\n'''
        text = replace_once(text, old, new, "value buffer validation")

        old = '''\t/* Make failure explicit if AML inspects the GSBUS status byte. */\n\tif (gsb)\n\t\tgsb->status = 0xff;\n\n\t/* Trace only: provider backends are intentionally not fabricated. */\n\tstatus = AE_SUPPORT;\n'''
        new = '''\t/*\n\t * The AML-visible buffer starts with the GenericSerialBus status/length\n\t * header. Preserve provider failure as data instead of returning an\n\t * ACPICA exception: this mirrors the normal Linux I2C OpRegion model and\n\t * lets AML run its own failure path without pretending the provider worked.\n\t */\n\tif (action == ACPI_WRITE && info->access_length) {\n\t\tsize_t dump_len = min_t(size_t, info->access_length,\n\t\t\t\t\tQCOM_ABD_MAX_DUMP_BYTES);\n\n\t\tprint_hex_dump(KERN_INFO, "A14 ABD payload: ",\n\t\t\t       DUMP_PREFIX_OFFSET, 16, 1, gsb->data,\n\t\t\t       dump_len, false);\n\t}\n\n\tif (action == ACPI_READ) {\n\t\t/* Do not expose stale contents when no provider backend exists. */\n\t\tif (info->access_length)\n\t\t\tmemset(gsb->data, 0, info->access_length);\n\t\tgsb->len = 0;\n\t}\n\n\tgsb->status = 0xff;\n\tstatus = AE_OK;\n'''
        text = replace_once(text, old, new, "status-preserving failure")

        text = replace_once(
            text,
            'pr_info("A14 ABD: QCOM0427 GenericSerialBus handler installed (trace-only)\\n");',
            'pr_info("A14 ABD: QCOM0427 GenericSerialBus handler installed (status-trace)\\n");\n\tpr_info("A14 ABD: unavailable providers return AE_OK with gsb status 0xff; provider success is never fabricated\\n");',
            "install banner",
        )

        driver.write_text(text)
        print("qcom_abd_status_trace=applied")

    body = driver.read_text()
    required = (
        NEW_MARKER,
        "QCOM_ABD_MAX_DUMP_BYTES",
        'print_hex_dump(KERN_INFO, "A14 ABD payload: "',
        "memset(gsb->data, 0, info->access_length)",
        "gsb->status = 0xff",
        "status = AE_OK",
        "provider success is never fabricated",
    )
    missing = [x for x in required if x not in body]
    if missing:
        fail(f"post-transform verification missing: {missing}")
    if "status = AE_SUPPORT" in body:
        fail("old AE_SUPPORT abort path remains")

    print(f"{NEW_MARKER}=APPLIED")
    print("acpi_hid=QCOM0427")
    print("address_space=GenericSerialBus")
    print("handler_return=AE_OK")
    print("transaction_status=0xff")
    print("aml_abort_on_missing_backend=false")
    print("provider_success_fabricated=false")
    print("write_payload_dump_bytes_max=96")


if __name__ == "__main__":
    main()
