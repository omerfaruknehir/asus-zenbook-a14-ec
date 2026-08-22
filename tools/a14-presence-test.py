#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Standalone hardware test for the A14 SSC human-presence path.

This intentionally does NOT install a service or desktop integration. It builds
and loads the development qcom_ssc_hpd module, enables its IIO proximity-change
event, and consumes the kernel IIO event fd directly.

Expected hardware path:
  QRTR/QMI service 400 -> SUID discovery -> camera handshake 576/ACK 832
  -> HPD config 512 -> presence event 928 -> IIO proximity change event
"""

from __future__ import annotations

import argparse
import array
import errno
import fcntl
import os
from pathlib import Path
import select
import struct
import subprocess
import sys
import time

MODULE = "qcom_ssc_hpd"
IIO_NAME = "qcom-ssc-human-presence"
MODEL_COMPAT = b"asus,zenbook-a14-ux3407ra"

# include/uapi/linux/iio/events.h:
#   #define IIO_GET_EVENT_FD_IOCTL _IOR('i', 0x90, int)
_IOC_NRBITS = 8
_IOC_TYPEBITS = 8
_IOC_SIZEBITS = 14
_IOC_NRSHIFT = 0
_IOC_TYPESHIFT = _IOC_NRSHIFT + _IOC_NRBITS
_IOC_SIZESHIFT = _IOC_TYPESHIFT + _IOC_TYPEBITS
_IOC_DIRSHIFT = _IOC_SIZESHIFT + _IOC_SIZEBITS
_IOC_READ = 2
IIO_GET_EVENT_FD_IOCTL = (
    (_IOC_READ << _IOC_DIRSHIFT)
    | (ord("i") << _IOC_TYPESHIFT)
    | (0x90 << _IOC_NRSHIFT)
    | (struct.calcsize("i") << _IOC_SIZESHIFT)
)


def sh(cmd: list[str], *, check: bool = True, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        check=check,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def check_machine() -> None:
    compat = Path("/proc/device-tree/compatible")
    if not compat.exists():
        raise SystemExit("No device-tree compatible list found; refusing to probe unknown hardware.")
    data = compat.read_bytes()
    if MODEL_COMPAT not in data.split(b"\0"):
        pretty = data.replace(b"\0", b" ").decode(errors="replace")
        raise SystemExit(f"Unsupported machine; compatible={pretty}")


def build_module(root: Path) -> Path:
    aos = root / "kernel" / "aos"
    print(f"[build] {aos}")
    sh(["make", "-C", str(aos)])
    ko = aos / f"{MODULE}.ko"
    if not ko.is_file():
        raise SystemExit(f"Build completed but module is missing: {ko}")
    return ko


def require_root_after_build(args: argparse.Namespace) -> None:
    if os.geteuid() == 0:
        return
    print("[privilege] Re-running the hardware phase with sudo...")
    extra = ["--no-build"]
    if args.no_reload:
        extra.append("--no-reload")
    if args.keep_enabled:
        extra.append("--keep-enabled")
    if args.unload:
        extra.append("--unload")
    extra += ["--duration", str(args.duration)]
    os.execvp("sudo", ["sudo", "--", sys.executable, str(Path(__file__).resolve()), *extra])


def module_loaded() -> bool:
    return Path(f"/sys/module/{MODULE}").exists()


def load_module(ko: Path, reload_module: bool) -> None:
    if module_loaded() and reload_module:
        print(f"[module] unloading existing {MODULE}")
        sh(["rmmod", MODULE])
    if not module_loaded():
        print(f"[module] loading {ko}")
        sh(["insmod", str(ko)])
    else:
        print(f"[module] keeping currently loaded {MODULE}")


def find_iio_device(timeout: float = 8.0) -> Path:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for dev in sorted(Path("/sys/bus/iio/devices").glob("iio:device*")):
            try:
                if (dev / "name").read_text().strip() == IIO_NAME:
                    return dev
            except OSError:
                pass
        time.sleep(0.1)
    raise SystemExit(
        f"IIO device '{IIO_NAME}' did not appear. Check: journalctl -k -b | grep -E 'qcom-ssc-hpd|SSC QMI'"
    )


def find_event_enable(iio: Path) -> Path:
    events = iio / "events"
    matches = [
        p for p in events.glob("*_en")
        if "proximity" in p.name and "change" in p.name and "either" in p.name
    ]
    if len(matches) != 1:
        all_events = sorted(str(p) for p in events.glob("*")) if events.exists() else []
        raise SystemExit(
            "Could not uniquely locate the proximity CHANGE/EITHER enable node.\n"
            + "IIO event files:\n  " + "\n  ".join(all_events)
        )
    return matches[0]


def read_raw(iio: Path) -> int | None:
    raw = iio / "in_proximity_raw"
    try:
        return int(raw.read_text().strip())
    except OSError as exc:
        if exc.errno in (errno.ENODATA, errno.EAGAIN):
            return None
        raise
    except ValueError:
        return None


def state_text(value: int | None) -> str:
    if value is None:
        return "UNKNOWN (waiting for first SSC presence event)"
    if value == 1:
        return "PRESENT"
    if value == 0:
        return "AWAY"
    return f"UNKNOWN({value})"


def kernel_log_tail(seconds: int = 90) -> str:
    proc = sh(
        ["journalctl", "-k", "-b", f"--since=-{seconds}s", "--no-pager", "-o", "cat"],
        check=False,
        capture=True,
    )
    needles = (
        "qcom-ssc-hpd",
        "SSC datatype",
        "SSC QMI",
        "camera handshake",
        "presence activation",
        "human_presence_detect",
        "presence event",
        "SSC sensor error",
    )
    lines = [line for line in (proc.stdout or "").splitlines() if any(n in line for n in needles)]
    return "\n".join(lines[-120:])


def open_event_fd(iio: Path) -> tuple[int, int]:
    devnode = Path("/dev") / iio.name
    dev_fd = os.open(devnode, os.O_RDONLY | os.O_NONBLOCK)
    event_fd_arg = array.array("i", [-1])
    fcntl.ioctl(dev_fd, IIO_GET_EVENT_FD_IOCTL, event_fd_arg, True)
    event_fd = event_fd_arg[0]
    if event_fd < 0:
        os.close(dev_fd)
        raise OSError(errno.ENODEV, "IIO_GET_EVENT_FD_IOCTL returned no event fd")
    os.set_blocking(event_fd, False)
    return dev_fd, event_fd


def enable_presence(event_enable: Path) -> None:
    print(f"[activate] {event_enable} <- 1")
    try:
        event_enable.write_text("1\n")
    except OSError as exc:
        print(f"\nFAIL: kernel rejected presence activation: {exc}", file=sys.stderr)
        logs = kernel_log_tail()
        if logs:
            print("\nRelevant kernel log:", file=sys.stderr)
            print(logs, file=sys.stderr)
        if exc.errno == errno.ETIMEDOUT:
            print(
                "\nInterpretation: activation timed out. On the current development path this usually means "
                "camera handshake INIT 576 was sent but ACK 832 was not received; QRTR/QMI/SUID discovery may "
                "still be working correctly.",
                file=sys.stderr,
            )
        raise SystemExit(2)


def monitor(iio: Path, event_fd: int, duration: float) -> None:
    initial = read_raw(iio)
    print(f"[state] {state_text(initial)}")
    print("[monitor] Move into and out of the sensor range (driver test threshold is currently 1.5 m).")
    if duration > 0:
        print(f"[monitor] Listening for {duration:g} s; Ctrl-C stops early.")
    else:
        print("[monitor] Listening until Ctrl-C.")

    poller = select.poll()
    poller.register(event_fd, select.POLLIN | select.POLLERR | select.POLLHUP)
    deadline = time.monotonic() + duration if duration > 0 else None
    last = initial
    events_seen = 0
    next_raw_poll = 0.0

    while deadline is None or time.monotonic() < deadline:
        timeout_ms = 500
        if deadline is not None:
            timeout_ms = max(0, min(timeout_ms, int((deadline - time.monotonic()) * 1000)))
        ready = poller.poll(timeout_ms)
        for _fd, mask in ready:
            if mask & select.POLLIN:
                while True:
                    try:
                        blob = os.read(event_fd, 16)
                    except BlockingIOError:
                        break
                    if len(blob) < 16:
                        break
                    event_id, timestamp_ns = struct.unpack("=Qq", blob[:16])
                    value = read_raw(iio)
                    events_seen += 1
                    last = value
                    now = time.strftime("%H:%M:%S")
                    print(
                        f"[{now}] EVENT #{events_seen}: {state_text(value)} "
                        f"raw={value if value is not None else 'n/a'} "
                        f"event_id=0x{event_id:016x} iio_ts_ns={timestamp_ns}"
                    )
            if mask & (select.POLLERR | select.POLLHUP):
                raise SystemExit(f"IIO event fd reported mask=0x{mask:x}")

        # Also sample raw state as a diagnostic fallback. The kernel event fd is
        # authoritative, but this makes parser/state changes visible even if an
        # event-read ABI problem exists in userspace.
        now_mono = time.monotonic()
        if now_mono >= next_raw_poll:
            value = read_raw(iio)
            if value is not None and value != last:
                last = value
                print(f"[{time.strftime('%H:%M:%S')}] RAW CHANGE: {state_text(value)} raw={value}")
            next_raw_poll = now_mono + 0.5

    print(f"[summary] IIO events observed: {events_seen}; final state: {state_text(read_raw(iio))}")
    if events_seen == 0:
        print("[summary] No IIO presence transitions were observed. Relevant kernel log follows:")
        logs = kernel_log_tail(max(90, int(duration) + 15 if duration > 0 else 90))
        print(logs if logs else "(no matching SSC/HPD kernel messages in the recent journal)")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Build/load and live-test the ASUS A14 Qualcomm SSC human-presence IIO driver."
    )
    p.add_argument("--no-build", action="store_true", help="use the existing kernel/aos/qcom_ssc_hpd.ko")
    p.add_argument("--no-reload", action="store_true", help="do not replace an already-loaded qcom_ssc_hpd module")
    p.add_argument("--duration", type=float, default=0.0, help="seconds to monitor; 0 (default) means until Ctrl-C")
    p.add_argument("--keep-enabled", action="store_true", help="leave the IIO presence event enabled on exit")
    p.add_argument("--unload", action="store_true", help="unload qcom_ssc_hpd on exit")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    root = repo_root()
    check_machine()
    ko = root / "kernel" / "aos" / f"{MODULE}.ko"

    if not args.no_build:
        ko = build_module(root)

    require_root_after_build(args)

    if not ko.is_file():
        raise SystemExit(f"Module not found: {ko}; rerun without --no-build")

    load_module(ko, reload_module=not args.no_reload)
    iio = find_iio_device()
    event_enable = find_event_enable(iio)
    print(f"[iio] device={iio} name={IIO_NAME}")
    print(f"[iio] event-enable={event_enable.name}")

    dev_fd = event_fd = -1
    enabled = False
    try:
        dev_fd, event_fd = open_event_fd(iio)
        enable_presence(event_enable)
        enabled = True
        print(f"[activate] event state={event_enable.read_text().strip()}")
        monitor(iio, event_fd, args.duration)
    except KeyboardInterrupt:
        print("\n[monitor] stopped by user")
    finally:
        if enabled and not args.keep_enabled:
            try:
                print(f"[cleanup] {event_enable} <- 0")
                event_enable.write_text("0\n")
            except OSError as exc:
                print(f"[cleanup] failed to disable presence event: {exc}", file=sys.stderr)
        if event_fd >= 0:
            os.close(event_fd)
        if dev_fd >= 0:
            os.close(dev_fd)
        if args.unload and module_loaded():
            print(f"[cleanup] unloading {MODULE}")
            sh(["rmmod", MODULE], check=False)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
