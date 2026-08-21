#!/usr/bin/env python3
"""Validate and extract an authenticated UEFI FMP firmware payload.

This is intentionally read-only with respect to the source capsule.  It
supports the single-payload, version-3 FMP capsule used by UX3407RA BIOS 312
and refuses dependency sections or ambiguous multi-payload capsules.
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import struct
import sys
import uuid


FMP_CAPSULE_GUID = uuid.UUID("6dcbd5ed-e82d-4c44-bda1-7194199ad92a")
PKCS7_CERT_GUID = uuid.UUID("4aafd29d-68df-49ee-8aa9-347d375665a7")
CAPSULE_HEADER = struct.Struct("<16sIII")
FMP_HEADER = struct.Struct("<IHH")
FMP_IMAGE_HEADER_V3 = struct.Struct("<I16sB3xIIQQ")
AUTH_PREFIX = struct.Struct("<QIHH16s")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def guid_le(data: bytes) -> uuid.UUID:
    return uuid.UUID(bytes_le=data)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def find_offsets(data: bytes, needle: bytes, limit: int = 32) -> list[int]:
    offsets: list[int] = []
    start = 0
    while len(offsets) < limit:
        offset = data.find(needle, start)
        if offset < 0:
            break
        offsets.append(offset)
        start = offset + 1
    return offsets


def extract(capsule: bytes) -> tuple[bytes, dict[str, str]]:
    require(len(capsule) >= CAPSULE_HEADER.size, "truncated EFI capsule header")
    capsule_guid_raw, header_size, flags, capsule_size = CAPSULE_HEADER.unpack_from(
        capsule, 0
    )
    capsule_guid = guid_le(capsule_guid_raw)
    require(capsule_guid == FMP_CAPSULE_GUID, f"not an FMP capsule: {capsule_guid}")
    require(
        header_size >= CAPSULE_HEADER.size and header_size <= len(capsule),
        f"invalid capsule header size: {header_size}",
    )
    require(
        capsule_size == len(capsule),
        f"capsule size mismatch: header={capsule_size} file={len(capsule)}",
    )

    fmp_base = header_size
    require(
        fmp_base + FMP_HEADER.size <= len(capsule),
        "truncated FMP capsule header",
    )
    fmp_version, driver_count, payload_count = FMP_HEADER.unpack_from(
        capsule, fmp_base
    )
    require(fmp_version == 1, f"unsupported FMP capsule version: {fmp_version}")
    require(driver_count == 0, f"embedded drivers are not supported: {driver_count}")
    require(payload_count == 1, f"expected one firmware payload: {payload_count}")

    offset_count = driver_count + payload_count
    offset_table = fmp_base + FMP_HEADER.size
    require(
        offset_table + offset_count * 8 <= len(capsule),
        "truncated FMP item-offset table",
    )
    item_offset = struct.unpack_from("<Q", capsule, offset_table)[0]
    image_header = fmp_base + item_offset
    require(
        image_header + FMP_IMAGE_HEADER_V3.size <= len(capsule),
        "truncated FMP image header",
    )

    (
        image_version,
        image_type_raw,
        image_index,
        update_image_size,
        vendor_code_size,
        hardware_instance,
        image_capsule_support,
    ) = FMP_IMAGE_HEADER_V3.unpack_from(capsule, image_header)
    require(image_version == 3, f"unsupported FMP image-header version: {image_version}")
    require(vendor_code_size == 0, f"unexpected vendor-code bytes: {vendor_code_size}")
    require(
        image_capsule_support & ~0x1 == 0,
        "dependency or unknown image-capsule sections are not supported",
    )

    update_start = image_header + FMP_IMAGE_HEADER_V3.size
    update_end = update_start + update_image_size
    require(update_end <= len(capsule), "declared update image extends past capsule")

    firmware_start = update_start
    monotonic_count = 0
    cert_length = 0
    cert_guid = None
    if image_capsule_support & 0x1:
        require(
            update_start + AUTH_PREFIX.size <= update_end,
            "truncated firmware authentication header",
        )
        (
            monotonic_count,
            cert_length,
            cert_revision,
            cert_type,
            cert_guid_raw,
        ) = AUTH_PREFIX.unpack_from(capsule, update_start)
        cert_guid = guid_le(cert_guid_raw)
        require(cert_length >= 24, f"invalid WIN_CERTIFICATE length: {cert_length}")
        require(cert_revision == 0x0200, f"unexpected certificate revision: {cert_revision:#x}")
        require(cert_type == 0x0EF1, f"unexpected certificate type: {cert_type:#x}")
        require(cert_guid == PKCS7_CERT_GUID, f"unexpected certificate GUID: {cert_guid}")
        firmware_start = update_start + 8 + cert_length
        require(firmware_start <= update_end, "certificate extends past update image")

    firmware = capsule[firmware_start:update_end]
    require(firmware, "empty extracted firmware image")
    metadata = {
        "capsule_guid": str(capsule_guid),
        "capsule_header_size": str(header_size),
        "capsule_flags": f"0x{flags:08x}",
        "capsule_size": str(capsule_size),
        "fmp_version": str(fmp_version),
        "payload_item_offset": f"0x{item_offset:x}",
        "image_header_offset": f"0x{image_header:x}",
        "image_type_guid": str(guid_le(image_type_raw)),
        "image_index": str(image_index),
        "update_image_size": str(update_image_size),
        "hardware_instance": str(hardware_instance),
        "image_capsule_support": f"0x{image_capsule_support:x}",
        "monotonic_count": str(monotonic_count),
        "certificate_length": str(cert_length),
        "certificate_guid": str(cert_guid) if cert_guid else "none",
        "firmware_offset": f"0x{firmware_start:x}",
        "firmware_size": str(len(firmware)),
    }
    return firmware, metadata


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("capsule", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    try:
        capsule = args.capsule.read_bytes()
        firmware, metadata = extract(capsule)
        if args.output.exists() and not args.force:
            raise ValueError(f"output already exists (use --force): {args.output}")
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(firmware)
    except (OSError, ValueError) as error:
        print(f"ERROR={error}", file=sys.stderr)
        return 1

    print(f"source={args.capsule}")
    print(f"source_sha256={sha256(capsule)}")
    for key, value in metadata.items():
        print(f"{key}={value}")
    print(f"output={args.output}")
    print(f"output_sha256={sha256(firmware)}")

    signatures = {
        "uefi_fv_header": b"_FVH",
        "elf": b"\x7fELF",
        "zip": b"PK\x03\x04",
        "qtec_ascii": b"QTEC",
        "asus_identity": b"ASUS Tech.Inc.",
        "known_backlight_report": bytes.fromhex("5a ba c5 c4"),
    }
    for name, signature in signatures.items():
        offsets = find_offsets(firmware, signature)
        rendered = ",".join(f"0x{offset:x}" for offset in offsets) or "none"
        print(f"signature_{name}={rendered}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
