#!/usr/bin/env python3
"""Fail-closed source/binary audit for the A14 readback application."""

from __future__ import annotations
import hashlib
import pathlib
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parent
SOURCE = (ROOT / "a14_ec_readback.c").read_text()
REQUIRED = ("SPI_FAST_READ    0x0bU", "SPI_READ_ID      0x9fU",
            "spi_flash_write_commands=none", "bridge_mode != 0")
FORBIDDEN = ("SPI_WRITE_ENABLE", "SPI_WRITE_DISABLE", "SPI_SECTOR_ERASE",
             "SPI_PAGE_PROGRAM", "spi_program", "spi_erase")

for token in REQUIRED:
    if token not in SOURCE:
        raise SystemExit(f"required safety token missing: {token}")
for token in FORBIDDEN:
    if token in SOURCE:
        raise SystemExit(f"forbidden write-path token present: {token}")

image = pathlib.Path(sys.argv[1]).read_bytes()
if image[:2] != b"MZ": raise SystemExit("not PE/COFF")
pe = struct.unpack_from("<I", image, 0x3c)[0]
if image[pe:pe+4] != b"PE\0\0": raise SystemExit("bad PE signature")
machine, sections = struct.unpack_from("<HH", image, pe + 4)
coff_characteristics = struct.unpack_from("<H", image, pe + 22)[0]
optional_magic = struct.unpack_from("<H", image, pe + 24)[0]
subsystem = struct.unpack_from("<H", image, pe + 24 + 68)[0]
image_base = struct.unpack_from("<Q", image, pe + 24 + 24)[0]
section_alignment, file_alignment = struct.unpack_from("<II", image, pe + 24 + 32)
directory_count = struct.unpack_from("<I", image, pe + 24 + 108)[0]
if machine != 0xaa64 or optional_magic != 0x20b or subsystem != 10:
    raise SystemExit(f"unexpected PE identity machine={machine:#x} magic={optional_magic:#x} subsystem={subsystem}")
if coff_characteristics & 0x0001:
    raise SystemExit("PE base relocations are marked stripped")
if image_base != 0:
    raise SystemExit(f"unexpected nonzero image base: {image_base:#x}")
if section_alignment != 0x1000 or file_alignment != 0x1000:
    raise SystemExit(
        f"firmware-compatible 4 KiB alignment missing: section={section_alignment:#x} file={file_alignment:#x}"
    )
if directory_count < 6:
    raise SystemExit(f"PE data-directory table is too short: {directory_count}")
reloc_rva, reloc_size = struct.unpack_from("<II", image, pe + 24 + 112 + 5 * 8)
if reloc_rva == 0 or reloc_size < 8:
    raise SystemExit(f"base relocation directory missing: rva={reloc_rva:#x} size={reloc_size:#x}")
print("audit=pass")
print("architecture=aarch64")
print("subsystem=efi_application")
print("image_base=0x0")
print("section_alignment=0x1000")
print("file_alignment=0x1000")
print(f"base_relocations=rva:{reloc_rva:#x},size:{reloc_size:#x}")
print("spi_allowlist=0x9f,0x0b")
print("spi_write_path=absent")
print(f"sections={sections}")
print(f"sha256={hashlib.sha256(image).hexdigest()}")
