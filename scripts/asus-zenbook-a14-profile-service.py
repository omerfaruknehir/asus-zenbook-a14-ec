#!/usr/bin/env python3
"""System D-Bus API for the ASUS Zenbook A14 EC profile driver.

This intentionally exposes only the five validated named policies. It never
provides raw EC, PWM, register, firmware-mailbox, or MMIO access.
"""

from __future__ import annotations

import os
import pwd
import sys
import syslog
from pathlib import Path

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

BUS_NAME = "io.github.omerfaruknehir.AsusA14"
OBJECT_PATH = "/io/github/omerfaruknehir/AsusA14"
INTERFACE = "io.github.omerfaruknehir.AsusA14.Profile1"

PROFILE_PATH = Path("/sys/devices/platform/asus_zenbook_a14_ec/profile")
CHOICES_PATH = Path("/sys/devices/platform/asus_zenbook_a14_ec/profile_choices")
EMERGENCY_PATH = Path("/sys/devices/platform/asus_zenbook_a14_ec/quiet_emergency")

PROFILES = ("quiet", "power-saver", "balanced", "performance", "full-speed")


class A14Error(dbus.DBusException):
    _dbus_error_name = f"{INTERFACE}.Error"


class InvalidProfileError(dbus.DBusException):
    _dbus_error_name = f"{INTERFACE}.InvalidProfile"


class AccessDeniedError(dbus.DBusException):
    _dbus_error_name = "org.freedesktop.DBus.Error.AccessDenied"


class ProfileService(dbus.service.Object):
    def __init__(self, bus: dbus.SystemBus) -> None:
        self._bus = bus
        self._bus_name = dbus.service.BusName(BUS_NAME, bus, do_not_queue=True)
        super().__init__(bus, OBJECT_PATH)
        self._dbus = bus.get_object("org.freedesktop.DBus", "/org/freedesktop/DBus")
        self._last_profile = self._read_profile()
        self._last_emergency = self._read_emergency()
        GLib.timeout_add_seconds(1, self._poll_state)

    def _sender_uid(self, sender: str) -> int:
        try:
            return int(
                self._dbus.GetConnectionUnixUser(
                    sender, dbus_interface="org.freedesktop.DBus"
                )
            )
        except dbus.DBusException as exc:
            raise AccessDeniedError("Cannot resolve caller credentials") from exc

    def _authorize_local_user(self, sender: str) -> int:
        uid = self._sender_uid(sender)
        if uid == 0:
            return uid
        try:
            pw = pwd.getpwuid(uid)
        except KeyError as exc:
            raise AccessDeniedError("Unknown caller uid") from exc
        # Restrict mutation to ordinary local users that currently have a
        # per-user runtime/session bus. This avoids making the system D-Bus
        # method an unauthenticated remote power-control API.
        if uid < 1000 or not Path(f"/run/user/{uid}/bus").exists():
            raise AccessDeniedError("A local logged-in user session is required")
        if pw.pw_uid != uid:
            raise AccessDeniedError("Caller identity mismatch")
        return uid

    @staticmethod
    def _read_profile() -> str:
        try:
            value = PROFILE_PATH.read_text().strip()
        except OSError as exc:
            raise A14Error(f"Cannot read {PROFILE_PATH}: {exc}") from exc
        if value not in PROFILES:
            # CUSTOM/manual PWM is intentionally represented as custom rather
            # than made writable through this API.
            return "custom"
        return value

    @staticmethod
    def _read_emergency() -> bool:
        try:
            return EMERGENCY_PATH.read_text().strip() == "1"
        except OSError:
            return False

    def _poll_state(self) -> bool:
        try:
            profile = self._read_profile()
        except A14Error:
            profile = "unavailable"
        emergency = self._read_emergency()

        if profile != self._last_profile:
            self._last_profile = profile
            self.ProfileChanged(profile)
        if emergency != self._last_emergency:
            self._last_emergency = emergency
            self.QuietEmergencyChanged(emergency)
        return GLib.SOURCE_CONTINUE

    @dbus.service.method(INTERFACE, in_signature="", out_signature="s")
    def GetProfile(self) -> dbus.String:
        return dbus.String(self._read_profile())

    @dbus.service.method(INTERFACE, in_signature="", out_signature="as")
    def GetProfiles(self) -> dbus.Array:
        try:
            available = tuple(CHOICES_PATH.read_text().split())
        except OSError:
            available = PROFILES
        values = [profile for profile in PROFILES if profile in available]
        return dbus.Array([dbus.String(v) for v in values], signature="s")

    @dbus.service.method(INTERFACE, in_signature="", out_signature="b")
    def GetQuietEmergency(self) -> dbus.Boolean:
        return dbus.Boolean(self._read_emergency())

    @dbus.service.method(
        INTERFACE, in_signature="s", out_signature="", sender_keyword="sender"
    )
    def SetProfile(self, profile: str, sender: str) -> None:
        profile = str(profile)
        if profile not in PROFILES:
            raise InvalidProfileError(f"Unsupported A14 profile: {profile}")
        uid = self._authorize_local_user(sender)
        try:
            PROFILE_PATH.write_text(f"{profile}\n")
        except OSError as exc:
            raise A14Error(f"Cannot apply {profile}: {exc}") from exc

        applied = self._read_profile()
        if applied != profile:
            raise A14Error(f"Driver reported {applied} after requesting {profile}")

        self._last_profile = applied
        self.ProfileChanged(applied)
        syslog.openlog("asus-a14-profile-service")
        syslog.syslog(syslog.LOG_NOTICE, f"uid={uid} profile={applied}")

    @dbus.service.signal(INTERFACE, signature="s")
    def ProfileChanged(self, profile: str) -> None:
        pass

    @dbus.service.signal(INTERFACE, signature="b")
    def QuietEmergencyChanged(self, active: bool) -> None:
        pass


def main() -> int:
    if not PROFILE_PATH.exists():
        print(f"a14-profile-service: missing {PROFILE_PATH}", file=sys.stderr)
        return os.EX_UNAVAILABLE

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    try:
        service = ProfileService(bus)
    except dbus.DBusException as exc:
        print(f"a14-profile-service: D-Bus setup failed: {exc}", file=sys.stderr)
        return os.EX_UNAVAILABLE
    except A14Error as exc:
        print(f"a14-profile-service: driver unavailable: {exc}", file=sys.stderr)
        return os.EX_UNAVAILABLE

    # Keep the service object alive for the duration of the main loop.
    _service = service
    loop = GLib.MainLoop()
    loop.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
