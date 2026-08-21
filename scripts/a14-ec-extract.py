#!/usr/bin/env python3
"""Extract the UX3407RA.313 EC image from an authenticated FMP payload.

The parser is intentionally narrow and fail-closed: it recognizes the exact
FV-image and EC-file GUIDs, LZMA guided-section wrapper, UI name, size, and
SHA-256 observed in UX3407RA.312. It does not modify its input.
"""

from __future__ import annotations

import argparse
import hashlib
import lzma
import struct
import uuid
from pathlib import Path


FV_FILE_GUID = uuid.UUID("9e21fd93-9c72-4c15-8c4b-e77f1db2d792")
EC_FILE_GUID = uuid.UUID("d0472b6a-1710-497b-833a-d9bd3fc11d8b")
LZMA_GUID = uuid.UUID("ee4e5898-3914-4259-9d6e-dc7bd79403cf")
EC_UI = "F0184104.UX3407RA.313"
EC_SIZE = 256 * 1024
EC_SHA256 = "353eb0d125d76a14f15faa72f2153d57e25efd8d212f42b18a9f11c16e3fc39d"


def u24(data: bytes) -> int:
    if len(data) != 3:
        raise ValueError("u24 requires three bytes")
    return int.from_bytes(data, "little")


def offsets(blob: bytes, needle: bytes):
    cursor = 0
    while True:
        found = blob.find(needle, cursor)
        if found < 0:
            return
        yield found
        cursor = found + 1


def ffs_body(blob: bytes, offset: int, label: str) -> bytes:
    if offset + 24 > len(blob):
        raise SystemExit(f"truncated {label} FFS header")
    size = u24(blob[offset + 20 : offset + 23])
    header_size = 24
    if size == 0xFFFFFF:
        if offset + 32 > len(blob):
            raise SystemExit(f"truncated extended {label} FFS header")
        size = struct.unpack_from("<Q", blob, offset + 24)[0]
        header_size = 32
    if size < header_size or offset + size > len(blob):
        raise SystemExit(f"invalid {label} FFS size {size}")
    return blob[offset + header_size : offset + size]


def section_at(blob: bytes, offset: int) -> tuple[int, int, int, bytes]:
    if offset + 4 > len(blob):
        raise SystemExit("truncated section header")
    size = u24(blob[offset : offset + 3])
    kind = blob[offset + 3]
    header_size = 4
    if size == 0xFFFFFF:
        if offset + 8 > len(blob):
            raise SystemExit("truncated extended section header")
        size = struct.unpack_from("<I", blob, offset + 4)[0]
        header_size = 8
    if size < header_size or offset + size > len(blob):
        raise SystemExit(f"invalid section size {size} at {offset:#x}")
    return size, kind, header_size, blob[offset + header_size : offset + size]


def extract_ec(source: bytes) -> tuple[bytes, dict[str, str | int]]:
    fv_candidates = []
    for candidate in offsets(source, FV_FILE_GUID.bytes_le):
        try:
            # File type 0x0b is EFI_FV_FILETYPE_FIRMWARE_VOLUME_IMAGE.
            if source[candidate + 18] != 0x0B:
                continue
            body = ffs_body(source, candidate, "nested-FV")
            size, kind, header, candidate_payload = section_at(body, 0)
            if kind != 0x02 or len(candidate_payload) < 20:
                continue
            definition = uuid.UUID(bytes_le=candidate_payload[:16])
            data_offset, attrs = struct.unpack_from("<HH", candidate_payload, 16)
            if definition != LZMA_GUID or not (header + 20 <= data_offset <= size):
                continue
            fv_candidates.append((candidate, body, size, data_offset, attrs))
        except (IndexError, ValueError, SystemExit):
            continue
    if len(fv_candidates) != 1:
        raise SystemExit(
            f"expected one LZMA nested-FV FFS file, found {len(fv_candidates)}"
        )
    fv_offset, guided_body, section_size, data_offset, attributes = fv_candidates[0]
    compressed = guided_body[data_offset:section_size]
    try:
        expanded = lzma.decompress(compressed, format=lzma.FORMAT_ALONE)
    except lzma.LZMAError as error:
        raise SystemExit(f"LZMA decompression failed: {error}") from error

    ec_candidates = []
    for candidate in offsets(expanded, EC_FILE_GUID.bytes_le):
        try:
            # File type 0x02 is EFI_FV_FILETYPE_FREEFORM.
            if expanded[candidate + 18] != 0x02:
                continue
            body = ffs_body(expanded, candidate, "EC")
            cursor = 0
            candidate_ui = None
            candidate_raw = None
            while cursor + 4 <= len(body):
                size, kind, _header, payload = section_at(body, cursor)
                if kind == 0x15:
                    candidate_ui = payload.decode("utf-16-le", "strict").rstrip("\x00")
                elif kind == 0x19:
                    if candidate_raw is not None:
                        raise ValueError("multiple raw sections")
                    candidate_raw = payload
                cursor = (cursor + size + 3) & ~3
            if candidate_ui == EC_UI and candidate_raw is not None:
                ec_candidates.append((candidate, candidate_ui, candidate_raw))
        except (IndexError, UnicodeDecodeError, ValueError, SystemExit):
            continue
    if len(ec_candidates) != 1:
        raise SystemExit(f"expected one named EC FFS file, found {len(ec_candidates)}")
    ec_offset, ui, raw = ec_candidates[0]
    digest = hashlib.sha256(raw).hexdigest()
    if len(raw) != EC_SIZE or digest != EC_SHA256:
        raise SystemExit(f"EC identity mismatch: size={len(raw)} sha256={digest}")
    return raw, {
        "nested_fv_ffs_offset": fv_offset,
        "guided_attributes": attributes,
        "expanded_size": len(expanded),
        "ec_ffs_offset_in_expanded": ec_offset,
        "ec_ui": ui,
        "ec_size": len(raw),
        "ec_sha256": digest,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Extract the exact UX3407RA.313 EC image from an FMP image"
    )
    parser.add_argument("input", type=Path, help="UX3407RA.312.fmp-image.bin")
    parser.add_argument("output", type=Path, help="output EC image")
    args = parser.parse_args()
    if args.input.resolve() == args.output.resolve():
        raise SystemExit("refusing to overwrite the input")

    source = args.input.read_bytes()
    raw, info = extract_ec(source)
    args.output.write_bytes(raw)
    print(f"source={args.input}")
    print(f"source_sha256={hashlib.sha256(source).hexdigest()}")
    for key, value in info.items():
        if isinstance(value, int):
            print(f"{key}=0x{value:x}" if "offset" in key else f"{key}={value}")
        else:
            print(f"{key}={value}")
    print(f"output={args.output}")
    print("source_modified=NO")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
