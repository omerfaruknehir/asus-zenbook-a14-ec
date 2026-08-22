#!/usr/bin/env python3
"""A14 cold-state keyboard-light ownership A/B.

This deliberately sends only the legacy 0B05:0220 Feature report that the
original working Linux HID driver used before a normal keyboard-light level:

    5a d0 8f 01

It is a diagnostic, not yet a claimed Windows "breathing mode" API.  Run it
while the keyboard is stuck in firmware breathing after a true cold boot.  If
breathing stops, optionally send a native static brightness 0..3 immediately
afterwards with --brightness.
"""

import argparse
import fcntl
import os
from pathlib import Path
import sys

VENDOR = 0x0B05
PRODUCT = 0x0220
REPORT_SIZE = 64

# linux/include/uapi/linux/hidraw.h:
#   #define HIDIOCSFEATURE(len) _IOC(_IOC_WRITE|_IOC_READ, 'H', 0x06, len)
_IOC_NRBITS = 8
_IOC_TYPEBITS = 8
_IOC_SIZEBITS = 14
_IOC_NRSHIFT = 0
_IOC_TYPESHIFT = _IOC_NRSHIFT + _IOC_NRBITS
_IOC_SIZESHIFT = _IOC_TYPESHIFT + _IOC_TYPEBITS
_IOC_DIRSHIFT = _IOC_SIZESHIFT + _IOC_SIZEBITS
_IOC_WRITE = 1
_IOC_READ = 2


def _ioc(direction: int, typ: int, nr: int, size: int) -> int:
    return ((direction << _IOC_DIRSHIFT) |
            (typ << _IOC_TYPESHIFT) |
            (nr << _IOC_NRSHIFT) |
            (size << _IOC_SIZESHIFT))


def hid_iocsfeature(length: int) -> int:
    return _ioc(_IOC_WRITE | _IOC_READ, ord('H'), 0x06, length)


def find_keyboard_hidraw() -> Path:
    matches = []
    for sysdev in sorted(Path('/sys/class/hidraw').glob('hidraw*')):
        uevent = sysdev / 'device' / 'uevent'
        try:
            fields = dict(
                line.split('=', 1)
                for line in uevent.read_text().splitlines()
                if '=' in line
            )
        except OSError:
            continue
        hid_id = fields.get('HID_ID', '')
        parts = hid_id.split(':')
        if len(parts) != 3:
            continue
        try:
            vendor = int(parts[1], 16)
            product = int(parts[2], 16)
        except ValueError:
            continue
        if vendor == VENDOR and product == PRODUCT:
            matches.append(Path('/dev') / sysdev.name)

    if len(matches) != 1:
        raise RuntimeError(
            f'expected exactly one 0B05:0220 hidraw device, found {matches}')
    return matches[0]


def set_feature(fd: int, payload: bytes, label: str) -> None:
    if len(payload) > REPORT_SIZE:
        raise ValueError('payload too large')
    report = bytearray(REPORT_SIZE)
    report[:len(payload)] = payload
    fcntl.ioctl(fd, hid_iocsfeature(REPORT_SIZE), report, True)
    print(f'{label}: ' + ' '.join(f'{b:02x}' for b in payload))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        '--brightness', type=int, choices=range(4), metavar='0..3',
        help='after takeover, also send native static brightness 0..3')
    args = parser.parse_args()

    path = find_keyboard_hidraw()
    print(f'device={path}')
    print('before running: observe whether the keyboard is physically breathing')

    fd = os.open(path, os.O_RDWR | os.O_CLOEXEC)
    try:
        set_feature(fd, bytes((0x5A, 0xD0, 0x8F, 0x01)),
                    'legacy-static-takeover')
        if args.brightness is not None:
            set_feature(fd,
                        bytes((0x5A, 0xBA, 0xC5, 0xC4, args.brightness)),
                        f'static-brightness-{args.brightness}')
    finally:
        os.close(fd)

    print('observe the physical keyboard LEDs now; no software readback is assumed')
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f'error: {exc}', file=sys.stderr)
        raise SystemExit(1)
