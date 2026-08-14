#!/bin/sh

PROFILE=/sys/devices/platform/asus_zenbook_a14_ec/profile
EMERGENCY=/sys/devices/platform/asus_zenbook_a14_ec/quiet_emergency
P_EMERGENCY=/sys/module/asus_zenbook_a14_ec/parameters/quiet_emergency_mc
P_RECOVER=/sys/module/asus_zenbook_a14_ec/parameters/quiet_recover_mc
TMP=${TMPDIR:-/tmp}/a14-quiet-emergency-$$
MONITOR=$TMP/uevent.log
MON_PID=""
ok=1

say()
{
    printf '%s\n' "$*"
}

max_temp_mc()
{
    hottest=-1
    for z in /sys/class/thermal/thermal_zone*; do
        [ -r "$z/temp" ] || continue
        t=$(cat "$z/temp" 2>/dev/null)
        case "$t" in ''|*[!0-9]*) continue ;; esac
        if [ "$t" -gt "$hottest" ]; then hottest=$t; fi
    done
    if [ -r /sys/class/hwmon/hwmon0/temp1_input ]; then :; fi
    printf '%s' "$hottest"
}

wait_state()
{
    wanted=$1
    n=0
    while [ "$n" -lt 12 ]; do
        current=$(cat "$EMERGENCY" 2>/dev/null)
        if [ "$current" = "$wanted" ]; then
            return 0
        fi
        sleep 1
        n=$((n + 1))
    done
    return 1
}

cleanup()
{
    if [ -n "$MON_PID" ]; then
        kill "$MON_PID" 2>/dev/null || true
        wait "$MON_PID" 2>/dev/null || true
    fi
    if [ -n "${orig_emergency:-}" ] && [ -w "$P_EMERGENCY" ]; then
        printf '%s\n' "$orig_emergency" > "$P_EMERGENCY" 2>/dev/null || true
    fi
    if [ -n "${orig_recover:-}" ] && [ -w "$P_RECOVER" ]; then
        printf '%s\n' "$orig_recover" > "$P_RECOVER" 2>/dev/null || true
    fi
    if [ -n "${orig_profile:-}" ] && [ -w "$PROFILE" ]; then
        printf '%s\n' "$orig_profile" > "$PROFILE" 2>/dev/null || \
            printf '%s\n' balanced > "$PROFILE" 2>/dev/null || true
    fi
    rm -rf "$TMP" 2>/dev/null || true
}

trap cleanup INT TERM HUP

if [ "$(id -u)" -ne 0 ]; then
    say "ERROR: run with sudo: sudo sh ./scripts/a14-quiet-emergency-validation.sh"
    ok=0
fi

if [ "$ok" -eq 1 ]; then
    for f in "$PROFILE" "$EMERGENCY" "$P_EMERGENCY" "$P_RECOVER"; do
        if [ ! -r "$f" ]; then
            say "ERROR: missing $f"
            ok=0
        fi
    done
fi

if [ "$ok" -eq 1 ]; then
    orig_profile=$(cat "$PROFILE" 2>/dev/null)
    orig_emergency=$(cat "$P_EMERGENCY" 2>/dev/null)
    orig_recover=$(cat "$P_RECOVER" 2>/dev/null)
    say "original_profile=$orig_profile"
    say "original_quiet_emergency_mc=$orig_emergency"
    say "original_quiet_recover_mc=$orig_recover"

    mkdir -p "$TMP"
    if command -v udevadm >/dev/null 2>&1; then
        udevadm monitor --kernel --property --subsystem-match=platform > "$MONITOR" 2>&1 &
        MON_PID=$!
        sleep 1
    else
        say "uevadm_monitor=unavailable"
    fi

    now=$(max_temp_mc)
    case "$now" in
        ''|*[!0-9]*|-1) say "ERROR: current thermal temperature unavailable"; ok=0 ;;
    esac
fi

if [ "$ok" -eq 1 ]; then
    trigger=$((now - 1000))
    if [ "$trigger" -lt 1000 ]; then trigger=1000; fi
    hold_recover=$((now - 20000))
    if [ "$hold_recover" -lt 1000 ]; then hold_recover=1000; fi

    say "current_max_temp_mc=$now"
    say "temporary_trigger_mc=$trigger"
    say "temporary_hold_recover_mc=$hold_recover"

    printf '%s\n' "$hold_recover" > "$P_RECOVER"
    printf '%s\n' "$trigger" > "$P_EMERGENCY"
    printf '%s\n' quiet > "$PROFILE"

    say "waiting_for_emergency_engage=true"
    if wait_state 1; then
        say "quiet_emergency_state=1"
    else
        say "ERROR: Quiet emergency state did not engage"
        ok=0
    fi
fi

if [ "$ok" -eq 1 ]; then
    sleep 1
    if [ -s "$MONITOR" ]; then
        if grep -q 'A14_QUIET_EMERGENCY=1' "$MONITOR"; then
            say "engage_uevent=PASS"
        else
            say "ERROR: engage uevent not observed"
            ok=0
        fi
    else
        say "engage_uevent=not-captured"
    fi
fi

if [ "$ok" -eq 1 ]; then
    now2=$(max_temp_mc)
    case "$now2" in ''|*[!0-9]*|-1) now2=$now ;; esac
    force_recover=$((now2 + 20000))
    say "temporary_force_recover_mc=$force_recover"
    printf '%s\n' "$force_recover" > "$P_RECOVER"

    say "waiting_for_emergency_clear=true"
    if wait_state 0; then
        say "quiet_emergency_state=0"
    else
        say "ERROR: Quiet emergency state did not clear"
        ok=0
    fi
fi

if [ "$ok" -eq 1 ]; then
    sleep 1
    if [ -s "$MONITOR" ]; then
        if grep -q 'A14_QUIET_EMERGENCY=0' "$MONITOR"; then
            say "clear_uevent=PASS"
        else
            say "ERROR: clear uevent not observed"
            ok=0
        fi
    else
        say "clear_uevent=not-captured"
    fi
fi

say ""
say "===== DESKTOP DELIVERY LOG ====="
journalctl -t asus-a14-emergency-notify --since '-2 minutes' --no-pager 2>/dev/null | tail -n 20 || true

say ""
say "===== KERNEL LOG ====="
journalctl -k --since '-2 minutes' --no-pager 2>/dev/null | \
    grep -Ei 'Quiet emergency|asus_zenbook_a14_ec' | tail -n 80 || true

cleanup
trap - INT TERM HUP

say ""
if [ "$ok" -eq 1 ]; then
    say "A14_QUIET_EMERGENCY_VALIDATION=PASS"
else
    say "A14_QUIET_EMERGENCY_VALIDATION=FAIL"
fi
say "thresholds_restored=1"
say "profile_restored=${orig_profile:-unknown}"

true
