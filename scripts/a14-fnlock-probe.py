#!/usr/bin/env python3
"""Direct, dependency-free ASUS A14 Fn-lock feature-report probe.

This intentionally does not change driver bindings. It opens existing hidraw
nodes for ASUS 0B05:0220 / 0B05:4543 and sends the documented 5A D0 4E state
command so we can identify which physical HID endpoint owns Fn-lock.
"""

from __future__ import annotations

import errno
import fcntl
import os
from pathlib import Path
import sys

ASUS_VENDOR = 0x0B05
PRODUCTS = {0x0220, 0x4543}
REPORT_ID = 0x5A

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
    link = device / "driver"
    try:
        return link.resolve().name
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


def feature_get(fd: int, length: int) -> bytes:
    buf = bytearray(length)
    buf[0] = REPORT_ID
    fcntl.ioctl(fd, hid_iogfeature(length), buf, True)
    return bytes(buf)


def feature_set(fd: int, payload: bytes, length: int) -> bytes:
    if len(payload) + 1 > length:
        raise ValueError("feature payload is too large")
    buf = bytearray(length)
    buf[0] = REPORT_ID
    buf[1 : 1 + len(payload)] = payload
    fcntl.ioctl(fd, hid_iocsfeature(length), buf, True)
    return bytes(buf)


def working_length(fd: int) -> int:
    errors: list[str] = []
    for length in (64, 16):
        try:
            feature_get(fd, length)
            return length
        except OSError as error:
            errors.append(f"{length}:{error.errno}/{error.strerror}")
    raise OSError(errno.EINVAL, "no usable 0x5a feature-report length (" + ", ".join(errors) + ")")


def selected(product_arg: str) -> list[tuple[Path, int, str, str]]:
    devices = candidates()
    if product_arg == "all":
        return devices
    product = int(product_arg, 16)
    return [entry for entry in devices if entry[1] == product]


def main() -> int:
    action = sys.argv[1] if len(sys.argv) > 1 else "status"
    product_arg = sys.argv[2].lower() if len(sys.argv) > 2 else "all"
    if action not in {"status", "on", "off"} or product_arg not in {"all", "0220", "4543"}:
        print(f"usage: {sys.argv[0]} {{status|on|off}} [all|0220|4543]", file=sys.stderr)
        return 2

    devices = selected(product_arg)
    if not devices:
        print(f"No matching ASUS hidraw device found for {product_arg}.")
        return 3

    for node, product, name, driver in devices:
        print(f"device={node} product={product:04x} driver={driver} name={name}")
        if action == "status":
            try:
                with node.open("rb+", buffering=0) as stream:
                    length = working_length(stream.fileno())
                    response = feature_get(stream.fileno(), length)
                print(f"  report_len={length} feature_5a={response.hex(' ')}")
            except (OSError, PermissionError) as error:
                print(f"  read_error={error}")
            continue

        state = 1 if action == "on" else 0
        try:
            with node.open("rb+", buffering=0) as stream:
                length = working_length(stream.fileno())
                sent = feature_set(stream.fileno(), bytes((0xD0, 0x4E, state)), length)
                try:
                    response = feature_get(stream.fileno(), length)
                    readback = response.hex(" ")
                except OSError as error:
                    readback = f"GET failed: {error}"
            print(
                f"  FNLOCK_SET state={state} report_len={length} "
                f"sent={sent[:8].hex(' ')} readback={readback}"
            )
        except (OSError, PermissionError) as error:
            print(f"  write_error={error}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
