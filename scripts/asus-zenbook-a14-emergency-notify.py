#!/usr/bin/env python3
"""Deliver ASUS A14 Quiet emergency notifications to active desktop sessions."""

from __future__ import annotations

import glob
import os
import pwd
import shutil
import subprocess
import sys
import syslog

APP = "ASUS Zenbook A14"
REPLACE_ID = 3407


def parse_temp(raw: str | None) -> str:
    try:
        value = int(raw or "")
    except ValueError:
        return "unknown temperature"
    if value < 0:
        return "unknown temperature"
    return f"{value / 1000:.1f} °C"


def run_as_user(uid: int, argv: list[str], timeout: int = 4) -> tuple[bool, str]:
    try:
        user = pwd.getpwuid(uid).pw_name
    except KeyError:
        return False, "unknown-user"

    bus = f"/run/user/{uid}/bus"
    if not os.path.exists(bus):
        return False, "no-session-bus"

    runuser = shutil.which("runuser") or "/usr/sbin/runuser"
    cmd = [
        runuser, "-u", user, "--", "env",
        f"DBUS_SESSION_BUS_ADDRESS=unix:path={bus}",
        f"XDG_RUNTIME_DIR=/run/user/{uid}",
        *argv,
    ]
    try:
        proc = subprocess.run(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout,
            check=False,
        )
        output = (proc.stdout or "").strip().replace("\n", " ")[:300]
        return proc.returncode == 0, output or f"rc={proc.returncode}"
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, type(exc).__name__


def notify_user(uid: int, summary: str, body: str, urgency: str, timeout_ms: int) -> tuple[bool, str]:
    # Prefer the notification service's D-Bus API directly. This avoids
    # notify-send option/version differences observed in the original udev
    # delivery path. The uint32 replace ID keeps engage/clear on one card.
    if shutil.which("gdbus"):
        hints = "{'urgency': <byte 2>}" if urgency == "critical" else "{'urgency': <byte 1>}"
        ok, detail = run_as_user(uid, [
            "gdbus", "call", "--session",
            "--dest", "org.freedesktop.Notifications",
            "--object-path", "/org/freedesktop/Notifications",
            "--method", "org.freedesktop.Notifications.Notify",
            APP,
            str(REPLACE_ID),
            "",
            summary,
            body,
            "[]",
            hints,
            str(timeout_ms),
        ])
        if ok:
            return True, "gdbus"
        gdbus_detail = detail
    else:
        gdbus_detail = "gdbus-unavailable"

    if shutil.which("notify-send"):
        ok, detail = run_as_user(uid, [
            "notify-send",
            "--app-name", APP,
            "--urgency", urgency,
            "--expire-time", str(timeout_ms),
            summary,
            body,
        ])
        if ok:
            return True, "notify-send"
        return False, f"gdbus={gdbus_detail};notify-send={detail}"

    return False, f"gdbus={gdbus_detail};notify-send=unavailable"


def main() -> int:
    state = sys.argv[1] if len(sys.argv) > 1 else ""
    temp_raw = sys.argv[2] if len(sys.argv) > 2 else None
    reason = sys.argv[3] if len(sys.argv) > 3 else "unknown"
    temp = parse_temp(temp_raw)

    if state == "engage":
        summary = "Quiet mode: emergency cooling active"
        if reason == "qos-unavailable":
            body = (
                "CPU frequency throttling control is unavailable, so fan-stop Quiet "
                "is not safe. Firmware Turbo cooling has been forced while Quiet "
                "remains selected."
            )
        elif reason == "thermal-sensor-unavailable":
            body = (
                "CPU thermal safety sensors are unavailable, so fan-stop Quiet is "
                "not safe. Firmware Turbo cooling has been forced while Quiet "
                "remains selected."
            )
        else:
            body = (
                f"System temperature reached {temp}. CPU throttling remains active, "
                "the fans were returned to firmware control, and Turbo cooling was "
                "temporarily selected."
            )
        urgency = "critical"
        timeout_ms = 0
    elif state == "clear":
        summary = "Quiet mode: emergency cooling cleared"
        if reason == "profile-change":
            body = "Emergency cooling ended because another A14 mode was selected."
        elif reason == "qos-restored":
            body = (
                "CPU frequency throttling became available. The throttle-first "
                "fan-stop Quiet policy has been restored."
            )
        else:
            body = (
                f"System temperature recovered to {temp}. Fan-stop Quiet has been "
                "restored."
            )
        urgency = "normal"
        timeout_ms = 6000
    else:
        return os.EX_USAGE

    delivered = 0
    details: list[str] = []
    seen: set[int] = set()
    for bus in glob.glob("/run/user/[0-9]*/bus"):
        try:
            uid = int(bus.split("/")[3])
        except (ValueError, IndexError):
            continue
        if uid == 0 or uid in seen:
            continue
        seen.add(uid)
        success, detail = notify_user(uid, summary, body, urgency, timeout_ms)
        details.append(f"uid={uid}:{detail}")
        if success:
            delivered += 1

    syslog.openlog("asus-a14-emergency-notify")
    syslog.syslog(
        syslog.LOG_NOTICE,
        f"quiet_emergency={state} reason={reason} temp_mc={temp_raw or 'unknown'} "
        f"desktop_notifications={delivered} delivery={'|'.join(details) or 'no-sessions'}",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
