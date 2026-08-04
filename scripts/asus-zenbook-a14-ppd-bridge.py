#!/usr/bin/env python3
"""Optional power-profiles-daemon-compatible bridge for ASUS Zenbook A14.

This service is a fallback for DT kernels that cannot expose the driver's
platform_profile class device. It maps the desktop's three standard profile
names to the driver's always-available local profile sysfs attribute.
"""

from __future__ import annotations

import os
import signal
import sys
from pathlib import Path
from typing import Any

import dbus
import dbus.lowlevel
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

BUS_NAME = "org.freedesktop.UPower.PowerProfiles"
LEGACY_BUS_NAME = "net.hadess.PowerProfiles"
OBJECT_PATH = "/org/freedesktop/UPower/PowerProfiles"
LEGACY_OBJECT_PATH = "/net/hadess/PowerProfiles"
INTERFACE = "org.freedesktop.UPower.PowerProfiles"
LEGACY_INTERFACE = "net.hadess.PowerProfiles"
PROPERTIES_INTERFACE = "org.freedesktop.DBus.Properties"
KNOWN_INTERFACES = {INTERFACE, LEGACY_INTERFACE}

PROFILE_PATH = Path("/sys/devices/platform/asus_zenbook_a14_ec/profile")
STATE_PATH = Path("/var/lib/asus-zenbook-a14-ec/profile")
PROFILE_ORDER = ("power-saver", "balanced", "performance")
PROFILE_TO_DRIVER = {
    "power-saver": "quiet",
    "balanced": "balanced",
    "performance": "performance",
}
DRIVER_TO_PROFILE = {value: key for key, value in PROFILE_TO_DRIVER.items()}


class BridgeError(dbus.DBusException):
    _dbus_error_name = "org.freedesktop.DBus.Error.Failed"


class InvalidProfileError(dbus.DBusException):
    _dbus_error_name = "org.freedesktop.DBus.Error.InvalidArgs"


class PowerProfilesBridge(dbus.service.Object):
    """Small, current PPD-compatible D-Bus service backed by driver sysfs."""

    SUPPORTS_MULTIPLE_OBJECT_PATHS = True

    def __init__(self, bus: dbus.SystemBus) -> None:
        self._bus = bus
        self._bus_name = dbus.service.BusName(BUS_NAME, bus, do_not_queue=True)
        self._legacy_bus_name = dbus.service.BusName(
            LEGACY_BUS_NAME, bus, do_not_queue=True
        )
        super().__init__(bus, OBJECT_PATH)
        self.add_to_connection(bus, LEGACY_OBJECT_PATH)

        self._holds: dict[int, dict[str, Any]] = {}
        self._next_cookie = 1
        self._battery_aware = False
        self._active_profile = self._load_initial_profile()
        self._apply_effective_profile()

        bus.add_signal_receiver(
            self._name_owner_changed,
            signal_name="NameOwnerChanged",
            dbus_interface="org.freedesktop.DBus",
            bus_name="org.freedesktop.DBus",
            path="/org/freedesktop/DBus",
        )

    @staticmethod
    def _validate_profile(profile: str, *, allow_balanced: bool = True) -> str:
        valid = PROFILE_ORDER if allow_balanced else ("power-saver", "performance")
        if profile not in valid:
            raise InvalidProfileError(f"Invalid profile: {profile}")
        return profile

    @staticmethod
    def _read_driver_profile() -> str | None:
        try:
            return DRIVER_TO_PROFILE.get(PROFILE_PATH.read_text().strip())
        except OSError:
            return None

    def _load_initial_profile(self) -> str:
        try:
            saved = STATE_PATH.read_text().strip()
            if saved in PROFILE_ORDER:
                return saved
        except OSError:
            pass
        return self._read_driver_profile() or "balanced"

    def _save_profile(self) -> None:
        try:
            STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
            STATE_PATH.write_text(f"{self._active_profile}\n")
        except OSError as exc:
            print(f"ppd-bridge: cannot save profile state: {exc}", file=sys.stderr)

    def _effective_profile(self) -> str:
        held = {str(item["Profile"]) for item in self._holds.values()}
        if "power-saver" in held:
            return "power-saver"
        if "performance" in held:
            return "performance"
        return self._active_profile

    def _write_driver_profile(self, profile: str) -> None:
        driver_profile = PROFILE_TO_DRIVER[profile]
        try:
            PROFILE_PATH.write_text(f"{driver_profile}\n")
        except OSError as exc:
            raise BridgeError(
                f"Cannot apply {profile} through {PROFILE_PATH}: {exc}"
            ) from exc

    def _apply_effective_profile(self) -> None:
        effective = self._effective_profile()
        self._write_driver_profile(effective)
        print(
            f"ppd-bridge: active={self._active_profile} effective={effective}",
            flush=True,
        )

    def _emit_properties(self, names: tuple[str, ...]) -> None:
        changed = {name: self._get_property(name) for name in names}
        self.PropertiesChanged(INTERFACE, changed, [])
        self.PropertiesChanged(LEGACY_INTERFACE, changed, [])

    def _emit_profile_released(self, cookie: int, destination: str) -> None:
        message = dbus.lowlevel.SignalMessage(
            OBJECT_PATH, INTERFACE, "ProfileReleased"
        )
        message.append(dbus.UInt32(cookie), signature="u")
        message.set_destination(destination)
        self._bus.send_message(message)

    def _release_holds(self, *, owner: str | None = None, emit: bool = True) -> bool:
        cookies = [
            cookie
            for cookie, hold in self._holds.items()
            if owner is None or hold["Owner"] == owner
        ]
        if not cookies:
            return False
        for cookie in cookies:
            hold = self._holds.pop(cookie)
            if emit:
                self._emit_profile_released(cookie, str(hold["Owner"]))
        self._apply_effective_profile()
        self._emit_properties(("ActiveProfile", "ActiveProfileHolds"))
        return True

    def _name_owner_changed(self, name: str, old_owner: str, new_owner: str) -> None:
        if old_owner and not new_owner:
            self._release_holds(owner=str(old_owner), emit=False)

    def _profiles_property(self) -> dbus.Array:
        entries = []
        for profile in PROFILE_ORDER:
            entries.append(
                dbus.Dictionary(
                    {
                        "Profile": dbus.String(profile),
                        "Driver": dbus.String("asus-zenbook-a14-ec"),
                        "PlatformDriver": dbus.String("asus-zenbook-a14-ec"),
                    },
                    signature="sv",
                )
            )
        return dbus.Array(entries, signature="a{sv}")

    def _holds_property(self) -> dbus.Array:
        entries = []
        for hold in self._holds.values():
            entries.append(
                dbus.Dictionary(
                    {
                        "ApplicationId": dbus.String(str(hold["ApplicationId"])),
                        "Profile": dbus.String(str(hold["Profile"])),
                        "Reason": dbus.String(str(hold["Reason"])),
                    },
                    signature="sv",
                )
            )
        return dbus.Array(entries, signature="a{sv}")

    def _get_property(self, prop: str) -> Any:
        if prop == "ActiveProfile":
            return dbus.String(self._effective_profile())
        if prop == "PerformanceInhibited":
            return dbus.String("")
        if prop == "PerformanceDegraded":
            return dbus.String("")
        if prop == "Profiles":
            return self._profiles_property()
        if prop == "Actions":
            return dbus.Array([], signature="s")
        if prop == "ActionsInfo":
            return dbus.Array([], signature="a{sv}")
        if prop == "ActiveProfileHolds":
            return self._holds_property()
        if prop == "Version":
            return dbus.String("0.2.0-a14-bridge")
        if prop == "BatteryAware":
            return dbus.Boolean(self._battery_aware)
        raise dbus.exceptions.DBusException(
            f"Unknown property: {prop}",
            name="org.freedesktop.DBus.Error.UnknownProperty",
        )

    @dbus.service.method(PROPERTIES_INTERFACE, in_signature="ss", out_signature="v")
    def Get(self, interface: str, prop: str) -> Any:
        if interface not in KNOWN_INTERFACES:
            raise dbus.exceptions.DBusException(
                f"Unknown interface: {interface}",
                name="org.freedesktop.DBus.Error.UnknownInterface",
            )
        return self._get_property(prop)

    @dbus.service.method(PROPERTIES_INTERFACE, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface: str) -> dbus.Dictionary:
        if interface not in KNOWN_INTERFACES:
            raise dbus.exceptions.DBusException(
                f"Unknown interface: {interface}",
                name="org.freedesktop.DBus.Error.UnknownInterface",
            )
        names = (
            "ActiveProfile",
            "PerformanceInhibited",
            "PerformanceDegraded",
            "Profiles",
            "Actions",
            "ActionsInfo",
            "ActiveProfileHolds",
            "Version",
            "BatteryAware",
        )
        return dbus.Dictionary(
            {name: self._get_property(name) for name in names}, signature="sv"
        )

    @dbus.service.method(PROPERTIES_INTERFACE, in_signature="ssv", out_signature="")
    def Set(self, interface: str, prop: str, value: Any) -> None:
        if interface not in KNOWN_INTERFACES:
            raise dbus.exceptions.DBusException(
                f"Unknown interface: {interface}",
                name="org.freedesktop.DBus.Error.UnknownInterface",
            )
        if prop == "ActiveProfile":
            profile = self._validate_profile(str(value))
            self._release_holds(emit=True)
            self._active_profile = profile
            self._save_profile()
            self._apply_effective_profile()
            self._emit_properties(("ActiveProfile", "ActiveProfileHolds"))
            return
        if prop == "BatteryAware":
            self._battery_aware = bool(value)
            self._emit_properties(("BatteryAware",))
            return
        raise dbus.exceptions.DBusException(
            f"Property is read-only or unknown: {prop}",
            name="org.freedesktop.DBus.Error.PropertyReadOnly",
        )

    @dbus.service.signal(PROPERTIES_INTERFACE, signature="sa{sv}as")
    def PropertiesChanged(
        self, interface: str, changed: dict[str, Any], invalidated: list[str]
    ) -> None:
        pass

    @dbus.service.method(
        INTERFACE,
        in_signature="sss",
        out_signature="u",
        sender_keyword="sender",
    )
    def HoldProfile(
        self, profile: str, reason: str, application_id: str, sender: str
    ) -> dbus.UInt32:
        profile = self._validate_profile(str(profile), allow_balanced=False)
        cookie = self._next_cookie
        self._next_cookie += 1
        self._holds[cookie] = {
            "Profile": profile,
            "Reason": str(reason),
            "ApplicationId": str(application_id),
            "Owner": str(sender),
        }
        self._apply_effective_profile()
        self._emit_properties(("ActiveProfile", "ActiveProfileHolds"))
        return dbus.UInt32(cookie)

    @dbus.service.method(
        INTERFACE,
        in_signature="u",
        out_signature="",
        sender_keyword="sender",
    )
    def ReleaseProfile(self, cookie: int, sender: str) -> None:
        hold = self._holds.get(int(cookie))
        if hold is None or hold["Owner"] != str(sender):
            raise dbus.exceptions.DBusException(
                f"Unknown profile hold cookie: {cookie}",
                name="org.freedesktop.DBus.Error.InvalidArgs",
            )
        self._holds.pop(int(cookie))
        self._apply_effective_profile()
        self._emit_properties(("ActiveProfile", "ActiveProfileHolds"))

    @dbus.service.method(INTERFACE, in_signature="sb", out_signature="")
    def SetActionEnabled(self, action: str, enabled: bool) -> None:
        raise dbus.exceptions.DBusException(
            f"Unknown action: {action}",
            name="org.freedesktop.DBus.Error.InvalidArgs",
        )

    @dbus.service.signal(INTERFACE, signature="u")
    def ProfileReleased(self, cookie: int) -> None:
        pass

    def restore_balanced(self) -> None:
        self._holds.clear()
        self._active_profile = "balanced"
        try:
            self._write_driver_profile("balanced")
        except BridgeError as exc:
            print(f"ppd-bridge: shutdown restore failed: {exc}", file=sys.stderr)


def main() -> int:
    if not PROFILE_PATH.exists():
        print(f"ppd-bridge: missing driver profile path: {PROFILE_PATH}", file=sys.stderr)
        return os.EX_UNAVAILABLE

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    try:
        bridge = PowerProfilesBridge(bus)
    except dbus.DBusException as exc:
        print(f"ppd-bridge: cannot claim D-Bus service: {exc}", file=sys.stderr)
        return os.EX_UNAVAILABLE

    loop = GLib.MainLoop()

    def stop(_signum: int, _frame: object) -> None:
        bridge.restore_balanced()
        loop.quit()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print("ppd-bridge: ready", flush=True)
    loop.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
