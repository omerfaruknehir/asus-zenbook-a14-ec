#!/usr/bin/env python3
"""System D-Bus API for the ASUS Zenbook A14 profile driver.

Profiles are ordered Whisper < Quiet < Normal < Turbo < Full Speed. The four
ASUS modes are direct firmware modes. Whisper is acoustic-first: the kernel
controls CPU/fans, while this root service applies a matching GPU devfreq cap.

Kernel profile changes use sysfs_notify(); this service watches the profile and
Whisper-level sysfs attributes for POLLPRI so Fn+F changes reach GNOME without
a one-second polling delay. A slow timer remains only as a recovery fallback.
"""

from __future__ import annotations

import json
import os
import pwd
import signal
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
WHISPER_LEVEL_PATH = Path("/sys/devices/platform/asus_zenbook_a14_ec/whisper_level")
GPU_STATE_PATH = Path("/run/asus-zenbook-a14-ec/whisper-gpu.json")
PROFILES = ("whisper", "quiet", "normal", "turbo", "full-speed")
GPU_PERCENT = {0: 60, 1: 45, 2: 30, 3: 30}
SYSFS_WATCH_CONDITION = GLib.IO_PRI | GLib.IO_ERR | GLib.IO_HUP


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
        self._gpu_originals = self._load_gpu_state()
        self._last_profile = self._read_profile()
        self._last_whisper_level = self._read_whisper_level()
        self._sysfs_watches: list[tuple[int, GLib.IOChannel, int]] = []
        if self._last_profile == "whisper":
            self._apply_gpu_whisper(self._last_whisper_level)
        else:
            self._restore_gpu()
        self._add_sysfs_watch(PROFILE_PATH)
        self._add_sysfs_watch(WHISPER_LEVEL_PATH)
        # Recovery only. Normal profile propagation is event-driven above.
        GLib.timeout_add_seconds(5, self._poll_state)

    def _sender_uid(self, sender: str) -> int:
        try:
            return int(self._dbus.GetConnectionUnixUser(
                sender, dbus_interface="org.freedesktop.DBus"))
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
        if uid < 1000 or not Path(f"/run/user/{uid}/bus").exists() or pw.pw_uid != uid:
            raise AccessDeniedError("A local logged-in user session is required")
        return uid

    @staticmethod
    def _read_profile() -> str:
        try:
            value = PROFILE_PATH.read_text().strip()
        except OSError as exc:
            raise A14Error(f"Cannot read {PROFILE_PATH}: {exc}") from exc
        return value if value in PROFILES else "custom"

    @staticmethod
    def _read_whisper_level() -> int:
        try:
            return max(0, min(3, int(WHISPER_LEVEL_PATH.read_text().strip())))
        except (OSError, ValueError):
            return 3

    @staticmethod
    def _prime_sysfs_fd(fd: int) -> None:
        os.lseek(fd, 0, os.SEEK_SET)
        try:
            os.read(fd, 4096)
        except BlockingIOError:
            pass

    def _add_sysfs_watch(self, path: Path) -> None:
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
            self._prime_sysfs_fd(fd)
            channel = GLib.IOChannel.unix_new(fd)
            channel.set_encoding(None)
            source_id = GLib.io_add_watch(
                channel,
                GLib.PRIORITY_DEFAULT,
                SYSFS_WATCH_CONDITION,
                self._on_sysfs_event,
                fd,
                str(path),
            )
            self._sysfs_watches.append((fd, channel, source_id))
            print(f"profile-service: event watch ready: {path}", flush=True)
        except (OSError, GLib.Error) as exc:
            print(
                f"profile-service: cannot watch {path}; 5s fallback polling remains: {exc}",
                file=sys.stderr,
            )

    def _on_sysfs_event(
        self,
        _channel: GLib.IOChannel,
        condition: GLib.IOCondition,
        fd: int,
        path: str,
    ) -> bool:
        if condition & GLib.IO_PRI:
            try:
                self._prime_sysfs_fd(fd)
            except OSError as exc:
                print(f"profile-service: cannot acknowledge {path}: {exc}", file=sys.stderr)
                return False
            self._sync_state()
        if condition & (GLib.IO_ERR | GLib.IO_HUP):
            print(f"profile-service: sysfs watch ended: {path}", file=sys.stderr)
            return False
        return True

    @staticmethod
    def _gpu_nodes() -> list[Path]:
        nodes: list[Path] = []
        root = Path("/sys/class/devfreq")
        if not root.is_dir():
            return nodes
        for node in root.iterdir():
            try:
                name = (node / "name").read_text().strip().lower()
            except OSError:
                name = ""
            identity = f"{name} {node.name} {node.resolve()}".lower()
            if ("gpu" in identity or "adreno" in identity) and (node / "max_freq").exists():
                nodes.append(node)
        return nodes

    @staticmethod
    def _frequencies(node: Path) -> list[int]:
        try:
            values = [int(v) for v in (node / "available_frequencies").read_text().split()]
            return sorted(set(v for v in values if v > 0))
        except (OSError, ValueError):
            return []

    def _load_gpu_state(self) -> dict[str, int]:
        try:
            raw = json.loads(GPU_STATE_PATH.read_text())
            return {str(k): int(v) for k, v in raw.items()}
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            return {}

    def _save_gpu_state(self) -> None:
        GPU_STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        GPU_STATE_PATH.write_text(json.dumps(self._gpu_originals, sort_keys=True))

    def _apply_gpu_whisper(self, level: int) -> None:
        percent = GPU_PERCENT.get(level, 30)
        changed = False
        for node in self._gpu_nodes():
            path = str(node.resolve())
            max_path = node / "max_freq"
            if path not in self._gpu_originals:
                try:
                    # Use the hardware table maximum rather than inheriting a
                    # stale cap left behind by an earlier service instance.
                    freqs = self._frequencies(node)
                    current_max = int(max_path.read_text().strip())
                    self._gpu_originals[path] = max(freqs) if freqs else current_max
                    changed = True
                except (OSError, ValueError):
                    continue
            freqs = self._frequencies(node)
            if not freqs:
                continue
            target_raw = freqs[-1] * percent // 100
            target = max((f for f in freqs if f <= target_raw), default=freqs[0])
            try:
                max_path.write_text(f"{target}\n")
            except OSError as exc:
                print(f"profile-service: cannot cap GPU {node.name}: {exc}", file=sys.stderr)
        if changed:
            try:
                self._save_gpu_state()
            except OSError as exc:
                print(f"profile-service: cannot save GPU state: {exc}", file=sys.stderr)

    def _restore_gpu(self) -> None:
        if not self._gpu_originals:
            return
        for node in self._gpu_nodes():
            path = str(node.resolve())
            if path not in self._gpu_originals:
                continue
            try:
                (node / "max_freq").write_text(f"{self._gpu_originals[path]}\n")
            except OSError as exc:
                print(f"profile-service: cannot restore GPU {node.name}: {exc}", file=sys.stderr)
        self._gpu_originals.clear()
        try:
            GPU_STATE_PATH.unlink(missing_ok=True)
        except OSError:
            pass

    def _sync_state(self) -> None:
        try:
            profile = self._read_profile()
        except A14Error:
            profile = "unavailable"
        level = self._read_whisper_level()

        if profile != self._last_profile:
            self._last_profile = profile
            self.ProfileChanged(profile)
        if profile == "whisper":
            if level != self._last_whisper_level or not self._gpu_originals:
                self._apply_gpu_whisper(level)
        elif self._gpu_originals:
            self._restore_gpu()
        self._last_whisper_level = level

    def _poll_state(self) -> bool:
        self._sync_state()
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
        return dbus.Boolean(False)

    @dbus.service.method(INTERFACE, in_signature="s", out_signature="", sender_keyword="sender")
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
        if applied == "whisper":
            self._apply_gpu_whisper(self._read_whisper_level())
        else:
            self._restore_gpu()
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

    def shutdown(self) -> None:
        self._restore_gpu()
        for fd, _channel, source_id in self._sysfs_watches:
            if source_id:
                try:
                    GLib.source_remove(source_id)
                except GLib.Error:
                    pass
            try:
                os.close(fd)
            except OSError:
                pass
        self._sysfs_watches.clear()


def main() -> int:
    if not PROFILE_PATH.exists():
        print(f"a14-profile-service: missing {PROFILE_PATH}", file=sys.stderr)
        return os.EX_UNAVAILABLE
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    try:
        service = ProfileService(bus)
    except (dbus.DBusException, A14Error) as exc:
        print(f"a14-profile-service: setup failed: {exc}", file=sys.stderr)
        return os.EX_UNAVAILABLE
    loop = GLib.MainLoop()

    def stop(_signum: int, _frame: object) -> None:
        service.shutdown()
        loop.quit()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    loop.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
