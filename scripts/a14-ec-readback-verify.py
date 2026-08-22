#!/usr/bin/env python3
"""Verify three full A14 EC readback passes and produce a durable backup."""

from __future__ import annotations
import argparse
import hashlib
import shutil
from pathlib import Path

FLASH_SIZE = 0x100000
ACTIVE_SIZE = 0x40000
KNOWN_ACTIVE_SHA256 = "353eb0d125d76a14f15faa72f2153d57e25efd8d212f42b18a9f11c16e3fc39d"

def digest(data: bytes) -> str: return hashlib.sha256(data).hexdigest()

def main() -> int:
    p = argparse.ArgumentParser(description="Verify A14EC001/2/3.BIN readback files")
    p.add_argument("directory", type=Path)
    p.add_argument("--output", type=Path, default=Path("a14-ec-full-backup.bin"))
    a = p.parse_args()
    paths = [a.directory / f"A14EC00{i}.BIN" for i in (1, 2, 3)]
    blobs = [path.read_bytes() for path in paths]
    for path, blob in zip(paths, blobs):
        if len(blob) != FLASH_SIZE: raise SystemExit(f"{path}: expected {FLASH_SIZE} bytes, got {len(blob)}")
        print(f"{path.name}_sha256={digest(blob)}")
    if not (blobs[0] == blobs[1] == blobs[2]): raise SystemExit("readback passes differ; backup NOT created")
    active = digest(blobs[0][:ACTIVE_SIZE])
    print("passes_identical=yes")
    print(f"active_0x00000_0x3ffff_sha256={active}")
    print(f"active_matches_official_ux3407ra_313={'yes' if active == KNOWN_ACTIVE_SHA256 else 'no'}")
    print(f"upper_0x40000_0xfffff_sha256={digest(blobs[0][ACTIVE_SIZE:])}")
    a.output.write_bytes(blobs[0])
    print(f"backup={a.output.resolve()}")
    print(f"backup_sha256={digest(blobs[0])}")
    return 0

if __name__ == "__main__": raise SystemExit(main())
