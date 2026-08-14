#!/bin/sh

# Controlled hardware validation for the ASUS Zenbook A14 EC driver.
# This script validates the EC transport, native profile command acceptance,
# automatic/manual ownership transitions, and manual PWM. It does not claim
# that native profile thermal behavior differs at idle; use the load validator
# for that. It performs no raw MMIO and does not touch CPAS/AOS.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd)
MODULE="$ROOT/asus_zenbook_a14_ec.ko"
PROFILE=""
HWMON=""
START_TS=$(date '+%Y-%m-%d %H:%M:%S')
ok=1
aborted=0
loaded_local=0

say()
{
    printf '%s\n' "$*"
}

find_profile()
{
    for f in /sys/devices/platform/asus_zenbook_a14_ec/profile \
             /sys/devices/platform/asus_zenbook_a14_ec.*/profile; do
        if [ -r "$f" ] && [ -w "$f" ]; then
            PROFILE=$f
            break
        fi
    done
}

find_hwmon()
{
    for h in /sys/class/hwmon/hwmon*; do
        if [ -r "$h/name" ] && [ "$(cat "$h/name" 2>/dev/null)" = asus_zenbook_a14_ec ]; then
            HWMON=$h
            break
        fi
    done
}

read_file()
{
    label=$1
    path=$2
    if [ -r "$path" ]; then
        value=$(cat "$path" 2>/dev/null)
        say "$label=${value:-unreadable}"
    else
        say "$label=unavailable"
    fi
}

sample_state()
{
    label=$1
    say ""
    say "===== $label ====="
    if [ -n "$PROFILE" ]; then
        read_file profile "$PROFILE"
    fi
    if [ -n "$HWMON" ]; then
        read_file fan1_rpm "$HWMON/fan1_input"
        read_file fan2_rpm "$HWMON/fan2_input"
        read_file ec_temp_mc "$HWMON/temp1_input"
        read_file pwm1 "$HWMON/pwm1"
        read_file pwm2 "$HWMON/pwm2"
        read_file pwm1_enable "$HWMON/pwm1_enable"
    fi
    if [ -r /sys/bus/platform/devices/b94000.i2c/power/runtime_status ]; then
        read_file geni_i2c_runtime /sys/bus/platform/devices/b94000.i2c/power/runtime_status
    fi
}

restore_balanced()
{
    if [ -n "$PROFILE" ] && [ -w "$PROFILE" ]; then
        printf '%s\n' balanced > "$PROFILE" 2>/dev/null
        rc=$?
        if [ "$rc" -eq 0 ]; then
            say "restore_balanced=ok"
        else
            say "restore_balanced=failed rc=$rc"
        fi
    fi
}

on_signal()
{
    aborted=1
    say "signal_received=true"
    restore_balanced
}

trap on_signal INT TERM HUP

write_profile()
{
    requested=$1
    say ""
    say "----- native profile command: $requested -----"
    printf '%s\n' "$requested" > "$PROFILE" 2>/dev/null
    rc=$?
    if [ "$rc" -ne 0 ]; then
        say "profile_write=$requested rc=$rc"
        return 1
    fi

    sleep 2
    actual=$(cat "$PROFILE" 2>/dev/null)
    say "profile_write=$requested rc=0 reported=${actual:-unreadable}"
    if [ "$actual" != "$requested" ]; then
        return 1
    fi
    sample_state "PROFILE COMMAND $requested"
    return 0
}

if [ "$(id -u)" -ne 0 ]; then
    say "ERROR: run with sudo: sudo ./scripts/a14-ec-runtime-validation.sh"
    ok=0
fi

if [ "$ok" -eq 1 ] && [ ! -r "$MODULE" ]; then
    say "ERROR: $MODULE is missing; build the modules first."
    ok=0
fi

if [ "$ok" -eq 1 ]; then
    say "===== PREPARE ====="
    say "started=$START_TS"
    uname -r

    if grep -q '^asus_zenbook_a14_ec ' /proc/modules 2>/dev/null; then
        say "unloading_existing_ec=true"
        sh "$ROOT/scripts/asus-zenbook-a14-ec-unload"
    fi

    if grep -q '^asus_zenbook_a14_ec ' /proc/modules 2>/dev/null; then
        say "ERROR: existing EC module is still loaded; local module was not inserted."
        ok=0
    fi
fi

if [ "$ok" -eq 1 ]; then
    say "loading_local_ec=$MODULE"
    insmod "$MODULE" performance_pwm=160
    rc=$?
    say "insmod_rc=$rc"
    if [ "$rc" -ne 0 ]; then
        ok=0
    else
        loaded_local=1
        sleep 2
    fi
fi

if [ "$ok" -eq 1 ]; then
    find_profile
    find_hwmon

    say "profile_path=${PROFILE:-missing}"
    say "hwmon_path=${HWMON:-missing}"

    if [ -z "$PROFILE" ]; then
        say "ERROR: driver profile sysfs node was not found."
        ok=0
    fi
    if [ -z "$HWMON" ]; then
        say "ERROR: driver hwmon node was not found."
        ok=0
    fi
fi

if [ "$ok" -eq 1 ]; then
    read_file profile_choices "$(dirname "$PROFILE")/profile_choices"
    sample_state BASELINE

    for profile in balanced quiet performance full-speed balanced; do
        if [ "$ok" -eq 1 ] && [ "$aborted" -eq 0 ]; then
            write_profile "$profile"
            rc=$?
            if [ "$rc" -ne 0 ]; then
                say "ERROR: native profile command validation stopped at $profile"
                ok=0
            fi
        fi
    done
fi

# Revalidate the previously proven manual-PWM path without confusing it with
# the native firmware performance profile. performance_pwm=160 above keeps the
# initial manual transition moderate before both channels are explicitly set.
if [ "$ok" -eq 1 ] && [ "$aborted" -eq 0 ]; then
    if [ -w "$HWMON/pwm1_enable" ] && [ -w "$HWMON/pwm1" ] && [ -w "$HWMON/pwm2" ]; then
        say ""
        say "----- manual PWM round-trip -----"
        printf '%s\n' 1 > "$HWMON/pwm1_enable" 2>/dev/null
        rc=$?
        if [ "$rc" -eq 0 ]; then
            printf '%s\n' 160 > "$HWMON/pwm1" 2>/dev/null
            rc1=$?
            printf '%s\n' 160 > "$HWMON/pwm2" 2>/dev/null
            rc2=$?
            sleep 2
            say "manual_pwm_set_rc=$rc/$rc1/$rc2"
            sample_state MANUAL_PWM_160
            if [ "$rc1" -ne 0 ] || [ "$rc2" -ne 0 ]; then
                ok=0
            fi
        else
            say "manual_enable_rc=$rc"
            ok=0
        fi

        printf '%s\n' 2 > "$HWMON/pwm1_enable" 2>/dev/null
        auto_rc=$?
        sleep 2
        say "manual_to_auto_rc=$auto_rc"
        sample_state AFTER_MANUAL_AUTO
        if [ "$auto_rc" -ne 0 ]; then
            ok=0
        fi
    else
        say "manual_pwm_roundtrip=skipped_missing_hwmon_controls"
    fi
fi

if [ "$loaded_local" -eq 1 ]; then
    restore_balanced
    sleep 1
fi

say ""
say "===== KERNEL MESSAGES SINCE TEST START ====="
if command -v journalctl >/dev/null 2>&1; then
    journalctl -k --since "$START_TS" --no-pager 2>/dev/null | \
        grep -Ei 'asus_zenbook_a14_ec|b94000|i2c|fan|thermal|platform.profile' | tail -n 160
else
    dmesg 2>/dev/null | grep -Ei 'asus_zenbook_a14_ec|b94000|i2c|fan|thermal|platform.profile' | tail -n 160
fi

say ""
if [ "$ok" -eq 1 ] && [ "$aborted" -eq 0 ]; then
    say "A14_EC_RUNTIME_TRANSPORT_VALIDATION=PASS"
    say "native_profile_behavior=requires_load_validation"
else
    say "A14_EC_RUNTIME_TRANSPORT_VALIDATION=FAIL"
fi
say "local_module_left_loaded=$loaded_local"
say "final_profile=balanced_requested"

true
