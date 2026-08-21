#!/usr/bin/env python3
"""Read-only correlation probe for the A14's secondary ASUS HID 0B05:4543.

The live UX3407RA descriptor declares two Feature reports:

* report 0x06: 144 payload bits, 19 bytes on the wire including report ID
* report 0x5a: 128 payload bits, 17 bytes on the wire including report ID

No feature report is ever written to 0B05:4543.  The ``correlate`` action only
uses the already-proven ``asus::kbd_backlight`` LED interface (0..3), reads the
two 4543 feature reports after each level, and restores the original level.
"""

from __future__ import annotations

import fcntl
from pathlib import Path
import sys
import time

ASUS_VENDOR = 0x0B05
ASUS_4543 = 0x4543
FEATURE_REPORTS = ((0x06, 19), (0x5A, 17))
LED = Path("/sys/class/leds/asus::kbd_backlight")

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


def find_4543() -> tuple[Path, str, str]:
    matches: list[tuple[Path, str, str]] = []
    for cls in sorted(Path("/sys/class/hidraw").glob("hidraw*")):
        device = cls / "device"
        info = read_uevent(device / "uevent")
        if parse_hid_id(info.get("HID_ID", "")) != (ASUS_VENDOR, ASUS_4543):
            continue
        try:
            driver = (device / "driver").resolve().name
        except OSError:
            driver = "unbound"
        matches.append(
            (Path("/dev") / cls.name, driver, info.get("HID_NAME", "unknown"))
        )
    if not matches:
        raise RuntimeError("no ASUS 0b05:4543 hidraw device found")
    if len(matches) != 1:
        raise RuntimeError(
            "multiple ASUS 0b05:4543 nodes: "
            + ", ".join(str(item[0]) for item in matches)
        )
    return matches[0]


def feature_get(fd: int, report_id: int, length: int) -> bytes:
    report = bytearray(length)
    report[0] = report_id
    fcntl.ioctl(fd, hid_iogfeature(length), report, True)
    return bytes(report)


def snapshot(fd: int, label: str) -> None:
    for report_id, length in FEATURE_REPORTS:
        try:
            data = feature_get(fd, report_id, length)
        except OSError as error:
            print(
                f"{label}_feature_{report_id:02x}=GET_FAILED "
                f"errno={error.errno} error={error.strerror}"
            )
        else:
            print(
                f"{label}_feature_{report_id:02x}="
                f"len:{len(data)} data:{data.hex(' ')}"
            )


def led_state() -> tuple[Path, int, int]:
    brightness = LED / "brightness"
    maximum = int((LED / "max_brightness").read_text().strip())
    current = int(brightness.read_text().strip())
    if maximum != 3 or current not in range(4):
        raise RuntimeError(
            f"expected proven 0..3 LED interface, got brightness={current} "
            f"max_brightness={maximum}"
        )
    return brightness, current, maximum


def correlate(fd: int, delay: float) -> None:
    brightness, original, maximum = led_state()
    print(f"proven_led={LED} original={original} max_brightness={maximum}")
    print("unknown_feature_writes_to_4543=NONE")
    snapshot(fd, "initial")
    try:
        for level in range(4):
            brightness.write_text(f"{level}\n")
            time.sleep(delay)
            print(f"known_0220_level={level} reported={brightness.read_text().strip()}")
            snapshot(fd, f"level_{level}")
    finally:
        brightness.write_text(f"{original}\n")
        time.sleep(delay)
        print(
            f"restored_0220_level={original} "
            f"reported={brightness.read_text().strip()}"
        )
        snapshot(fd, "restored")


def usage() -> int:
    print(
        f"usage: sudo {sys.argv[0]} status | correlate [delay]",
        file=sys.stderr,
    )
    return 2


def main() -> int:
    if len(sys.argv) < 2:
        return usage()
    try:
        node, driver, name = find_4543()
        print(f"device={node} product=4543 driver={driver} name={name}")
        with node.open("rb+", buffering=0) as stream:
            if sys.argv[1] == "status" and len(sys.argv) == 2:
                print("unknown_feature_writes_to_4543=NONE")
                snapshot(stream.fileno(), "status")
                return 0
            if sys.argv[1] == "correlate" and len(sys.argv) <= 3:
                delay = float(sys.argv[2]) if len(sys.argv) == 3 else 0.5
                correlate(stream.fileno(), max(0.1, min(5.0, delay)))
                return 0
    except KeyboardInterrupt:
        print("A14_4543_PROBE=INTERRUPTED", file=sys.stderr)
        return 130
    except (OSError, RuntimeError, ValueError) as error:
        print(f"ERROR={error}", file=sys.stderr)
        return 1
    return usage()


if __name__ == "__main__":
    raise SystemExit(main())
