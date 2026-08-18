#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Progress renderer for A14 kernel installation phases."""

from __future__ import annotations

import argparse
from pathlib import Path
import os
import shutil
import sys
import time


def hms(v: float) -> str:
    v = max(0, int(v))
    h, rem = divmod(v, 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def draw_bar(done: int, total: int, elapsed: float, label: str, start_done: int) -> None:
    width = shutil.get_terminal_size((120, 20)).columns
    bw = max(16, min(42, width // 3))
    ratio = done / total if total else 0.0
    ratio = max(0.0, min(1.0, ratio))
    filled = int(bw * ratio)
    bar = "#" * filled + "-" * (bw - filled)
    advanced = done - start_done
    if advanced > 0 and elapsed > 0 and done < total:
        rate = advanced / elapsed
        eta = (total - done) / rate if rate else float("inf")
        eta_s = hms(eta)
    elif done >= total and total:
        eta_s = "00:00"
    else:
        eta_s = "--:--"
    line = (
        f"[{bar}] {ratio*100:6.2f}%  {done}/{total}  "
        f"elapsed {hms(elapsed)}  ETA {eta_s}  {label}"
    )
    sys.stdout.write("\r" + line[: max(1, width - 1)].ljust(max(1, width - 1)))
    sys.stdout.flush()


def draw_activity(elapsed: float, label: str, tick: int) -> None:
    width = shutil.get_terminal_size((120, 20)).columns
    bw = max(16, min(42, width // 3))
    span = min(7, bw)
    pos = tick % max(1, bw - span + 1)
    chars = list("-" * bw)
    for i in range(pos, pos + span):
        chars[i] = "#"
    line = f"[{''.join(chars)}] running  elapsed {hms(elapsed)}  {label}"
    sys.stdout.write("\r" + line[: max(1, width - 1)].ljust(max(1, width - 1)))
    sys.stdout.flush()


def module_paths(build: Path) -> list[str]:
    order = build / "modules.order"
    if not order.is_file():
        raise SystemExit(f"ERROR: missing {order}")
    out: list[str] = []
    seen: set[str] = set()
    for raw in order.read_text(errors="replace").splitlines():
        rel = raw.strip()
        if not rel or rel in seen or not rel.endswith(".o"):
            continue
        seen.add(rel)
        out.append(rel[:-2] + ".ko")
    if not out:
        raise SystemExit("ERROR: modules.order contains no modules")
    return out


def watch_modules(args: argparse.Namespace) -> int:
    build = args.build.resolve()
    dest = args.dest.resolve()
    mods = module_paths(build)

    def count() -> int:
        return sum((dest / "kernel" / rel).is_file() for rel in mods)

    start_done = count()
    start = time.monotonic()
    while True:
        done = count()
        elapsed = time.monotonic() - start
        draw_bar(done, len(mods), elapsed, "modules installed", start_done)
        if not pid_alive(args.pid):
            sys.stdout.write("\n")
            return 0 if done == len(mods) else 2
        time.sleep(max(0.1, args.interval))


def watch_activity(args: argparse.Namespace) -> int:
    start = time.monotonic()
    tick = 0
    while pid_alive(args.pid):
        draw_activity(time.monotonic() - start, args.label, tick)
        tick += 1
        time.sleep(max(0.1, args.interval))
    draw_activity(time.monotonic() - start, args.label, tick)
    sys.stdout.write("\n")
    return 0


def main() -> int:
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="mode", required=True)

    m = sub.add_parser("modules")
    m.add_argument("--build", type=Path, required=True)
    m.add_argument("--dest", type=Path, required=True)
    m.add_argument("--pid", type=int, required=True)
    m.add_argument("--interval", type=float, default=0.35)

    a = sub.add_parser("activity")
    a.add_argument("--pid", type=int, required=True)
    a.add_argument("--label", required=True)
    a.add_argument("--interval", type=float, default=0.2)

    args = p.parse_args()
    if args.mode == "modules":
        return watch_modules(args)
    return watch_activity(args)


if __name__ == "__main__":
    raise SystemExit(main())
