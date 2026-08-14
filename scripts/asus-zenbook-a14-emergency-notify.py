#!/usr/bin/env python3
"""Deliver ASUS A14 Quiet emergency notifications to active desktop sessions."""

from __future__ import annotations

import glob
import os
import pwd
import subprocess
import sys
import syslog

APP = "ASUS Zenbook A14"
REPLACE_ID = "3407"


def parse_temp(raw: str | None) -> str:
    try:
        value = int(raw or "")
    except ValueError:
        return "unknown temperature"
    if value < 0:
        return "unknown temperature"
    return f"{value / 1000:.1f} °C"


def notify_user(uid: int, summary: str, body: str, urgency: str, timeout_ms: int) -> bool:
    try:
        user = pwd.getpwuid(uid).pw_name
    except KeyError:
        return False

    bus = f"/run/user/{uid}/bus"
    if not os.path.exists(bus):
        return False

    env = [
        f"DBUS_SESSION_BUS_ADDRESS=unix:path={bus}",
        f"XDG_RUNTIME_DIR=/run/user/{uid}",
    ]
    cmd = [
        "runuser", "-u", user, "--", "env", *env,
        "notify-send",
        "--app-name", APP,
        "--replace-id", REPLACE_ID,
        "--urgency", urgency,
        "--expire-time", str(timeout_ms),
        summary,
        body,
    ]
    try:
        proc = subprocess.run(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=3,
            check=False,
        )
        return proc.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def main() -> int:
    state = sys.argv[1] if len(sys.argv) > 1 else ""
    temp_raw = sys.argv[2] if len(sys.argv) > 2 else None
    reason = sys.argv[3] if len(sys.argv) > 3 else "unknown"
    temp = parse_temp(temp_raw)

    if state == "engage":
        summary = "Quiet mode: emergency cooling active"
        if reason == "qos-unavailable":
            body = (
                "CPU frequency throttling control is unavailable, so Quiet cannot "
                "safely remain on the minimal-fan curve. Firmware Turbo cooling "
                "has been forced while Quiet remains selected."
            )
        else:
            body = (
                f"System temperature reached {temp}. CPU throttling remains active, "
                "but the firmware cooling curve was temporarily raised to Turbo."
            )
        urgency = "critical"
        timeout_ms = 0
    elif state == "clear":
        summary = "Quiet mode: emergency cooling cleared"
        if reason == "profile-change":
            body = "Emergency cooling ended because another A14 mode was selected."
        else:
            body = (
                f"System temperature recovered to {temp}. The native Quiet cooling "
                "curve has been restored."
            )
        urgency = "normal"
        timeout_ms = 6000
    else:
        return os.EX_USAGE

    delivered = 0
    seen: set[int] = set()
    for bus in glob.glob("/run/user/[0-9]*/bus"):
        try:
            uid = int(bus.split("/")[3])
        except (ValueError, IndexError):
            continue
        if uid == 0 or uid in seen:
            continue
        seen.add(uid)
        if notify_user(uid, summary, body, urgency, timeout_ms):
            delivered += 1

    syslog.openlog("asus-a14-emergency-notify")
    syslog.syslog(
        syslog.LOG_NOTICE,
        f"quiet_emergency={state} reason={reason} temp_mc={temp_raw or 'unknown'} desktop_notifications={delivered}",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
