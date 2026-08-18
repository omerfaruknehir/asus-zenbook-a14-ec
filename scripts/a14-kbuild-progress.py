#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Render compact live progress for an A14 Kbuild stream read from stdin."""

import argparse
import re
import shutil
import sys
import time


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--label", required=True)
    p.add_argument("--logfile", required=True)
    p.add_argument("--module-total", type=int, default=0)
    p.add_argument("--module-built", type=int, default=0)
    return p.parse_args()


args = parse_args()
label = args.label
logfile = args.logfile
module_total = max(0, args.module_total)
module_done = max(0, args.module_built)
module_start = module_done
start = time.monotonic()
actions = 0
warnings = 0
shown = 0
last_target = "starting"
spin_i = 0
seen_ko = set()

act = re.compile(
    r"^\s*(AR|AS|BTF|BTFIDS|CALL|CC|CHK|DTC|DTB|GEN|HOSTCC|HOSTCXX|HOSTLD|"
    r"KSYMS|LD|LEX|MODPOST|NM|OBJCOPY|SORTTAB|UPD|YACC)"
    r"(?:\s+\[M\])?\s+(.+?)\s*$"
)
warn = re.compile(r"(?:\bwarning:|\bWARNING:)", re.I)
err = re.compile(
    r"(?:\bfatal:|\berror:|\bERROR:|undefined reference|No rule to make target|"
    r"make(?:\[\d+\])?: \*\*\*)",
    re.I,
)
ko = re.compile(r"^\s*(?:LD|BTF)\s+\[M\]\s+(.+\.ko)\s*$")


def hms(value):
    value = max(0, int(value))
    h, rem = divmod(value, 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def clear_line():
    width = shutil.get_terminal_size((120, 20)).columns
    sys.stdout.write("\r" + " " * max(1, width - 1) + "\r")


def draw():
    global spin_i
    elapsed = time.monotonic() - start
    width = shutil.get_terminal_size((120, 20)).columns
    bar_width = max(12, min(34, width // 4))

    if module_total > 0:
        ratio = min(module_done / module_total, 0.99)
        filled = int(bar_width * ratio)
        bar = "#" * filled + "-" * (bar_width - filled)
        prefix = f"~{int(ratio * 100):2d}%"
        counts = f"{module_done}/{module_total} modules"
        advanced = max(0, module_done - module_start)
        if advanced >= 2 and elapsed > 0:
            rate = advanced / elapsed
            eta = "~" + hms((module_total - module_done) / rate) if rate else "--:--"
        else:
            eta = "--:--"
    else:
        span = min(6, bar_width)
        pos = spin_i % max(1, bar_width - span + 1)
        spin_i += 1
        chars = list("-" * bar_width)
        for i in range(pos, pos + span):
            chars[i] = "#"
        bar = "".join(chars)
        prefix = "running"
        counts = f"actions:{actions}"
        eta = "--:--"

    target = last_target
    max_target = max(18, width - bar_width - 68)
    if len(target) > max_target:
        target = "…" + target[-(max_target - 1):]

    line = (
        f"[{bar}] {prefix}  {counts}  elapsed {hms(elapsed)}  ETA {eta}  "
        f"warn {warnings}  {target}"
    )
    sys.stdout.write("\r" + line[: max(1, width - 1)].ljust(max(1, width - 1)))
    sys.stdout.flush()


print(f"A14_BUILD_PHASE={label}")
if module_total:
    print(f"modules_total={module_total}")
    print(f"modules_already_built={module_done}")
else:
    print("progress_mode=immediate activity bar; no blocking Kbuild preflight")
print(f"raw_log={logfile}")
draw()

try:
    for raw in sys.stdin:
        line = raw.rstrip("\n")

        km = ko.match(line)
        if km and km.group(1) not in seen_ko:
            seen_ko.add(km.group(1))
            if module_total:
                module_done = min(module_total, module_done + 1)

        m = act.match(line)
        if m:
            actions += 1
            last_target = f"{m.group(1)} {m.group(2)}"
            draw()
            continue

        if warn.search(line):
            warnings += 1
            if shown < 5:
                clear_line()
                print(line)
                shown += 1
            draw()
            continue

        if err.search(line):
            clear_line()
            print(line)
            draw()
finally:
    clear_line()

print(f"A14_BUILD_PHASE_STREAM_END={label}")
print(f"actions_observed={actions}")
print(f"warnings_observed={warnings}")
if warnings > shown:
    print(
        f"warnings_suppressed_from_terminal={warnings - shown} "
        f"(all preserved in {logfile})"
    )
