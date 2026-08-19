#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Add a narrow QCOM0C36 IORT Named Component pathname fallback.

The A14 firmware IORT names GPU0 as "\\_SB.GPU0". ACPICA's
ACPI_FULL_PATHNAME keeps the four-character NameSeg as "\\_SB_.GPU0", and
Linux IORT does a literal strcmp(). Keep the normal exact match first; only for
QCOM0C36 retry with ACPI_FULL_PATHNAME_NO_TRAILING.

This changes IORT identity matching only. It does not touch GPU MMIO, power,
MSM/Adreno binding, or the already-working GIO0/keyboard/SCM paths.
"""

from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"
MARKER = "A14_IORT_NCOMP_NO_TRAILING_V1"
LOG = "A14IORT: QCOM0C36 normalized path match"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 GPU0 IORT-path transform: {msg}")


def kernel_version(root: Path) -> str:
    vals = {}
    for line in (root / "Makefile").read_text().splitlines():
        for key in ("VERSION", "PATCHLEVEL", "SUBLEVEL"):
            if line.startswith(key + " ="):
                vals[key] = line.split("=", 1)[1].strip()
    try:
        return ".".join(vals[k] for k in ("VERSION", "PATCHLEVEL", "SUBLEVEL"))
    except KeyError as exc:
        fail(f"cannot determine kernel version: {exc}")


def verify(path: Path) -> None:
    body = path.read_text()
    required = [
        MARKER,
        "ACPI_FULL_PATHNAME_NO_TRAILING",
        'acpi_dev_hid_uid_match(adev, "QCOM0C36", NULL)',
        LOG,
    ]
    missing = [x for x in required if x not in body]
    if missing:
        fail(f"verification missing: {missing}")
    if body.count(MARKER) != 1:
        fail(f"expected exactly one {MARKER} marker")


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: apply-a14-full-acpi-gpu0-iort-path.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file():
        fail(f"not a kernel source tree: {root}")
    found = kernel_version(root)
    if found != KERNEL_VERSION:
        fail(f"targets exactly {KERNEL_VERSION}; found {found}")

    path = root / "drivers/acpi/arm64/iort.c"
    if not path.is_file():
        fail(f"missing {path}")

    body = path.read_text()
    if MARKER in body:
        verify(path)
        print("iort_qcom0c36_path_fallback=current")
        print("A14_QCOM0C36_IORT_PATH_V1=APPLIED")
        return

    old = r'''		status = !strcmp(device_name, buf.pointer) ?  AE_OK : AE_NOT_FOUND;
		acpi_os_free(buf.pointer);
'''
    new = r'''		status = !strcmp(device_name, buf.pointer) ?  AE_OK : AE_NOT_FOUND;
		/*
		 * A14_IORT_NCOMP_NO_TRAILING_V1
		 *
		 * The UX3407RA firmware's QCOM0C36 IORT Named Component uses
		 * "\\_SB.GPU0", while ACPICA's ACPI_FULL_PATHNAME preserves the
		 * four-character namespace segment as "\\_SB_.GPU0". Keep the
		 * normal exact IORT match above and, only for QCOM0C36, retry with
		 * ACPICA's explicitly normalized no-trailing-underscore pathname.
		 */
		if (status == AE_NOT_FOUND &&
		    node->type == ACPI_IORT_NODE_NAMED_COMPONENT &&
		    acpi_dev_hid_uid_match(adev, "QCOM0C36", NULL)) {
			struct acpi_buffer normalized = { ACPI_ALLOCATE_BUFFER, NULL };
			acpi_status nstatus;

			nstatus = acpi_get_name(adev->handle,
						ACPI_FULL_PATHNAME_NO_TRAILING,
						&normalized);
			if (ACPI_SUCCESS(nstatus)) {
				if (!strcmp(device_name, normalized.pointer)) {
					dev_info_once(cdev,
						      "A14IORT: QCOM0C36 normalized path match firmware=%s acpi=%s\n",
						      device_name, buf.pointer);
					status = AE_OK;
				}
				acpi_os_free(normalized.pointer);
			}
		}
		acpi_os_free(buf.pointer);
'''

    count = body.count(old)
    if count != 1:
        fail(f"expected one IORT Named Component compare anchor, found {count}")

    path.write_text(body.replace(old, new, 1))
    verify(path)
    print("iort_qcom0c36_path_fallback=applied")
    print("A14_QCOM0C36_IORT_PATH_V1=APPLIED")
    print("exact_iort_match_preserved=true")
    print("fallback_scope=QCOM0C36_named_component_only")
    print("gpu_mmio_access=none")
    print("gpu_power_change=none")


if __name__ == "__main__":
    main()
