#!/usr/bin/env python3
"""Direct, dependency-free ASUS A14 Fn-lock HID probe.

GET_REPORT uses a 64-byte buffer, matching upstream hid-asus. SET_REPORT
commands are deliberately sent at their real command lengths; in particular
Fn-lock is exactly 4 bytes: 5a d0 4e <0|1>.

The ``functions`` action mirrors upstream asus_kbd_get_functions(): it sends
5a 05 20 31 00 08, immediately performs GET_REPORT, and prints response byte 6,
which upstream treats as the keyboard-function capability bitmap.

This does not change driver bindings. It can probe ASUS 0B05:0220 (keyboard)
and 0B05:4543 (HDTL auxiliary endpoint) independently.
"""

from __future__ import annotations

import fcntl
from pathlib import Path
import sys
import time

ASUS_VENDOR = 0x0B05
PRODUCTS = {0x0220, 0x4543}
REPORT_ID = 0x5A
GET_REPORT_LEN = 64
FUNCTION_QUERY = bytes((0x5A, 0x05, 0x20, 0x31, 0x00, 0x08))

_IOC_NRBITS = 8
_IOC_TYPEBITS = 8
_IOC_SIZEBITS = 14
_IOC_NRSHIFT = 0
_IOC_TYPESHIFT = _IOC_NRSHIFT + _IOC_NRBITS
_IOC_SIZESHIFT = _IOC_TYPESHIFT + _IOC_TYPEBITS
_IOC_DIRSHIFT = _IOC_SIZESHIFT + _IOC_SIZEBITS
_IOC_WRITE = 1
_IOC_READ = 2


def _ioc(direction: int, kind: int, nr: int, size: int) -> int:
    return (
        (direction << _IOC_DIRSHIFT)
        | (kind << _IOC_TYPESHIFT)
        | (nr << _IOC_NRSHIFT)
        | (size << _IOC_SIZESHIFT)
    )


def hid_iocsfeature(length: int) -> int:
    return _ioc(_IOC_WRITE | _IOC_READ, ord("H"), 0x06, length)


def hid_iogfeature(length: int) -> int:
    return _ioc(_IOC_WRITE | _IOC_READ, ord("H"), 0x07, length)


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


def parse_hid_id(value: str) -> tuple[int, int] | None:
    try:
        _bus, vendor, product = value.split(":", 2)
        return int(vendor, 16), int(product, 16)
    except (ValueError, AttributeError):
        return None


def driver_name(device: Path) -> str:
    try:
        return (device / "driver").resolve().name
    except OSError:
        return "unbound"


def candidates() -> list[tuple[Path, int, str, str]]:
    found: list[tuple[Path, int, str, str]] = []
    for cls in sorted(Path("/sys/class/hidraw").glob("hidraw*")):
        device = cls / "device"
        info = read_uevent(device / "uevent")
        ident = parse_hid_id(info.get("HID_ID", ""))
        if not ident:
            continue
        vendor, product = ident
        if vendor != ASUS_VENDOR or product not in PRODUCTS:
            continue
        found.append(
            (
                Path("/dev") / cls.name,
                product,
                info.get("HID_NAME", "unknown"),
                driver_name(device),
            )
        )
    return found


def feature_get(fd: int, length: int = GET_REPORT_LEN) -> bytes:
    buf = bytearray(length)
    buf[0] = REPORT_ID
    fcntl.ioctl(fd, hid_iogfeature(length), buf, True)
    return bytes(buf)


def feature_set_exact(fd: int, report: bytes) -> bytes:
    if not report or report[0] != REPORT_ID:
        raise ValueError("SET_REPORT must include report ID 0x5a as byte 0")
    buf = bytearray(report)
    fcntl.ioctl(fd, hid_iocsfeature(len(buf)), buf, True)
    return bytes(buf)


def query_functions(fd: int) -> bytes:
    feature_set_exact(fd, FUNCTION_QUERY)
    time.sleep(0.03)
    return feature_get(fd)


def asus_init(fd: int) -> None:
    # Mirrors the known ASUS keyboard bring-up without changing backlight.
    commands = (
        bytes((0x5A, 0x41, 0x53, 0x55, 0x53, 0x20, 0x54, 0x65,
               0x63, 0x68, 0x2E, 0x49, 0x6E, 0x63, 0x2E, 0x00)),
        FUNCTION_QUERY,
        bytes((0x5A, 0xD0, 0x8F, 0x01, 0x00, 0x00)),
        bytes((0x5A, 0xD0, 0x85, 0xFF, 0x00, 0x00)),
    )
    for report in commands:
        feature_set_exact(fd, report)
        time.sleep(0.03)


def selected(product_arg: str) -> list[tuple[Path, int, str, str]]:
    devices = candidates()
    if product_arg == "all":
        return devices
    product = int(product_arg, 16)
    return [entry for entry in devices if entry[1] == product]


def main() -> int:
    action = sys.argv[1] if len(sys.argv) > 1 else "status"
    product_arg = sys.argv[2].lower() if len(sys.argv) > 2 else "all"
    actions = {"status", "functions", "init", "on", "off"}
    products = {"all", "0220", "4543"}
    if action not in actions or product_arg not in products:
        print(
            f"usage: {sys.argv[0]} {{status|functions|init|on|off}} [all|0220|4543]",
            file=sys.stderr,
        )
        return 2

    devices = selected(product_arg)
    if not devices:
        print(f"No matching ASUS hidraw device found for {product_arg}.")
        return 3

    failures = 0
    for node, product, name, driver in devices:
        print(f"device={node} product={product:04x} driver={driver} name={name}")
        try:
            with node.open("rb+", buffering=0) as stream:
                fd = stream.fileno()
                if action == "status":
                    response = feature_get(fd)
                    print(f"  get_report_len={GET_REPORT_LEN} feature_5a={response.hex(' ')}")
                elif action == "functions":
                    response = query_functions(fd)
                    bits = response[6] if len(response) > 6 else 0
                    print(
                        f"  FUNCTION_QUERY set_report_len={len(FUNCTION_QUERY)} "
                        f"sent={FUNCTION_QUERY.hex(' ')}"
                    )
                    print(f"  feature_5a={response.hex(' ')}")
                    print(f"  function_bits_byte6=0x{bits:02x}")
                    if bits == 0:
                        print("  GENERIC_ASUS_FUNCTION_BITMAP=EMPTY")
                elif action == "init":
                    asus_init(fd)
                    print("  ASUS_INIT=SET_REPORT_ACCEPTED lengths=16,6,6,6")
                else:
                    state = 1 if action == "on" else 0
                    sent = feature_set_exact(fd, bytes((0x5A, 0xD0, 0x4E, state)))
                    print(
                        f"  FNLOCK_SET state={state} set_report_len={len(sent)} "
                        f"sent={sent.hex(' ')}"
                    )
                    try:
                        response = feature_get(fd)
                        print(f"  feature_5a_after={response.hex(' ')}")
                    except OSError as error:
                        print(f"  GET_REPORT_after_failed={error}")
        except (OSError, PermissionError) as error:
            failures += 1
            print(f"  ERROR={error}")

    return 1 if failures == len(devices) else 0


if __name__ == "__main__":
    raise SystemExit(main())
