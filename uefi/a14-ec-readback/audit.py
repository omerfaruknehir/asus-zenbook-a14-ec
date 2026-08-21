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
optional_magic = struct.unpack_from("<H", image, pe + 24)[0]
subsystem = struct.unpack_from("<H", image, pe + 24 + 68)[0]
if machine != 0xaa64 or optional_magic != 0x20b or subsystem != 10:
    raise SystemExit(f"unexpected PE identity machine={machine:#x} magic={optional_magic:#x} subsystem={subsystem}")
print("audit=pass")
print("architecture=aarch64")
print("subsystem=efi_application")
print("spi_allowlist=0x9f,0x0b")
print("spi_write_path=absent")
print(f"sections={sections}")
print(f"sha256={hashlib.sha256(image).hexdigest()}")
