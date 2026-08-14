#!/bin/sh

# Compare the recovered A14 native firmware profiles under a controlled CPU
# load. This touches only the driver's profile sysfs interface and reads
# hwmon/cpufreq/thermal state. It performs no raw EC/MMIO access.

PROFILE=""
HWMON=""
LOAD_PIDS=""
STOPPED=0
CUTOFF_MC=85000
SAMPLES_PER_PROFILE=5
SAMPLE_INTERVAL=2

say()
{
    printf '%s\n' "$*"
}

find_nodes()
{
    for f in /sys/devices/platform/asus_zenbook_a14_ec/profile \
             /sys/devices/platform/asus_zenbook_a14_ec.*/profile; do
        if [ -r "$f" ] && [ -w "$f" ]; then
            PROFILE=$f
            break
        fi
    done

    for h in /sys/class/hwmon/hwmon*; do
        if [ -r "$h/name" ] && [ "$(cat "$h/name" 2>/dev/null)" = asus_zenbook_a14_ec ]; then
            HWMON=$h
            break
        fi
    done
}

read_num()
{
    if [ -r "$1" ]; then
        cat "$1" 2>/dev/null
    fi
}

hottest_thermal()
{
    hottest=-1
    hottest_name=none

    for z in /sys/class/thermal/thermal_zone*; do
        [ -r "$z/temp" ] || continue
        t=$(cat "$z/temp" 2>/dev/null)
        case "$t" in
            ''|*[!0-9]*) continue ;;
        esac

        if [ "$t" -gt "$hottest" ]; then
            hottest=$t
            if [ -r "$z/type" ]; then
                hottest_name=$(cat "$z/type" 2>/dev/null)
            else
                hottest_name=$(basename "$z")
            fi
        fi
    done

    printf '%s %s' "$hottest" "$hottest_name"
}

cpu_freq_summary()
{
    vals=""
    for f in /sys/devices/system/cpu/cpufreq/policy*/scaling_cur_freq; do
        if [ -r "$f" ]; then
            v=$(cat "$f" 2>/dev/null)
            case "$v" in
                ''|*[!0-9]*) ;;
                *) vals="$vals $v" ;;
            esac
        fi
    done

    if [ -n "$vals" ]; then
        printf '%s\n' "$vals" | awk '{
            n=0; sum=0; max=0;
            for (i=1; i<=NF; i++) {
                if ($i ~ /^[0-9]+$/) {
                    n++; sum += $i; if ($i > max) max=$i;
                }
            }
            if (n) printf "cpu_freq_avg_khz=%d cpu_freq_max_khz=%d", sum/n, max;
            else printf "cpu_freq_avg_khz=unavailable cpu_freq_max_khz=unavailable";
        }'
    else
        printf '%s' 'cpu_freq_avg_khz=unavailable cpu_freq_max_khz=unavailable'
    fi
}

stop_load()
{
    if [ "$STOPPED" -eq 0 ]; then
        for p in $LOAD_PIDS; do
            kill "$p" 2>/dev/null || true
        done
        for p in $LOAD_PIDS; do
            wait "$p" 2>/dev/null || true
        done
        STOPPED=1
    fi
}

restore_balanced()
{
    if [ -n "$PROFILE" ] && [ -w "$PROFILE" ]; then
        printf '%s\n' balanced > "$PROFILE" 2>/dev/null || true
    fi
}

cleanup()
{
    stop_load
    restore_balanced
}

trap cleanup INT TERM HUP

sample()
{
    requested=$1
    index=$2
    profile=$(cat "$PROFILE" 2>/dev/null)
    fan1=$(read_num "$HWMON/fan1_input")
    fan2=$(read_num "$HWMON/fan2_input")
    ec_temp=$(read_num "$HWMON/temp1_input")
    pwm1=$(read_num "$HWMON/pwm1")
    pwm2=$(read_num "$HWMON/pwm2")
    freq=$(cpu_freq_summary)
    thermal=$(hottest_thermal)
    system_temp=$(printf '%s' "$thermal" | awk '{print $1}')
    system_zone=$(printf '%s' "$thermal" | cut -d' ' -f2-)

    say "sample profile_requested=$requested profile_reported=${profile:-?} n=$index ec_temp_mc=${ec_temp:-?} system_max_temp_mc=${system_temp:-?} system_max_zone=${system_zone:-?} fan1_rpm=${fan1:-?} fan2_readout=${fan2:-?} pwm1=${pwm1:-?} pwm2=${pwm2:-?} $freq"

    hottest=$system_temp
    case "$hottest" in
        ''|*[!0-9]*) hottest=-1 ;;
    esac
    case "$ec_temp" in
        ''|*[!0-9]*) ;;
        *)
            if [ "$ec_temp" -gt "$hottest" ]; then
                hottest=$ec_temp
            fi
            ;;
    esac

    if [ "$hottest" -ge "$CUTOFF_MC" ]; then
        say "thermal_cutoff=true hottest_mc=$hottest cutoff_mc=$CUTOFF_MC"
        return 1
    fi
    return 0
}

run_profile()
{
    requested=$1

    say ""
    say "===== PROFILE $requested UNDER LOAD ====="
    printf '%s\n' "$requested" > "$PROFILE" 2>/dev/null
    rc=$?
    say "profile_write_rc=$rc"
    if [ "$rc" -ne 0 ]; then
        return 1
    fi

    n=1
    while [ "$n" -le "$SAMPLES_PER_PROFILE" ]; do
        sleep "$SAMPLE_INTERVAL"
        sample "$requested" "$n" || return 1
        n=$((n + 1))
    done
    return 0
}

ok=1

if [ "$(id -u)" -ne 0 ]; then
    say "ERROR: run with sudo: sudo sh ./scripts/a14-ec-profile-load-validation.sh"
    ok=0
fi

if [ "$ok" -eq 1 ]; then
    find_nodes
    say "profile_path=${PROFILE:-missing}"
    say "hwmon_path=${HWMON:-missing}"
    if [ -z "$PROFILE" ] || [ -z "$HWMON" ]; then
        ok=0
    fi
fi

if [ "$ok" -eq 1 ]; then
    say "profile_choices=$(cat "$(dirname "$PROFILE")/profile_choices" 2>/dev/null)"
    say "thermal_cutoff_mc=$CUTOFF_MC"

    cpu_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null)
    case "$cpu_count" in
        ''|*[!0-9]*) cpu_count=1 ;;
    esac
    if [ "$cpu_count" -gt 12 ]; then
        cpu_count=12
    fi

    say "load_threads=$cpu_count"
    i=0
    while [ "$i" -lt "$cpu_count" ]; do
        yes >/dev/null &
        LOAD_PIDS="$LOAD_PIDS $!"
        i=$((i + 1))
    done

    say "load_started=true"
    sleep 4

    # Alternate every experimental policy with balanced. This reduces the
    # chance that a simple temperature ramp is mistaken for a profile effect.
    for requested in balanced quiet balanced performance balanced full-speed balanced; do
        if [ "$ok" -eq 1 ]; then
            run_profile "$requested" || ok=0
        fi
    done
fi

cleanup
sleep 2

say ""
say "===== FINAL ====="
if [ -n "$PROFILE" ]; then
    say "final_profile=$(cat "$PROFILE" 2>/dev/null)"
fi
if [ -n "$HWMON" ]; then
    say "final_ec_temp_mc=$(read_num "$HWMON/temp1_input")"
    say "final_fan1_rpm=$(read_num "$HWMON/fan1_input")"
fi
thermal=$(hottest_thermal)
say "final_system_max_temp_mc=$(printf '%s' "$thermal" | awk '{print $1}')"
say "final_system_max_zone=$(printf '%s' "$thermal" | cut -d' ' -f2-)"

if [ "$ok" -eq 1 ]; then
    say "A14_EC_PROFILE_LOAD_CAPTURE=COMPLETE"
else
    say "A14_EC_PROFILE_LOAD_CAPTURE=STOPPED"
fi

true
