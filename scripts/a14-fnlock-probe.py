#!/usr/bin/env python3
"""Direct, dependency-free ASUS A14 Fn-lock HID probe.

Windows reference captured on UX3407RA with ASUSOptimization.exe 2.1.75.0:
  VID=0B05 PID=0220 UsagePage=FF31 Usage=0076
  FeatureReportByteLength=64
  Fn-switch payload = [5a d0 4e <state>] zero-padded to all 64 bytes.

Re-disassembly of the exact ASUSOptimization.exe captured from the machine also
shows that Fn-switch is not the first transaction on a fresh service/device
session.  The relevant startup path uses ONE open HID handle and performs:

  1. SET_FEATURE 64 bytes:
       5a + ASCII "ASUS Tech.Inc." + NUL + zero padding
  2. SET_FEATURE 64 bytes:
       5a 05 20 31 00 08 + zero padding       (Configuration query)
  3. GET_FEATURE 64 bytes, report id 5a, and parse capability bytes
  4. SET_FEATURE 64 bytes:
       5a d0 4e <state> + zero padding        (Fn switch)

The ``win-off`` and ``win-on`` actions reproduce those operations in that order
without closing/reopening /dev/hidraw between them.  This is deliberately more
faithful than the older separate ``init`` then ``on/off`` invocations.

Observed Windows state semantics:
  state 0: ASUS/media action keys are primary; Fn+F1..F12 produces F1..F12
  state 1: F1..F12 are primary; Fn+F1..F12 produces ASUS/media actions

Product 4543 remains available only for historical comparison; it is not the
Windows Fn-switch target.
"""

from __future__ import annotations

import fcntl
from pathlib import Path
import sys
import time

ASUS_VENDOR = 0x0B05
PRODUCTS = {0x0220, 0x4543}
FNLOCK_PRODUCT = 0x0220
REPORT_ID = 0x5A
FEATURE_REPORT_LEN = 64
GET_REPORT_LEN = 64
FUNCTION_QUERY = bytes((0x5A, 0x05, 0x20, 0x31, 0x00, 0x08))
SUPPORT_KBD_BACKLIGHT = 0x01
# ASUSOptimization constructs 16 meaningful initial bytes: report ID, the
# 14-byte ASCII string, then an explicit NUL.  Full feature length is 64.
WINDOWS_INIT = bytes((REPORT_ID,)) + b"ASUS Tech.Inc." + b"\x00"

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


def feature_set_full(fd: int, report: bytes, length: int = FEATURE_REPORT_LEN) -> bytes:
    if not report or report[0] != REPORT_ID:
        raise ValueError("SET_REPORT must include report ID 0x5a as byte 0")
    if len(report) > length:
        raise ValueError("report is larger than the Windows feature-report length")
    buf = bytearray(length)
    buf[:len(report)] = report
    fcntl.ioctl(fd, hid_iocsfeature(length), buf, True)
    return bytes(buf)


def query_functions_exact(fd: int) -> bytes:
    feature_set_exact(fd, FUNCTION_QUERY)
    time.sleep(0.03)
    return feature_get(fd)


def windows_init(fd: int) -> bytes:
    return feature_set_full(fd, WINDOWS_INIT)


def windows_service_sequence(fd: int, state: int) -> tuple[bytes, bytes, bytes, bytes]:
    """Mirror the relevant ASUSOptimization startup + Fn-switch path."""
    init_sent = feature_set_full(fd, WINDOWS_INIT)
    time.sleep(0.03)

    config_sent = feature_set_full(fd, FUNCTION_QUERY)
    time.sleep(0.03)

    # ASUSOptimization uses a full FeatureReportByteLength GET with report ID 5a.
    # Retry briefly because the Windows implementation also tolerates delayed
    # configuration responses.
    response = b""
    last_error: OSError | None = None
    for _ in range(4):
        try:
            response = feature_get(fd)
            if len(response) >= 8 and response[0] == REPORT_ID:
                break
        except OSError as error:
            last_error = error
        time.sleep(0.05)
    else:
        if last_error is not None:
            raise last_error
        raise OSError("configuration GET_FEATURE never returned a valid report 0x5a")

    fn_sent = feature_set_full(fd, bytes((REPORT_ID, 0xD0, 0x4E, state)))
    return init_sent, config_sent, response, fn_sent


def legacy_init(fd: int) -> None:
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


def print_config_response(response: bytes) -> None:
    print(f"  CONFIG_GET_FEATURE len={len(response)} data={response.hex(' ')}")
    if len(response) >= 9:
        print(
            "  CONFIG_CAP_BYTES="
            f"byte6=0x{response[6]:02x} byte7=0x{response[7]:02x} "
            f"byte8=0x{response[8]:02x}"
        )


def main() -> int:
    action = sys.argv[1] if len(sys.argv) > 1 else "status"
    product_arg = sys.argv[2].lower() if len(sys.argv) > 2 else "0220"
    actions = {
        "status", "functions", "init", "legacy-init", "on", "off",
        "win-on", "win-off",
    }
    products = {"all", "0220", "4543"}
    if action not in actions or product_arg not in products:
        print(
            f"usage: {sys.argv[0]} "
            "{status|functions|init|legacy-init|on|off|win-on|win-off} "
            "[0220|4543|all]",
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
        if action in {"init", "on", "off", "win-on", "win-off"} and product != FNLOCK_PRODUCT:
            print("  WARNING=Windows Fn-switch reference targets product 0220, not this endpoint")
        try:
            with node.open("rb+", buffering=0) as stream:
                fd = stream.fileno()
                if action == "status":
                    response = feature_get(fd)
                    print(f"  get_report_len={GET_REPORT_LEN} feature_5a={response.hex(' ')}")
                elif action == "functions":
                    response = query_functions_exact(fd)
                    bits = response[6] if len(response) > 6 else 0
                    print(
                        f"  FUNCTION_QUERY set_report_len={len(FUNCTION_QUERY)} "
                        f"sent={FUNCTION_QUERY.hex(' ')}"
                    )
                    print(f"  feature_5a={response.hex(' ')}")
                    print(f"  function_bits_byte6=0x{bits:02x}")
                    print(
                        "  SUPPORT_KBD_BACKLIGHT="
                        + ("YES" if bits & SUPPORT_KBD_BACKLIGHT else "NO")
                    )
                    unknown = bits & ~SUPPORT_KBD_BACKLIGHT
                    print(f"  unknown_function_bits=0x{unknown:02x}")
                    print("  FNLOCK_CAPABILITY_BIT=NOT_DEFINED_BY_UPSTREAM_QUERY")
                elif action == "init":
                    sent = windows_init(fd)
                    print(
                        f"  WINDOWS_INPUT_INIT=SET_REPORT_ACCEPTED len={len(sent)} "
                        f"sent_prefix={sent[:20].hex(' ')}"
                    )
                    print('  INIT_STRING=ASUS Tech.Inc. + explicit NUL; zero-padded to 64')
                elif action == "legacy-init":
                    legacy_init(fd)
                    print("  LEGACY_INIT=SET_REPORT_ACCEPTED lengths=16,6,6,6")
                elif action in {"win-on", "win-off"}:
                    state = 1 if action == "win-on" else 0
                    init_sent, config_sent, response, fn_sent = windows_service_sequence(fd, state)
                    print(
                        f"  STEP1_WINDOWS_INIT len={len(init_sent)} "
                        f"prefix={init_sent[:20].hex(' ')}"
                    )
                    print(
                        f"  STEP2_CONFIG_SET len={len(config_sent)} "
                        f"prefix={config_sent[:12].hex(' ')}"
                    )
                    print_config_response(response)
                    print(
                        f"  STEP4_FNLOCK_SET state={state} len={len(fn_sent)} "
                        f"prefix={fn_sent[:12].hex(' ')}"
                    )
                    print(
                        "  MODE_REQUESTED="
                        + ("F1-F12-primary" if state else "ASUS-action-keys-primary")
                    )
                    print("  NOTE=behavioral verification still requires testing the physical F-row")
                else:
                    state = 1 if action == "on" else 0
                    sent = feature_set_full(fd, bytes((0x5A, 0xD0, 0x4E, state)))
                    print(
                        f"  FNLOCK_SET state={state} set_report_len={len(sent)} "
                        f"sent_prefix={sent[:8].hex(' ')}"
                    )
                    print(
                        "  MODE_REQUESTED="
                        + ("F1-F12-primary" if state else "ASUS-action-keys-primary")
                    )
                    print("  NOTE=SET_REPORT acceptance is not behavioral verification")
        except (OSError, PermissionError) as error:
            failures += 1
            print(f"  ERROR={error}")

    return 1 if failures == len(devices) else 0


if __name__ == "__main__":
    raise SystemExit(main())
