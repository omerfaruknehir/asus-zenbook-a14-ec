#!/usr/bin/env python3
"""Create a raw 0..255 keyboard-backlight variant of the UX3407RA EC image.

This tool only patches an already-extracted 256 KiB EC image. It deliberately
does not flash hardware or modify a BIOS/FMP capsule. The exact input hash and
original instruction bytes are both checked before any output is written.
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path


EC_SIZE = 256 * 1024
EC_SHA256 = "353eb0d125d76a14f15faa72f2153d57e25efd8d212f42b18a9f11c16e3fc39d"
PATCH_OFFSET = 0xFFDC

# Original function begins by mapping 0/1/2/3 to 00/43/87/CC and maps every
# other value to zero. Only its single entry point at 0xffdc is referenced.
ORIGINAL = bytes.fromhex("09 47 b7 37 80 00 63 00 e5 02")

# RV32IMC:
#   lui a5, 0x803
#   sb  a0, 0x4a(a5)       # keyboard-backlight PWM target
#   ret
RAW_TARGET = bytes.fromhex("b7 37 80 00 23 85 a7 04 82 80")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Patch an extracted UX3407RA.313 EC image for raw 0..255 backlight targets"
    )
    parser.add_argument("input", type=Path, help="extracted 256 KiB EC image")
    parser.add_argument("output", type=Path, help="new patched EC image")
    args = parser.parse_args()

    source = args.input.read_bytes()
    digest = sha256(source)
    if len(source) != EC_SIZE:
        raise SystemExit(f"refusing input size {len(source)}; expected {EC_SIZE}")
    if digest != EC_SHA256:
        raise SystemExit(f"refusing unknown EC image sha256={digest}")
    if source[PATCH_OFFSET : PATCH_OFFSET + len(ORIGINAL)] != ORIGINAL:
        observed = source[PATCH_OFFSET : PATCH_OFFSET + len(ORIGINAL)].hex()
        raise SystemExit(
            f"instruction guard failed at 0x{PATCH_OFFSET:x}: observed={observed}"
        )
    if args.input.resolve() == args.output.resolve():
        raise SystemExit("refusing in-place modification; choose a separate output")

    patched = bytearray(source)
    patched[PATCH_OFFSET : PATCH_OFFSET + len(RAW_TARGET)] = RAW_TARGET
    args.output.write_bytes(patched)

    print(f"input={args.input}")
    print(f"input_sha256={digest}")
    print(f"patch_offset=0x{PATCH_OFFSET:x}")
    print(f"original={ORIGINAL.hex(' ')}")
    print(f"replacement={RAW_TARGET.hex(' ')}")
    print(f"output={args.output}")
    print(f"output_sha256={sha256(patched)}")
    print("flash_performed=NO")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
