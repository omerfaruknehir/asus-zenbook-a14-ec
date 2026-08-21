#!/usr/bin/env python3
"""Direct ASUS A14 keyboard-backlight/F4 firmware probe.

Targets the UX3407RA keyboard HID collection used by ASUSOptimization:

  VID:PID                  0b05:0220
  report ID                5a
  feature report length    64 bytes
  brightness command       5a ba c5 c4 <level 0..3>
  F4 input event           5a c7 ...

The ``sequence`` action performs ASUSOptimization's harmless feature-session
priming, sends all four real hardware levels, and restores the prior Linux LED
level.  It does not reload modules or touch the EC/fan controller.
"""

from __future__ import annotations

import fcntl
import os
from pathlib import Path
import selectors
import sys
import time

ASUS_VENDOR = 0x0B05
ASUS_PRODUCT = 0x0220
REPORT_ID = 0x5A
FEATURE_LEN = 64
FUNCTION_QUERY = bytes((0x5A, 0x05, 0x20, 0x31, 0x00, 0x08))
WINDOWS_INIT = bytes((REPORT_ID,)) + b"ASUS Tech.Inc." + b"\x00"
BACKLIGHT_PREFIX = bytes((REPORT_ID, 0xBA, 0xC5, 0xC4))
F4_USAGE = 0xC7
LED = Path("/sys/class/leds/asus::kbd_backlight")
EC_STATUS = Path(
    "/sys/bus/platform/devices/asus_zenbook_a14_ec/kbd_backlight_ec_status"
)

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


def find_device() -> tuple[Path, str, str]:
    matches: list[tuple[Path, str, str]] = []
    for cls in sorted(Path("/sys/class/hidraw").glob("hidraw*")):
        device = cls / "device"
        info = read_uevent(device / "uevent")
        if parse_hid_id(info.get("HID_ID", "")) != (ASUS_VENDOR, ASUS_PRODUCT):
            continue
        try:
            driver = (device / "driver").resolve().name
        except OSError:
            driver = "unbound"
        matches.append(
            (Path("/dev") / cls.name, driver, info.get("HID_NAME", "unknown"))
        )
    if not matches:
        raise RuntimeError("no ASUS 0b05:0220 hidraw device found")
    if len(matches) != 1:
        nodes = ", ".join(str(item[0]) for item in matches)
        raise RuntimeError(f"multiple ASUS 0b05:0220 hidraw devices found: {nodes}")
    return matches[0]


def feature_get(fd: int) -> bytes:
    report = bytearray(FEATURE_LEN)
    report[0] = REPORT_ID
    fcntl.ioctl(fd, hid_iogfeature(FEATURE_LEN), report, True)
    return bytes(report)


def feature_set(fd: int, payload: bytes) -> bytes:
    if not payload or payload[0] != REPORT_ID or len(payload) > FEATURE_LEN:
        raise ValueError("invalid report 0x5a feature payload")
    report = bytearray(FEATURE_LEN)
    report[:len(payload)] = payload
    fcntl.ioctl(fd, hid_iocsfeature(FEATURE_LEN), report, True)
    return bytes(report)


def known_feature(report: bytes) -> bool:
    if report.startswith(WINDOWS_INIT):
        return True
    return len(report) >= 2 and report[0] == REPORT_ID and report[1] in {
        0x05, 0xB0, 0xB1, 0xBA, 0xBB, 0xC2, 0xD0, 0xF4
    }


def prime_like_windows(fd: int) -> bytes:
    """Mirror ASUSOptimization's GET/conditional init/config SET+GET path."""
    try:
        initial = feature_get(fd)
    except OSError:
        initial = b""
    print("initial_feature=" + (initial.hex(" ") if initial else "GET_FAILED"))

    if not known_feature(initial):
        sent = feature_set(fd, WINDOWS_INIT)
        print(f"windows_init_sent={sent[:20].hex(' ')}")
        time.sleep(0.03)
    else:
        print("windows_init_sent=SKIPPED_KNOWN_FEATURE_FAMILY")

    sent = feature_set(fd, FUNCTION_QUERY)
    print(f"config_set={sent[:12].hex(' ')}")
    time.sleep(0.03)

    last_error: OSError | None = None
    for _ in range(4):
        try:
            response = feature_get(fd)
            if response.startswith(FUNCTION_QUERY):
                print(f"config_get={response.hex(' ')}")
                if len(response) >= 9:
                    print(
                        "capabilities="
                        f"{response[6]:02x} {response[7]:02x} {response[8]:02x}"
                    )
                return response
        except OSError as error:
            last_error = error
        time.sleep(0.05)
    if last_error:
        raise last_error
    raise RuntimeError("configuration GET did not return the expected prefix")


def set_level(fd: int, level: int) -> None:
    if level not in range(4):
        raise ValueError("hardware brightness level must be 0, 1, 2, or 3")
    sent = feature_set(fd, BACKLIGHT_PREFIX + bytes((level,)))
    print(f"level={level} set_feature={sent[:12].hex(' ')}")


def cached_native_level() -> int:
    try:
        brightness = int((LED / "brightness").read_text().strip())
        maximum = int((LED / "max_brightness").read_text().strip())
    except (OSError, ValueError):
        return 1
    if maximum <= 0:
        return 1
    return max(0, min(3, round(brightness * 3 / maximum)))


def read_ec_status() -> int | None:
    try:
        return int(EC_STATUS.read_text().strip(), 0)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as error:
        raise RuntimeError(f"cannot read {EC_STATUS}: {error}") from error


def print_ec_status(label: str, required: bool = False) -> None:
    status = read_ec_status()
    if status is None:
        if required:
            raise RuntimeError(
                f"{EC_STATUS} is missing; install/reload diagnostic version 0.5.12"
            )
        print(f"{label}_ec_status=UNAVAILABLE")
        return
    masked = status & 0x06
    logical = masked >> 1
    print(
        f"{label}_ec_status=0x{status:02x} "
        f"masked_0x06=0x{masked:02x} dsdt_logical={logical}"
    )


def run_sequence(fd: int, delay: float, require_ec_status: bool = False) -> None:
    restore = cached_native_level()
    print(f"restore_level={restore}")
    prime_like_windows(fd)
    print_ec_status("initial", require_ec_status)
    try:
        for level in range(4):
            set_level(fd, level)
            time.sleep(0.15)
            print_ec_status(f"level_{level}", require_ec_status)
            time.sleep(max(0.0, delay - 0.15))
    finally:
        set_level(fd, restore)
        time.sleep(0.15)
        print_ec_status("restored", require_ec_status)
        print("physical_level_restored=yes")


def capture_f4(node: Path, seconds: float) -> bool:
    print(f"Press the keyboard-backlight key / Fn+F4 during the next {seconds:g}s.")
    fd = os.open(node, os.O_RDONLY | os.O_NONBLOCK)
    selector = selectors.DefaultSelector()
    selector.register(fd, selectors.EVENT_READ)
    found = False
    try:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            for _key, _mask in selector.select(timeout=min(0.25, remaining)):
                while True:
                    try:
                        report = os.read(fd, 4096)
                    except BlockingIOError:
                        break
                    if not report:
                        break
                    print(f"input_report={report.hex(' ')}")
                    if len(report) >= 2 and report[0] == REPORT_ID and report[1] == F4_USAGE:
                        found = True
                        print("F4_USAGE_C7=SEEN")
    finally:
        selector.close()
        os.close(fd)
    if not found:
        print("F4_USAGE_C7=NOT_SEEN")
    return found


def usage() -> int:
    print(
        f"usage: sudo {sys.argv[0]} status | level <0..3> | "
        "sequence [delay] | correlate [delay] | f4 [seconds]",
        file=sys.stderr,
    )
    return 2


def main() -> int:
    if len(sys.argv) < 2:
        return usage()
    action = sys.argv[1]
    try:
        node, driver, name = find_device()
        print(f"device={node} product=0220 driver={driver} name={name}")
        if action == "f4":
            seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 10.0
            return 0 if capture_f4(node, max(2.0, min(60.0, seconds))) else 1
        with node.open("rb+", buffering=0) as stream:
            fd = stream.fileno()
            if action == "status" and len(sys.argv) == 2:
                response = feature_get(fd)
                print(f"feature_5a={response.hex(' ')}")
                return 0
            if action == "level" and len(sys.argv) == 3:
                set_level(fd, int(sys.argv[2], 0))
                return 0
            if action == "sequence" and len(sys.argv) <= 3:
                delay = float(sys.argv[2]) if len(sys.argv) == 3 else 1.5
                run_sequence(fd, max(0.5, min(10.0, delay)))
                return 0
            if action == "correlate" and len(sys.argv) <= 3:
                delay = float(sys.argv[2]) if len(sys.argv) == 3 else 1.0
                run_sequence(
                    fd, max(0.5, min(10.0, delay)), require_ec_status=True
                )
                return 0
    except KeyboardInterrupt:
        print("A14_KBD_PROBE=INTERRUPTED", file=sys.stderr)
        return 130
    except (OSError, RuntimeError, ValueError) as error:
        print(f"ERROR={error}", file=sys.stderr)
        return 1
    return usage()


if __name__ == "__main__":
    raise SystemExit(main())
