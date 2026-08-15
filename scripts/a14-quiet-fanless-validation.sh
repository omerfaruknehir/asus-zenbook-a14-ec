#!/bin/sh

PROFILE=/sys/devices/platform/asus_zenbook_a14_ec/profile
EMERGENCY=/sys/devices/platform/asus_zenbook_a14_ec/quiet_emergency
ok=1
original=balanced
hwmon=""

say()
{
    printf '%s\n' "$*"
}

restore()
{
    if [ -w "$PROFILE" ]; then
        printf '%s\n' "$original" >"$PROFILE" 2>/dev/null || \
            printf '%s\n' balanced >"$PROFILE" 2>/dev/null || true
    fi
}

trap restore INT TERM HUP

if [ "$(id -u)" -ne 0 ]; then
    say "ERROR: run with sudo: sudo sh ./scripts/a14-quiet-fanless-validation.sh"
    ok=0
fi

if [ "$ok" -eq 1 ] && [ ! -r "$PROFILE" ]; then
    say "ERROR: A14 EC profile sysfs is missing"
    ok=0
fi

if [ "$ok" -eq 1 ]; then
    original=$(cat "$PROFILE" 2>/dev/null)
    case "$original" in
        quiet|power-saver|balanced|performance|full-speed) ;;
        *) original=balanced ;;
    esac
fi

if [ "$ok" -eq 1 ]; then
    for h in /sys/class/hwmon/hwmon*; do
        [ -r "$h/name" ] || continue
        name=$(cat "$h/name" 2>/dev/null)
        case "$name" in
            asus_zenbook_a14_ec|asus-zenbook-a14-ec)
                hwmon=$h
                break
                ;;
        esac
    done
    if [ -z "$hwmon" ]; then
        say "ERROR: A14 hwmon device not found"
        ok=0
    fi
fi

thermal_count=0
hottest=-1
hottest_type=none
if [ "$ok" -eq 1 ]; then
    say "===== A14 CPU THERMAL ZONES ====="
    for z in /sys/class/thermal/thermal_zone*; do
        [ -r "$z/type" ] && [ -r "$z/temp" ] || continue
        type=$(cat "$z/type" 2>/dev/null)
        case "$type" in
            cpu[0-9]-[0-9]-top-thermal|cpu[0-9]-[0-9]-btm-thermal|cpuss[0-9]-top-thermal|cpuss[0-9]-btm-thermal|cpu[0-9]_[0-9]_top_thermal|cpu[0-9]_[0-9]_btm_thermal|cpuss[0-9]_top_thermal|cpuss[0-9]_btm_thermal)
                temp=$(cat "$z/temp" 2>/dev/null)
                case "$temp" in ''|*[!0-9-]*) continue ;; esac
                thermal_count=$((thermal_count + 1))
                if [ "$temp" -gt "$hottest" ]; then
                    hottest=$temp
                    hottest_type=$type
                fi
                ;;
        esac
    done
    say "thermal_zone_count=$thermal_count"
    say "hottest_before_mc=$hottest"
    say "hottest_before_zone=$hottest_type"
    if [ "$thermal_count" -eq 0 ]; then
        say "ERROR: no real A14 CPU thermal zones found"
        ok=0
    elif [ "$hottest" -ge 70000 ]; then
        say "ERROR: system is too warm for a fan-stop validation (>=70 C)"
        ok=0
    fi
fi

if [ "$ok" -eq 1 ]; then
    say "===== BASELINE BALANCED ====="
    printf '%s\n' balanced >"$PROFILE"
    sleep 2
    say "profile=$(cat "$PROFILE" 2>/dev/null)"
    say "fan1_rpm=$(cat "$hwmon/fan1_input" 2>/dev/null || echo unavailable)"
    say "fan2_rpm=$(cat "$hwmon/fan2_input" 2>/dev/null || echo unavailable)"
    say "pwm1=$(cat "$hwmon/pwm1" 2>/dev/null || echo unavailable)"
    say "pwm2=$(cat "$hwmon/pwm2" 2>/dev/null || echo unavailable)"
    say "pwm1_enable=$(cat "$hwmon/pwm1_enable" 2>/dev/null || echo unavailable)"
fi

if [ "$ok" -eq 1 ]; then
    say "===== SELECT QUIET ====="
    printf '%s\n' quiet >"$PROFILE"
    qrc=$?
    say "quiet_write_rc=$qrc"
    if [ "$qrc" -ne 0 ]; then
        ok=0
    fi
fi

if [ "$ok" -eq 1 ]; then
    # Allow the EC command, late cpufreq QoS attachment and fan-stop transition
    # to settle before evaluating state.
    sleep 5
    profile=$(cat "$PROFILE" 2>/dev/null)
    emergency=$(cat "$EMERGENCY" 2>/dev/null || echo unavailable)
    pwm1=$(cat "$hwmon/pwm1" 2>/dev/null || echo unavailable)
    pwm2=$(cat "$hwmon/pwm2" 2>/dev/null || echo unavailable)
    enable=$(cat "$hwmon/pwm1_enable" 2>/dev/null || echo unavailable)

    say "profile=$profile"
    say "quiet_emergency=$emergency"
    say "pwm1=$pwm1"
    say "pwm2=$pwm2"
    say "pwm1_enable=$enable"

    if [ "$profile" != quiet ]; then
        say "ERROR: driver did not remain in Quiet"
        ok=0
    fi
    if [ "$emergency" != 0 ]; then
        say "ERROR: Quiet fail-safe is active; fans must not be forced off"
        ok=0
    fi
    if [ "$pwm1" != 0 ] || [ "$pwm2" != 0 ]; then
        say "ERROR: Quiet did not command zero PWM to both fans"
        ok=0
    fi
    if [ "$enable" != 1 ]; then
        say "ERROR: Quiet did not enter deliberate manual fan-stop ownership"
        ok=0
    fi
fi

if [ "$ok" -eq 1 ]; then
    say "===== FAN SPINDOWN ====="
    i=0
    fan1=unavailable
    fan2=unavailable
    while [ "$i" -lt 15 ]; do
        fan1=$(cat "$hwmon/fan1_input" 2>/dev/null || echo unavailable)
        fan2=$(cat "$hwmon/fan2_input" 2>/dev/null || echo unavailable)
        say "spindown_s=$((i + 1)) fan1_rpm=$fan1 fan2_rpm=$fan2"
        case "$fan1:$fan2" in
            *[!0-9:]* ) ;;
            * )
                if [ "$fan1" -le 500 ] && [ "$fan2" -le 500 ]; then
                    break
                fi
                ;;
        esac
        sleep 1
        i=$((i + 1))
    done

    case "$fan1:$fan2" in
        *[!0-9:]* )
            say "ERROR: fan tach readback unavailable"
            ok=0
            ;;
        * )
            if [ "$fan1" -gt 500 ] || [ "$fan2" -gt 500 ]; then
                say "ERROR: fans did not spin down to near-zero RPM"
                ok=0
            fi
            ;;
    esac
fi

if [ "$ok" -eq 1 ]; then
    hottest=-1
    hottest_type=none
    for z in /sys/class/thermal/thermal_zone*; do
        [ -r "$z/type" ] && [ -r "$z/temp" ] || continue
        type=$(cat "$z/type" 2>/dev/null)
        case "$type" in
            cpu[0-9]-[0-9]-top-thermal|cpu[0-9]-[0-9]-btm-thermal|cpuss[0-9]-top-thermal|cpuss[0-9]-btm-thermal|cpu[0-9]_[0-9]_top_thermal|cpu[0-9]_[0-9]_btm_thermal|cpuss[0-9]_top_thermal|cpuss[0-9]_btm_thermal)
                temp=$(cat "$z/temp" 2>/dev/null)
                case "$temp" in ''|*[!0-9-]*) continue ;; esac
                if [ "$temp" -gt "$hottest" ]; then
                    hottest=$temp
                    hottest_type=$type
                fi
                ;;
        esac
    done
    say "hottest_after_mc=$hottest"
    say "hottest_after_zone=$hottest_type"
    if [ "$hottest" -ge 75000 ]; then
        say "ERROR: unexpected temperature rise during no-load fan-stop test"
        ok=0
    fi
fi

restore
sleep 2
say "===== RESTORE ====="
say "restored_profile=$(cat "$PROFILE" 2>/dev/null)"
say "restored_pwm1_enable=$(cat "$hwmon/pwm1_enable" 2>/dev/null || echo unavailable)"
say "restored_fan1_rpm=$(cat "$hwmon/fan1_input" 2>/dev/null || echo unavailable)"

say "===== KERNEL LOG ====="
journalctl -k -b --since '-5 minutes' --no-pager 2>/dev/null | \
    grep -Ei 'asus_zenbook_a14_ec|Quiet CPU|thermal zones|fan-stop|freq QoS' | tail -n 100 || true

say ""
if [ "$ok" -eq 1 ]; then
    say "A14_QUIET_FANLESS_VALIDATION=PASS"
else
    say "A14_QUIET_FANLESS_VALIDATION=FAIL"
fi

trap - INT TERM HUP
true
