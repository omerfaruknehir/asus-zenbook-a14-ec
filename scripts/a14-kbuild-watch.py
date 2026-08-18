#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Report real Kbuild module-finalization progress for the A14 build tree.

Unlike action-count or file-existence progress, this treats a module as complete
only when its final .ko is current and (when enabled) actually contains a .BTF
section. modules.order contains .o paths; those are converted to their final .ko
paths exactly as scripts/Makefile.modfinal does.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import struct
import sys
import time


def parse_args() -> argparse.Namespace:
    default = Path.home() / "Downloads" / "a14-full-acpi-kernel" / "build"
    p = argparse.ArgumentParser()
    p.add_argument("--build", type=Path, default=default)
    p.add_argument("--interval", type=float, default=0.75)
    p.add_argument("--once", action="store_true")
    return p.parse_args()


def config_enabled(out: Path, symbol: str) -> bool:
    needle = f"{symbol}=y"
    for candidate in (out / "include/config/auto.conf", out / ".config"):
        try:
            for line in candidate.read_text(errors="replace").splitlines():
                if line == needle:
                    return True
        except OSError:
            pass
    return False


def load_modules(out: Path) -> list[tuple[Path, Path, Path]]:
    order = out / "modules.order"
    if not order.is_file():
        raise SystemExit(f"ERROR: missing {order}")

    result: list[tuple[Path, Path, Path]] = []
    seen: set[str] = set()
    for raw in order.read_text(errors="replace").splitlines():
        rel = raw.strip()
        if not rel or rel in seen:
            continue
        seen.add(rel)
        if not rel.endswith(".o"):
            continue
        stem = rel[:-2]
        result.append((out / rel, out / f"{stem}.mod.o", out / f"{stem}.ko"))
    return result


class BtfCache:
    def __init__(self) -> None:
        self._cache: dict[str, tuple[int, int, bool]] = {}

    def has_btf(self, path: Path, st: os.stat_result | None = None) -> bool:
        try:
            st = st or path.stat()
        except OSError:
            return False
        sig = (st.st_mtime_ns, st.st_size)
        old = self._cache.get(str(path))
        if old is not None and old[:2] == sig:
            return old[2]
        value = self._scan_elf64(path)
        self._cache[str(path)] = (sig[0], sig[1], value)
        return value

    @staticmethod
    def _scan_elf64(path: Path) -> bool:
        """Return True when an ELF64 file contains a section named .BTF."""
        try:
            with path.open("rb", buffering=0) as f:
                ident = f.read(16)
                if len(ident) != 16 or ident[:4] != b"\x7fELF" or ident[4] != 2:
                    return False
                endian = "<" if ident[5] == 1 else ">" if ident[5] == 2 else None
                if endian is None:
                    return False

                rest = f.read(64 - 16)
                if len(rest) != 48:
                    return False
                # ELF64 header fields after e_ident.
                fields = struct.unpack(endian + "HHIQQQIHHHHHH", rest)
                e_shoff = fields[5]
                e_shentsize = fields[10]
                e_shnum = fields[11]
                e_shstrndx = fields[12]
                if not e_shoff or e_shentsize < 64 or not e_shnum or e_shstrndx >= e_shnum:
                    return False

                def read_sh(index: int) -> tuple[int, int, int]:
                    f.seek(e_shoff + index * e_shentsize)
                    raw = f.read(64)
                    if len(raw) != 64:
                        raise EOFError
                    sh = struct.unpack(endian + "IIQQQQIIQQ", raw)
                    return sh[0], sh[4], sh[5]  # name offset, file offset, size

                _, str_off, str_size = read_sh(e_shstrndx)
                f.seek(str_off)
                names = f.read(str_size)

                for i in range(e_shnum):
                    name_off, _, _ = read_sh(i)
                    if name_off >= len(names):
                        continue
                    end = names.find(b"\x00", name_off)
                    if end < 0:
                        continue
                    if names[name_off:end] == b".BTF":
                        return True
        except (OSError, EOFError, struct.error):
            return False
        return False


def stat_ns(path: Path) -> int:
    try:
        return path.stat().st_mtime_ns
    except OSError:
        return -1


def module_complete(
    obj: Path,
    mod_obj: Path,
    ko: Path,
    *,
    vmlinux_ns: int,
    common_ns: int,
    module_lds_ns: int,
    require_btf: bool,
    btf_cache: BtfCache,
) -> bool:
    try:
        st = ko.stat()
    except OSError:
        return False
    if st.st_size <= 0:
        return False

    newest_input = max(stat_ns(obj), stat_ns(mod_obj), common_ns, module_lds_ns)
    if st.st_mtime_ns < newest_input:
        return False
    if require_btf:
        # v7.1.5 Makefile.modfinal regenerates module BTF when vmlinux or the
        # module is newer; gen-btf.sh embeds .BTF directly into the final .ko.
        if st.st_mtime_ns < vmlinux_ns:
            return False
        if not btf_cache.has_btf(ko, st):
            return False
    return True


def fmt_time(seconds: float) -> str:
    if seconds < 0 or seconds == float("inf"):
        return "--:--"
    seconds = int(seconds)
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def draw(done: int, total: int, elapsed: float, start_done: int) -> None:
    width = shutil.get_terminal_size((120, 20)).columns
    bar_w = max(16, min(42, width // 3))
    ratio = done / total if total else 1.0
    filled = min(bar_w, int(bar_w * ratio))
    bar = "#" * filled + "-" * (bar_w - filled)

    advanced = done - start_done
    if advanced > 0 and elapsed > 0 and done < total:
        rate = advanced / elapsed
        eta = (total - done) / rate if rate > 0 else float("inf")
    elif done >= total:
        eta = 0
    else:
        eta = float("inf")

    line = (
        f"[{bar}] {ratio * 100:6.2f}%  {done}/{total} finalized  "
        f"elapsed {fmt_time(elapsed)}  ETA {fmt_time(eta)}"
    )
    sys.stdout.write("\r" + line[: max(1, width - 1)].ljust(max(1, width - 1)))
    sys.stdout.flush()


def main() -> int:
    args = parse_args()
    out = args.build.expanduser().resolve()
    modules = load_modules(out)
    total = len(modules)
    if total == 0:
        raise SystemExit("ERROR: modules.order contains no module objects")

    require_btf = config_enabled(out, "CONFIG_DEBUG_INFO_BTF_MODULES")
    vmlinux = out / "vmlinux"
    common = out / ".module-common.o"
    module_lds = out / "scripts/module.lds"
    btf_cache = BtfCache()

    def count() -> int:
        vmlinux_ns = stat_ns(vmlinux)
        common_ns = stat_ns(common)
        module_lds_ns = stat_ns(module_lds)
        return sum(
            module_complete(
                obj,
                mod_obj,
                ko,
                vmlinux_ns=vmlinux_ns,
                common_ns=common_ns,
                module_lds_ns=module_lds_ns,
                require_btf=require_btf,
                btf_cache=btf_cache,
            )
            for obj, mod_obj, ko in modules
        )

    start_done = count()
    start = time.monotonic()
    print(f"build={out}")
    print(f"modules_total={total}")
    print(f"btf_required={'yes' if require_btf else 'no'}")
    print(f"finalized_at_start={start_done}")

    while True:
        done = count()
        elapsed = time.monotonic() - start
        draw(done, total, elapsed, start_done)
        if args.once or done >= total:
            sys.stdout.write("\n")
            if done >= total:
                print("A14_MODULE_FINALIZATION=COMPLETE")
            return 0
        time.sleep(max(0.1, args.interval))


if __name__ == "__main__":
    raise SystemExit(main())
