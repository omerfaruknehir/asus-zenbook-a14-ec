#!/usr/bin/env python3
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "asus_zenbook_a14_ec.c"
HID_SOURCE = ROOT / "hid_asus_ec.c"
SCRIPTS = ROOT / "scripts"


def read_source() -> str:
    return SOURCE.read_text()


def has(token: str) -> bool:
    return token in read_source()


def hid_has(token: str) -> bool:
    return HID_SOURCE.is_file() and token in HID_SOURCE.read_text()


def run(script: str) -> None:
    path = SCRIPTS / script
    if not path.is_file():
        raise SystemExit(f"missing composition helper: {path}")
    print(f"compose_run={script}", flush=True)
    subprocess.run([sys.executable, str(path)], cwd=ROOT, check=True)


def native_profile_complete() -> bool:
    s = read_source()
    return (
        "#define EC_FW_WAIT_MIN_US                100000" in s
        and "#define EC_FW_WAIT_MAX_US                110000" in s
        and "EC_FW_FAN_PROFILE_NORMAL" in s
        and "EC_FW_FAN_PROFILE_QUIET" in s
        and "EC_FW_FAN_PROFILE_TURBO" in s
        and "EC_FW_FAN_PROFILE_FULL_SPEED" in s
        and "static int asus_ec_set_native_fan_profile" in s
        and "ASUS_EC_PROFILE_FULL_SPEED" in s
    )


def final_missing() -> list[str]:
    s = read_source()
    required = (
        "EC_FW_FAN_PROFILE_NORMAL",
        "EC_FW_FAN_PROFILE_QUIET",
        "EC_FW_FAN_PROFILE_TURBO",
        "EC_FW_FAN_PROFILE_FULL_SPEED",
        "EC_NATIVE_FAN1_RPM_LO",
        "PLATFORM_PROFILE_MAX_POWER",
        "A14_NATIVE_MODE_NAMES_HOTKEY",
        "A14_WHISPER_MODE",
        "ASUS_EC_PROFILE_WHISPER",
        'return sysfs_emit(buf, "whisper quiet normal turbo full-speed\\n");',
        "int asus_a14_cycle_native_profile(void);\n\nint asus_a14_cycle_native_profile(void)",
        "EXPORT_SYMBOL_GPL(asus_a14_cycle_native_profile)",
        "DEVICE_ATTR_RO(whisper_level)",
    )
    missing = [token for token in required if token not in s]

    # The four ASUS modes remain pure firmware modes. Old synthetic named
    # policies must not leak back in; Whisper is the sole synthetic policy.
    forbidden = (
        "A14_PROFILE_POLICY_V2",
        "A14_QUIET_FANLESS",
        "A14_THERMAL_SAFETY",
        "A14_QOS_COMPLETE",
        "ASUS_EC_PROFILE_POWER_SAVER",
        "power_saver_max_percent",
        "quiet_fan_pwm",
        "asus_ec_enter_manual_locked(ec, 255)",
    )
    missing.extend(f"forbidden:{token}" for token in forbidden if token in s)
    return missing


def ensure_export_prototype() -> None:
    expected = (
        "int asus_a14_cycle_native_profile(void);\n\n"
        "int asus_a14_cycle_native_profile(void)"
    )
    if has(expected):
        print("a14_fn_f_export_prototype=current")
    else:
        run("apply-a14-export-prototype.py")


def compose_ec() -> None:
    # Installed DKMS sources are packaged after composition. Do not require the
    # repository-only transformer scripts again when all final markers exist,
    # but still verify the final exported prototype because Whisper rewrites
    # the Fn+F cycle function after the native-mode layer creates it.
    if has("A14_WHISPER_MODE") and has("A14_NATIVE_MODE_NAMES_HOTKEY"):
        print("a14_ec_composed=current")
        ensure_export_prototype()
        return

    if has("static int asus_ec_force_auto_locked"):
        print("a14_ec_hardening=current")
    else:
        run("apply-a14-ec-hardening.py")

    if native_profile_complete():
        print("a14_native_fan_profile=current")
    else:
        run("apply-a14-native-fan-profile.py")

    run("apply-a14-native-hardening-compat.py")
    run("apply-a14-native-max-power.py")

    if has("EC_NATIVE_FAN1_RPM_LO"):
        print("a14_native_fan_telemetry=current")
    else:
        run("apply-a14-native-fan-telemetry.py")

    run("apply-a14-native-mode-names-hotkey.py")
    run("apply-a14-whisper.py")
    ensure_export_prototype()


def compose_hid() -> None:
    if hid_has("A14_HID_NATIVE_PROFILE_HOTKEY"):
        print("a14_hid_composed=current")
        return
    run("apply-a14-hid-fnlock.py")
    run("apply-a14-hid-profile-hotkey.py")


def main() -> None:
    if not SOURCE.is_file():
        raise SystemExit(f"missing source: {SOURCE}")
    if not HID_SOURCE.is_file():
        raise SystemExit(f"missing source: {HID_SOURCE}")

    compose_ec()
    compose_hid()

    missing = final_missing()
    if missing:
        raise SystemExit("a14_ec_stack=incomplete: " + ", ".join(missing))

    hid = HID_SOURCE.read_text()
    hid_required = (
        "A14_HID_NATIVE_PROFILE_HOTKEY",
        "asus_a14_cycle_native_profile();",
        "schedule_work(&data->profile_work);",
    )
    hid_missing = [token for token in hid_required if token not in hid]
    if hid_missing:
        raise SystemExit("a14_hid_stack=incomplete: " + ", ".join(hid_missing))

    print("a14_profiles=whisper,quiet,normal,turbo,full-speed")
    print("a14_native_profiles=quiet,normal,turbo,full-speed")
    print("a14_fn_f_cycle=whisper,quiet,normal,turbo,full-speed")
    print("a14_ec_stack=current")


if __name__ == "__main__":
    main()
