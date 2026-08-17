#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Resolve a 1-based device_initcall ordinal in the built A14 vmlinux.

Reads the actual linked initcall table, including ARM64 PREL32 entries, rather
than guessing from source/link order.  Prints nearby ordinals, target symbols,
and addr2line locations so a hard-reset bisect can be mapped back to code.
"""
from __future__ import annotations

import os
from pathlib import Path
import struct
import subprocess
import sys

KREL = "7.1.5-a14-acpi-full0"


def die(msg: str) -> "NoReturn":
    raise SystemExit(f"ERROR: {msg}")


def run(*args: str) -> str:
    return subprocess.check_output(args, text=True, errors="replace").strip()


def parse_nm(vmlinux: Path):
    rows = []
    for line in run("nm", "-n", "--defined-only", str(vmlinux)).splitlines():
        p = line.split(None, 2)
        if len(p) != 3:
            continue
        try:
            addr = int(p[0], 16)
        except ValueError:
            continue
        rows.append((addr, p[1], p[2]))
    return rows


def symbol_addr(rows, name: str) -> int:
    for addr, _typ, sym in rows:
        if sym == name:
            return addr
    die(f"missing symbol {name}")


def symbols_at(rows, addr: int):
    return [name for a, _typ, name in rows if a == addr]


def nearest_symbol(rows, addr: int):
    best = None
    for row in rows:
        if row[0] > addr:
            break
        best = row
    if best is None:
        return None
    return best


def elf_sections(path: Path):
    data = path.read_bytes()
    if len(data) < 64 or data[:4] != b"\x7fELF":
        die(f"not an ELF file: {path}")
    if data[4] != 2:
        die("expected ELF64 vmlinux")
    if data[5] != 1:
        die("expected little-endian vmlinux")

    e_shoff = struct.unpack_from("<Q", data, 40)[0]
    e_shentsize = struct.unpack_from("<H", data, 58)[0]
    e_shnum = struct.unpack_from("<H", data, 60)[0]
    if e_shentsize < 64 or not e_shnum:
        die("invalid ELF section table")

    sections = []
    fmt = "<IIQQQQIIQQ"
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        if off + 64 > len(data):
            die("truncated ELF section table")
        sh = struct.unpack_from(fmt, data, off)
        sections.append({
            "type": sh[1],
            "addr": sh[3],
            "offset": sh[4],
            "size": sh[5],
        })
    return data, sections


def read_vaddr(data: bytes, sections, addr: int, size: int) -> bytes:
    # SHT_NOBITS == 8 has no bytes in the file.
    for sh in sections:
        if sh["type"] == 8 or not sh["size"]:
            continue
        start = sh["addr"]
        end = start + sh["size"]
        if start <= addr and addr + size <= end:
            off = sh["offset"] + (addr - start)
            if off + size > len(data):
                die(f"ELF file offset for 0x{addr:x} is truncated")
            return data[off:off + size]
    die(f"virtual address 0x{addr:x} is not backed by an ELF section")


def addr2line(vmlinux: Path, addr: int) -> str:
    try:
        return run("addr2line", "-f", "-p", "-e", str(vmlinux), f"0x{addr:x}")
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "<addr2line unavailable>"


def resolve(rows, data, sections, start: int, entry_size: int, ordinal: int, vmlinux: Path):
    entry_addr = start + (ordinal - 1) * entry_size
    raw = read_vaddr(data, sections, entry_addr, entry_size)
    if entry_size == 4:
        rel = struct.unpack("<i", raw)[0]
        target = (entry_addr + rel) & ((1 << 64) - 1)
        encoding = f"PREL32 {rel:+d}"
    else:
        target = struct.unpack("<Q", raw)[0]
        encoding = "pointer"

    exact = symbols_at(rows, target)
    near = nearest_symbol(rows, target)
    if exact:
        target_name = ",".join(exact)
    elif near:
        target_name = f"{near[2]}+0x{target - near[0]:x}"
    else:
        target_name = "<unknown>"

    init_syms = [x for x in symbols_at(rows, entry_addr) if "initcall" in x]
    return {
        "ordinal": ordinal,
        "entry": entry_addr,
        "entry_symbol": ",".join(init_syms) if init_syms else "<none>",
        "encoding": encoding,
        "target": target,
        "target_symbol": target_name,
        "location": addr2line(vmlinux, target),
    }


def default_ordinal() -> int | None:
    state = Path("/var/lib/a14-full-acpi/device-bisect.state")
    if not state.is_file():
        return None
    vals = {}
    for line in state.read_text(errors="replace").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            vals[k.strip()] = v.strip()
    if vals.get("state_low") == vals.get("state_high") and vals.get("state_low", "").isdigit():
        return int(vals["state_low"])
    return None


def main() -> None:
    owner_home = Path(os.environ.get("HOME", str(Path.home())))
    work = Path(os.environ.get("A14_FULL_ACPI_WORK", owner_home / "Downloads/a14-full-acpi-kernel"))
    out = work / "build"
    vmlinux = out / "vmlinux"
    config = out / ".config"

    if not vmlinux.is_file() or not config.is_file():
        die(f"missing built vmlinux/config under {out}")

    if len(sys.argv) >= 2:
        try:
            ordinal = int(sys.argv[1])
        except ValueError:
            die("ordinal must be an integer")
    else:
        ordinal = default_ordinal()
        if ordinal is None:
            die("no converged bisect state; pass the ordinal explicitly")

    rows = parse_nm(vmlinux)
    start = symbol_addr(rows, "__initcall6_start")
    end = symbol_addr(rows, "__initcall7_start")
    conf = config.read_text(errors="replace")
    entry_size = 4 if "CONFIG_HAVE_ARCH_PREL32_RELOCATIONS=y" in conf else 8
    span = end - start
    if span <= 0 or span % entry_size:
        die(f"invalid device-initcall span {span} bytes / entry_size {entry_size}")
    total = span // entry_size
    if not 1 <= ordinal <= total:
        die(f"ordinal {ordinal} outside 1..{total}")

    data, sections = elf_sections(vmlinux)

    print("A14_FULL_ACPI_DEVICE_INITCALL_RESOLVE=COMPLETE")
    print(f"kernelrelease={KREL}")
    print(f"device_initcall_total={total}")
    print(f"requested_ordinal={ordinal}")
    print(f"entry_size={entry_size}")
    print(f"device_table=0x{start:x}..0x{end:x}")
    print()

    lo = max(1, ordinal - 3)
    hi = min(total, ordinal + 3)
    for n in range(lo, hi + 1):
        r = resolve(rows, data, sections, start, entry_size, n, vmlinux)
        flag = "<<< ISOLATED" if n == ordinal else ""
        print(f"[{n:4d}] entry=0x{r['entry']:x} target=0x{r['target']:x} {flag}")
        print(f"       initcall_symbol={r['entry_symbol']}")
        print(f"       target_symbol={r['target_symbol']}")
        print(f"       encoding={r['encoding']}")
        print(f"       source={r['location']}")


if __name__ == "__main__":
    main()
