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
        and "EC_FW_FAN_PROFILE_FULL_SPEED" in s
        and "static int asus_ec_set_native_fan_profile" in s
    )


def final_missing() -> list[str]:
    s = read_source()
    required = (
        "#define EC_FW_WAIT_MIN_US                100000",
        "#define EC_FW_WAIT_MAX_US                110000",
        "EC_NATIVE_FAN1_RPM_LO",
        "A14_PROFILE_POLICY_V2",
        "A14_PROFILE_EMERGENCY_NOTIFY",
        "A14_PROFILE_TRANSACTIONAL",
        "A14_QUIET_FANLESS",
        "A14_THERMAL_SAFETY",
        "A14_QOS_COMPLETE",
        "ASUS_EC_PROFILE_POWER_SAVER",
        "PLATFORM_PROFILE_MAX_POWER",
        "asus_ec_enter_manual_locked(ec, 255)",
        "asus_ec_enter_manual_locked(ec, quiet_fan_pwm)",
        "asus_ec_freq_qos_retry_attach",
        "asus_ec_freq_qos_available_policies",
        '"cpuss2-btm-thermal"',
    )
    return [token for token in required if token not in s]


def compose_ec() -> None:
    # Resume from the highest completed semantic layer. Newer layers imply that
    # their historical prerequisites were already materialized in this source.
    if has("A14_QOS_COMPLETE"):
        print("a14_qos_complete=current")
        return

    if has("A14_THERMAL_SAFETY"):
        print("a14_thermal_safety=current")
        run("apply-a14-qos-completeness.py")
        return

    if has("A14_QUIET_FANLESS"):
        print("a14_quiet_fanless=current")
        run("apply-a14-thermal-safety.py")
        run("apply-a14-qos-completeness.py")
        return

    if has("A14_PROFILE_TRANSACTIONAL"):
        print("a14_profile_transactional=current")
        run("apply-a14-quiet-fanless.py")
        run("apply-a14-thermal-safety.py")
        run("apply-a14-qos-completeness.py")
        return

    if has("A14_PROFILE_EMERGENCY_NOTIFY"):
        print("a14_profile_emergency_notify=current")
        run("apply-a14-profile-transactional.py")
        run("apply-a14-quiet-fanless.py")
        run("apply-a14-thermal-safety.py")
        run("apply-a14-qos-completeness.py")
        return

    if has("A14_PROFILE_POLICY_V2"):
        print("a14_profile_policy_v2=current")
        run("apply-a14-profile-emergency-notify.py")
        run("apply-a14-profile-transactional.py")
        run("apply-a14-quiet-fanless.py")
        run("apply-a14-thermal-safety.py")
        run("apply-a14-qos-completeness.py")
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

    run("apply-a14-profile-policy-v2.py")
    run("apply-a14-profile-emergency-notify.py")
    run("apply-a14-profile-transactional.py")
    run("apply-a14-quiet-fanless.py")
    run("apply-a14-thermal-safety.py")
    run("apply-a14-qos-completeness.py")


def main() -> None:
    if not SOURCE.is_file():
        raise SystemExit(f"missing source: {SOURCE}")

    compose_ec()
    run("apply-a14-hid-fnlock.py")

    missing = final_missing()
    if missing:
        raise SystemExit("a14_ec_stack=incomplete: " + ", ".join(missing))

    print("a14_ec_stack=current")


if __name__ == "__main__":
    main()
