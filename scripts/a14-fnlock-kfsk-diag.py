#!/usr/bin/env python3
"""Read the UX3407RA BIOS-312 KFSK selector from firmware shared memory.

The captured Windows DSDT defines:
  AAML = 0xD46DE000
  RAMW[AECB] at AAML + 0x0c
  AECO[KFSK] at AECB + 0x14

DEVS(0x00100023,state) then sends:
  ECCW(0x02, 0x84, KFSK | (state ? 0x08 : 0x04))

This diagnostic is READ-ONLY. It never writes /dev/mem or the EC.
On kernels with strict /dev/mem restrictions it may fail cleanly; that is not
interpreted as a KFSK value.
"""

from __future__ import annotations

import os
import struct
import sys

AAML = 0xD46DE000
AECB_PTR_OFFSET = 0x0C
KFSK_OFFSET = 0x14
AECO_SIZE = 0x1E


def pread_exact(fd: int, size: int, offset: int) -> bytes:
    data = os.pread(fd, size, offset)
    if len(data) != size:
        raise OSError(f"short /dev/mem read at 0x{offset:x}: {len(data)}/{size}")
    return data


def main() -> int:
    print("===== A14 BIOS KFSK SHARED-MEMORY DIAG =====")
    print(f"AAML_PHYS=0x{AAML:08x}")
    print(f"AECB_POINTER_PHYS=0x{AAML + AECB_PTR_OFFSET:08x}")
    print("ACCESS=READ_ONLY")

    try:
        fd = os.open("/dev/mem", os.O_RDONLY | getattr(os, "O_SYNC", 0))
    except OSError as error:
        print(f"DEVMEM_OPEN=FAILED errno={error.errno} error={error.strerror}")
        print("A14_KFSK_DIAG=UNAVAILABLE")
        return 3

    try:
        raw_ptr = pread_exact(fd, 4, AAML + AECB_PTR_OFFSET)
        aecb = struct.unpack("<I", raw_ptr)[0]
        print(f"AECB_POINTER_RAW={raw_ptr.hex(' ')}")
        print(f"AECB_PHYS=0x{aecb:08x}")
        if aecb < 0x10000 or aecb > 0xFFFFFFFF:
            print("AECB_POINTER=IMPLAUSIBLE")
            print("A14_KFSK_DIAG=UNAVAILABLE")
            return 4

        aeco = pread_exact(fd, AECO_SIZE, aecb)
        kfsk = aeco[KFSK_OFFSET]
        print(f"AECO_BYTES={aeco.hex(' ')}")
        print(f"KFSK=0x{kfsk:02x}")
        print(f"DEVS_STATE_0_COMMAND=0x{(kfsk | 0x04):02x}")
        print(f"DEVS_STATE_1_COMMAND=0x{(kfsk | 0x08):02x}")
        if kfsk in (0x00, 0x80):
            print("KFSK_KNOWN_SHAPE=YES")
        else:
            print("KFSK_KNOWN_SHAPE=NO_DO_NOT_GUESS")
        print("A14_KFSK_DIAG=PASS")
        return 0
    except OSError as error:
        print(f"DEVMEM_READ=FAILED errno={getattr(error, 'errno', None)} error={error}")
        print("A14_KFSK_DIAG=UNAVAILABLE")
        return 5
    finally:
        os.close(fd)


if __name__ == "__main__":
    raise SystemExit(main())
