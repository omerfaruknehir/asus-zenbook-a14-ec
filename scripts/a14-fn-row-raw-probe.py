#!/usr/bin/env python3
"""Capture the A14 keyboard's real F-row HID reports without changing bindings.

The generic ASUS 5a d0 4e Fn-lock command is not sufficient on the Zenbook A14.
This probe records what the firmware actually emits for plain F keys versus
Fn-modified keys so the kernel driver can implement the correct software
inversion instead of guessing another vendor command.

Modes:
  missing  Capture only Fn combinations still needed after the first A14 probe.
  all      Capture representative plain/Fn pairs across the entire F-row.
"""

from __future__ import annotations

import os
from pathlib import Path
import selectors
import sys
import termios
import time

ASUS_VENDOR = 0x0B05
PRODUCTS = {0x0220, 0x4543}


def read_uevent(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        for line in path.read_text(errors="replace").splitlines():
            key, sep, value = line.partition("=")
            if sep:
                values[key] = value
    except OSError:
        pass
    return values


def parse_id(text: str) -> tuple[int, int] | None:
    try:
        _bus, vendor, product = text.split(":", 2)
        return int(vendor, 16), int(product, 16)
    except (ValueError, AttributeError):
        return None


def driver_name(device: Path) -> str:
    try:
        return (device / "driver").resolve().name
    except OSError:
        return "unbound"


def devices() -> list[tuple[Path, int, str, str]]:
    result: list[tuple[Path, int, str, str]] = []
    for cls in sorted(Path("/sys/class/hidraw").glob("hidraw*")):
        info = read_uevent(cls / "device" / "uevent")
        ident = parse_id(info.get("HID_ID", ""))
        if not ident:
            continue
        vendor, product = ident
        if vendor != ASUS_VENDOR or product not in PRODUCTS:
            continue
        result.append(
            (
                Path("/dev") / cls.name,
                product,
                driver_name(cls / "device"),
                info.get("HID_NAME", "unknown"),
            )
        )
    return result


def drain(sel: selectors.BaseSelector) -> None:
    while True:
        ready = sel.select(timeout=0)
        if not ready:
            return
        for key, _ in ready:
            try:
                os.read(key.fd, 4096)
            except BlockingIOError:
                pass


def capture_step(sel: selectors.BaseSelector, label: str, seconds: float) -> None:
    print()
    print(f"=== {label} ===")
    print(f"Press/release it once or twice during the next {seconds:.1f}s.")
    sys.stdout.flush()
    drain(sel)
    start = time.monotonic()
    count = 0
    while time.monotonic() - start < seconds:
        remaining = max(0.0, seconds - (time.monotonic() - start))
        for key, _ in sel.select(timeout=min(0.15, remaining)):
            while True:
                try:
                    packet = os.read(key.fd, 4096)
                except BlockingIOError:
                    break
                if not packet:
                    break
                count += 1
                elapsed = time.monotonic() - start
                node, product = key.data
                print(
                    f"{elapsed:6.3f}s product={product:04x} node={node} "
                    f"len={len(packet):02d} data={packet.hex(' ')}"
                )
                sys.stdout.flush()
    if count == 0:
        print("NO_HIDRAW_PACKETS")


def tty_noecho() -> tuple[int, list] | None:
    if not sys.stdin.isatty():
        return None
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    new = termios.tcgetattr(fd)
    new[3] &= ~termios.ECHO
    termios.tcsetattr(fd, termios.TCSANOW, new)
    return fd, old


def restore_tty(state: tuple[int, list] | None) -> None:
    if state is None:
        return
    fd, old = state
    try:
        termios.tcsetattr(fd, termios.TCSANOW, old)
    except termios.error:
        pass


def main() -> int:
    mode = "missing"
    duration = 1.8
    args = sys.argv[1:]
    if args and args[0] in {"missing", "all"}:
        mode = args.pop(0)
    if args:
        try:
            duration = max(1.0, min(8.0, float(args.pop(0))))
        except ValueError:
            print(f"usage: sudo {sys.argv[0]} [missing|all] [seconds-per-step]", file=sys.stderr)
            return 2
    if args:
        print(f"usage: sudo {sys.argv[0]} [missing|all] [seconds-per-step]", file=sys.stderr)
        return 2

    found = devices()
    if not found:
        print("No ASUS 0B05:0220/4543 hidraw devices found.", file=sys.stderr)
        return 3

    sel = selectors.DefaultSelector()
    opened: list[int] = []
    tty_state = None
    try:
        print("===== A14 F-ROW RAW HID PROBE =====")
        print(f"mode={mode}")
        for node, product, driver, name in found:
            try:
                fd = os.open(node, os.O_RDONLY | os.O_NONBLOCK)
            except OSError as error:
                print(f"device={node} product={product:04x} ERROR={error}")
                continue
            opened.append(fd)
            sel.register(fd, selectors.EVENT_READ, (str(node), product))
            print(f"device={node} product={product:04x} driver={driver} name={name}")

        if not opened:
            return 4

        tty_state = tty_noecho()
        print()
        print("Do not change Fn-lock state during this probe.")
        print("The probe only listens; normal key actions still reach the desktop.")

        if mode == "missing":
            steps = (
                "Fn+F2",
                "Fn+F3",
                "Fn+F6",
                "Fn+F7",
                "Fn+F9",
                "Fn+F10",
                "Fn+F11",
                "Fn+F12",
            )
        else:
            steps = tuple(
                item
                for number in range(1, 13)
                for item in (f"F{number} ALONE", f"Fn+F{number}")
            ) + ("Fn+Esc",)

        for label in steps:
            capture_step(sel, label, duration)

        print()
        print("A14_FN_ROW_RAW_PROBE=COMPLETE")
        return 0
    except KeyboardInterrupt:
        print("\nA14_FN_ROW_RAW_PROBE=INTERRUPTED")
        return 130
    finally:
        restore_tty(tty_state)
        sel.close()
        for fd in opened:
            try:
                os.close(fd)
            except OSError:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
