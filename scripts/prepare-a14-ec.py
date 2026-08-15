#!/usr/bin/env python3
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "asus_zenbook_a14_ec.c"
SCRIPTS = ROOT / "scripts"


def read_source() -> str:
    return SOURCE.read_text()


def has(token: str) -> bool:
    return token in read_source()


def run(script: str) -> None:
    path = SCRIPTS / script
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
        "#define EC_FW_WAIT_MIN_US                100000",
        "#define EC_FW_WAIT_MAX_US                110000",
        "EC_FW_FAN_PROFILE_NORMAL",
        "EC_FW_FAN_PROFILE_QUIET",
        "EC_FW_FAN_PROFILE_TURBO",
        "EC_FW_FAN_PROFILE_FULL_SPEED",
        "EC_NATIVE_FAN1_RPM_LO",
        "ASUS_EC_PROFILE_FULL_SPEED",
        "static int asus_ec_set_native_fan_profile",
        "static int asus_ec_native_profile_marker",
        'return sysfs_emit(buf, "quiet normal turbo full-speed\\n");',
        "PLATFORM_PROFILE_MAX_POWER",
        "A14_NATIVE_MODE_NAMES_HOTKEY",
        "EXPORT_SYMBOL_GPL(asus_a14_cycle_native_profile)",
    )
    missing = [token for token in required if token not in s]

    # Named power profiles must be pure ASUS firmware modes. Manual PWM remains
    # available only through the explicit CUSTOM hwmon/control path.
    forbidden = (
        "A14_PROFILE_POLICY_V2",
        "A14_QUIET_FANLESS",
        "A14_THERMAL_SAFETY",
        "A14_QOS_COMPLETE",
        "ASUS_EC_PROFILE_POWER_SAVER",
        "quiet_max_percent",
        "power_saver_max_percent",
        "quiet_fan_pwm",
        "asus_ec_enter_manual_locked(ec, 255)",
    )
    missing.extend(f"forbidden:{token}" for token in forbidden if token in s)
    return missing


def compose_ec() -> None:
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


def main() -> None:
    if not SOURCE.is_file():
        raise SystemExit(f"missing source: {SOURCE}")

    compose_ec()
    run("apply-a14-hid-fnlock.py")

    missing = final_missing()
    if missing:
        raise SystemExit("a14_ec_stack=incomplete: " + ", ".join(missing))

    print("a14_ec_native_profiles=quiet,normal,turbo,full-speed")
    print("a14_ec_stack=current")


if __name__ == "__main__":
    main()
