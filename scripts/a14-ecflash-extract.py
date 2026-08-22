#!/usr/bin/env python3
"""Extract ASUS ECFlashApp from the UX3407RA FMP image without 7-Zip."""

from __future__ import annotations

import argparse
import hashlib
import lzma
import struct
import uuid
from pathlib import Path


FV_FILE_GUID = uuid.UUID("9e21fd93-9c72-4c15-8c4b-e77f1db2d792")
ECFLASH_GUID = uuid.UUID("484523a5-6a18-463f-ea1d-de3d740abad5")
LZMA_GUID = uuid.UUID("ee4e5898-3914-4259-9d6e-dc7bd79403cf")
EXPECTED_UI = "ECFlashApp"
EXPECTED_SIZE = 307200
EXPECTED_SHA256 = "1d245aa84b9e3f209d46d7b317ca3719dab47ad8549f7b8d0d86ce62579f97ed"


def u24(data: bytes) -> int:
    return int.from_bytes(data, "little")


def offsets(blob: bytes, needle: bytes):
    cursor = 0
    while True:
        found = blob.find(needle, cursor)
        if found < 0:
            return
        yield found
        cursor = found + 1


def ffs_body(blob: bytes, offset: int) -> bytes:
    if offset + 24 > len(blob):
        raise ValueError("truncated FFS header")
    size = u24(blob[offset + 20 : offset + 23])
    header = 24
    if size == 0xFFFFFF:
        if offset + 32 > len(blob):
            raise ValueError("truncated extended FFS header")
        size = struct.unpack_from("<Q", blob, offset + 24)[0]
        header = 32
    if size < header or offset + size > len(blob):
        raise ValueError("invalid FFS size")
    return blob[offset + header : offset + size]


def section_at(blob: bytes, offset: int) -> tuple[int, int, int, bytes]:
    if offset + 4 > len(blob):
        raise ValueError("truncated section")
    size = u24(blob[offset : offset + 3])
    kind = blob[offset + 3]
    header = 4
    if size == 0xFFFFFF:
        if offset + 8 > len(blob):
            raise ValueError("truncated extended section")
        size = struct.unpack_from("<I", blob, offset + 4)[0]
        header = 8
    if size < header or offset + size > len(blob):
        raise ValueError("invalid section size")
    return size, kind, header, blob[offset + header : offset + size]


def expand_nested_fv(source: bytes) -> tuple[bytes, int]:
    candidates = []
    for offset in offsets(source, FV_FILE_GUID.bytes_le):
        try:
            if source[offset + 18] != 0x0B:
                continue
            body = ffs_body(source, offset)
            size, kind, header, payload = section_at(body, 0)
            if kind != 0x02 or len(payload) < 20:
                continue
            codec = uuid.UUID(bytes_le=payload[:16])
            data_offset, _attrs = struct.unpack_from("<HH", payload, 16)
            if codec != LZMA_GUID or not (header + 20 <= data_offset <= size):
                continue
            candidates.append((offset, body[data_offset:size]))
        except (IndexError, ValueError):
            continue
    if len(candidates) != 1:
        raise SystemExit(f"expected one nested FV candidate, found {len(candidates)}")
    offset, compressed = candidates[0]
    try:
        return lzma.decompress(compressed, format=lzma.FORMAT_ALONE), offset
    except lzma.LZMAError as error:
        raise SystemExit(f"nested FV decompression failed: {error}") from error


def extract_ecflash(expanded: bytes) -> tuple[bytes, int]:
    candidates = []
    for offset in offsets(expanded, ECFLASH_GUID.bytes_le):
        try:
            if expanded[offset + 18] != 0x07:
                continue
            body = ffs_body(expanded, offset)
            cursor = 0
            ui = None
            pe32 = None
            while cursor + 4 <= len(body):
                size, kind, _header, payload = section_at(body, cursor)
                if kind == 0x15:
                    ui = payload.decode("utf-16-le", "strict").rstrip("\x00")
                elif kind == 0x10:
                    if pe32 is not None:
                        raise ValueError("multiple PE32 sections")
                    pe32 = payload
                cursor = (cursor + size + 3) & ~3
            if ui == EXPECTED_UI and pe32 is not None:
                candidates.append((offset, pe32))
        except (IndexError, UnicodeDecodeError, ValueError):
            continue
    if len(candidates) != 1:
        raise SystemExit(f"expected one ECFlashApp file, found {len(candidates)}")
    return candidates[0][1], candidates[0][0]


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Extract ECFlashApp.efi from an A14 FMP image"
    )
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.input.resolve() == args.output.resolve():
        raise SystemExit("refusing to overwrite the input")

    source = args.input.read_bytes()
    expanded, fv_offset = expand_nested_fv(source)
    app, app_offset = extract_ecflash(expanded)
    digest = hashlib.sha256(app).hexdigest()
    if len(app) != EXPECTED_SIZE or digest != EXPECTED_SHA256:
        raise SystemExit(f"ECFlashApp identity mismatch: size={len(app)} sha256={digest}")
    args.output.write_bytes(app)
    print(f"source={args.input}")
    print(f"nested_fv_ffs_offset=0x{fv_offset:x}")
    print(f"nested_fv_expanded_size={len(expanded)}")
    print(f"ecflash_ffs_offset_in_expanded=0x{app_offset:x}")
    print(f"ecflash_ui={EXPECTED_UI}")
    print(f"ecflash_size={len(app)}")
    print(f"ecflash_sha256={digest}")
    print(f"output={args.output}")
    print("source_modified=NO")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
