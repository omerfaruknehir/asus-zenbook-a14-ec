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
        "PLATFORM_PROFILE_MAX_POWER",
        "A14_NATIVE_MODE_NAMES_HOTKEY",
        "A14_WHISPER_MODE",
        "ASUS_EC_PROFILE_WHISPER",
        '#include <linux/math64.h>',
        'return sysfs_emit(buf, "whisper quiet normal turbo full-speed\\n");',
        "int asus_a14_cycle_native_profile(void);\n\nint asus_a14_cycle_native_profile(void)",
        "EXPORT_SYMBOL_GPL(asus_a14_cycle_native_profile)",
        "DEVICE_ATTR_RO(whisper_level)",
        "A14_EC_KBD_BACKLIGHT_STATUS_DIAGNOSTIC",
        "DEVICE_ATTR_RO(kbd_backlight_ec_status)",
        "*value = (long)raw * EC_TACH_RPM_MULT;",
    )
    missing = [token for token in required if token not in s]

    forbidden = (
        "A14_PROFILE_POLICY_V2",
        "A14_QUIET_FANLESS",
        "A14_THERMAL_SAFETY",
        "A14_QOS_COMPLETE",
        "ASUS_EC_PROFILE_POWER_SAVER",
        "power_saver_max_percent",
        "quiet_fan_pwm",
        "asus_ec_enter_manual_locked(ec, 255)",
        "EC_NATIVE_FAN1_RPM_LO",
        "EC_NATIVE_FAN1_RPM_HI",
        "asus_ec_read_native_fan1_rpm",
        # The DSDT DEVS 0x00100023 EC write was tested independently and in
        # combination with the HID feature request and did not switch the row.
        "A14_FNLOCK_EC_STAGE_DSDT",
        "DEVICE_ATTR_WO(fnlock_firmware_stage)",
    )
    missing.extend(f"forbidden:{token}" for token in forbidden if token in s)
    return missing


def ensure_export_prototype() -> None:
    prototype = "int asus_a14_cycle_native_profile(void);"
    definition = "int asus_a14_cycle_native_profile(void)\n{"
    expected = prototype + "\n\n" + definition
    s = read_source()

    if expected in s:
        print("a14_fn_f_export_prototype=current")
        return
    if definition not in s:
        raise SystemExit("Fn+F cycle definition missing")

    s = s.replace(prototype + "\n\n", "")
    if s.count(definition) != 1:
        raise SystemExit(f"Fn+F cycle definition count={s.count(definition)}")
    s = s.replace(definition, expected, 1)
    if s.count(prototype) != 1 or s.count(definition) != 1:
        raise SystemExit("Fn+F exported prototype finalization failed")
    SOURCE.write_text(s)
    print("a14_fn_f_export_prototype=applied")


def ensure_math64_header() -> None:
    s = read_source()
    if "A14_WHISPER_MODE" not in s:
        return
    include = "#include <linux/math64.h>\n"
    if include in s:
        print("a14_whisper_math64=current")
        return

    anchor = "#include <linux/kernel.h>\n"
    if s.count(anchor) != 1:
        raise SystemExit("kernel include anchor missing for math64")
    s = s.replace(anchor, anchor + include, 1)
    SOURCE.write_text(s)
    print("a14_whisper_math64=applied")


def compose_ec() -> None:
    if has("A14_WHISPER_MODE") and has("A14_NATIVE_MODE_NAMES_HOTKEY"):
        print("a14_ec_composed=current")
        ensure_export_prototype()
        ensure_math64_header()
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
    run("apply-a14-native-fan-telemetry.py")
    run("apply-a14-native-mode-names-hotkey.py")
    run("apply-a14-whisper.py")
    ensure_export_prototype()
    ensure_math64_header()


def fnlock_complete() -> bool:
    required = (
        "A14_HID_FNLOCK_WINDOWS_FULL_FEATURE_REPORT",
        "A14_HID_FNLOCK_WINDOWS_COMMON_INIT",
        "A14_HID_WINDOWS_POWER_RESET_SEQUENCE",
        "A14_HID_NO_POST_RESET_POWER_ON",
        "struct work_struct fnlock_work;",
        "struct delayed_work fnlock_init_work;",
        "atomic_t desired_fn_lock;",
        "static int asus_hid_windows_transport_reinit_hw",
        "static int asus_hid_windows_common_init",
        "static int asus_hid_set_fnlock_hw",
        "INIT_DELAYED_WORK(&data->fnlock_init_work, asus_fnlock_init_work);",
        "mod_delayed_work(system_wq, &data->fnlock_init_work",
        "schedule_work(&data->fnlock_work);",
        "A14_HID_FNLOCK_SOFTWARE_INVERSION",
        "asus_invert_standard_fkey",
        "Fn-lock software row state=",
        "no post-reset POWER_ON",
    )
    if not all(hid_has(token) for token in required):
        return False

    hid = HID_SOURCE.read_text()
    forbidden = (
        "static int asus_hid_initialise",
        "0xd0, 0x8f, 0x01",
        "A14_HID_FNLOCK_WINDOWS_INIT_INPUT",
        "A14_HID_QTEC_POST_HID_REPOWER",
        "asus_hid_qtec_post_init_repower",
    )
    return not any(token in hid for token in forbidden)


def profile_hotkey_complete() -> bool:
    required = (
        "A14_HID_NATIVE_PROFILE_HOTKEY",
        "struct work_struct profile_work;",
        "asus_a14_cycle_native_profile();",
        "schedule_work(&data->profile_work);",
    )
    return all(hid_has(token) for token in required)


def restore_generated_hid_base() -> None:
    """Recover from an older locally-composed HID source after git pull.

    Composition helpers mutate hid_asus_ec.c in the working tree. A fast-forward
    pull does not replace that modified file, so older generated Fn-lock code
    can survive a pull. Rebuild only that known generated state from committed
    HEAD, then apply current transforms in order.
    """
    current = HID_SOURCE.read_text()
    if "A14_HID_NATIVE_PROFILE_HOTKEY" not in current:
        raise SystemExit(
            "a14_hid_stack=partial-unrecoverable: Fn-lock composition is missing but the source is not a known generated Fn+F composition"
        )

    try:
        base = subprocess.run(
            ["git", "show", "HEAD:hid_asus_ec.c"],
            cwd=ROOT,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(
            "a14_hid_stack=partial: stale generated HID composition detected, but the committed HEAD base could not be recovered with git show"
        ) from error

    if not base.strip() or "struct asus_hid_data" not in base:
        raise SystemExit("a14_hid_stack=partial: recovered HEAD HID base is invalid")
    if "A14_HID_NATIVE_PROFILE_HOTKEY" in base:
        raise SystemExit(
            "a14_hid_stack=partial: committed HEAD already contains the generated profile marker; refusing recursive recovery"
        )

    HID_SOURCE.write_text(base)
    print("a14_hid_stale_composition=recovered-from-head")


def compose_hid() -> None:
    fnlock = fnlock_complete()
    profile = profile_hotkey_complete()

    if fnlock and profile:
        print("a14_hid_composed=current")
        return

    if profile and not fnlock:
        restore_generated_hid_base()
        fnlock = fnlock_complete()
        profile = profile_hotkey_complete()

    if not fnlock:
        run("apply-a14-hid-fnlock.py")
    if not profile:
        run("apply-a14-hid-profile-hotkey.py")

    if not fnlock_complete() or not profile_hotkey_complete():
        raise SystemExit("a14_hid_stack=incomplete-after-recomposition")


def enforce_fnlock_experiment_policy() -> None:
    """Keep disproven transport reset experiments opt-in in normal builds."""
    s = HID_SOURCE.read_text()
    old = "static bool fnlock_windows_transport_reinit = true;"
    new = "static bool fnlock_windows_transport_reinit = false;"

    if new in s:
        print("a14_fn_lock_windows_transport_reinit=diagnostic-disabled")
        return
    if s.count(old) != 1:
        raise SystemExit(
            "a14_fn_lock_windows_transport_reinit=policy-anchor-missing"
        )

    HID_SOURCE.write_text(s.replace(old, new, 1))
    print("a14_fn_lock_windows_transport_reinit=diagnostic-disabled-applied")


def main() -> None:
    if not SOURCE.is_file():
        raise SystemExit(f"missing source: {SOURCE}")
    if not HID_SOURCE.is_file():
        raise SystemExit(f"missing source: {HID_SOURCE}")

    compose_ec()
    run("apply-a14-kbd-backlight-status.py")
    compose_hid()
    enforce_fnlock_experiment_policy()

    missing = final_missing()
    if missing:
        raise SystemExit("a14_ec_stack=incomplete: " + ", ".join(missing))

    hid = HID_SOURCE.read_text()
    hid_required = (
        "A14_HID_NATIVE_PROFILE_HOTKEY",
        "asus_a14_cycle_native_profile();",
        "schedule_work(&data->profile_work);",
        "A14_HID_FNLOCK_WINDOWS_FULL_FEATURE_REPORT",
        "A14_HID_FNLOCK_WINDOWS_COMMON_INIT",
        "A14_HID_WINDOWS_POWER_RESET_SEQUENCE",
        "A14_HID_NO_POST_RESET_POWER_ON",
        "static int asus_hid_windows_transport_reinit_hw",
        "static int asus_hid_windows_common_init",
        "static int asus_hid_set_fnlock_hw",
        "struct delayed_work fnlock_init_work;",
        "INIT_DELAYED_WORK(&data->fnlock_init_work, asus_fnlock_init_work);",
        "mod_delayed_work(system_wq, &data->fnlock_init_work",
        "schedule_work(&data->fnlock_work);",
        "A14_HID_FNLOCK_SOFTWARE_INVERSION",
        "asus_invert_standard_fkey",
        "Fn-lock software row state=",
        "static bool fnlock_windows_transport_reinit = false;",
    )
    hid_missing = [token for token in hid_required if token not in hid]
    if hid_missing:
        raise SystemExit("a14_hid_stack=incomplete: " + ", ".join(hid_missing))

    hid_forbidden = (
        "static int asus_hid_initialise",
        "0xd0, 0x8f, 0x01",
        "A14_HID_FNLOCK_WINDOWS_INIT_INPUT",
        "static int asus_hid_windows_init_input",
        "A14_HID_QTEC_POST_HID_REPOWER",
        "asus_hid_qtec_post_init_repower",
        "applied A14/QTEC post-HID SET_POWER(ON)",
    )
    stale = [token for token in hid_forbidden if token in hid]
    if stale:
        raise SystemExit("a14_hid_stack=stale-obsolete-fnlock-path: " + ", ".join(stale))

    print("a14_profiles=whisper,quiet,normal,turbo,full-speed")
    print("a14_native_profiles=quiet,normal,turbo,full-speed")
    print("a14_fn_f_cycle=whisper,quiet,normal,turbo,full-speed")
    print("a14_fn_lock=software-row-inversion;windows-feature-init=diagnostic-only")
    print("a14_fn_lock_ec_stage=not-production-disproven-probe-only")
    print("a14_fan_telemetry=selector-calibrated")
    print("a14_ec_stack=current")


if __name__ == "__main__":
    main()
