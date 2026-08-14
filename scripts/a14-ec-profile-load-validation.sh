#!/bin/sh

# Validate the five named A14 policies under controlled CPU load. This touches
# only normal profile/hwmon/cpufreq/thermal interfaces; no raw EC/MMIO access.

PROFILE=""
HWMON=""
LOAD_PIDS=""
CUTOFF_MC=${A14_CUTOFF_MC:-82000}
COOLDOWN_TARGET_MC=${A14_COOLDOWN_TARGET_MC:-65000}
COOLDOWN_MAX_S=${A14_COOLDOWN_MAX_S:-60}
SAMPLES_PER_PROFILE=${A14_SAMPLES_PER_PROFILE:-4}
SAMPLE_INTERVAL=${A14_SAMPLE_INTERVAL:-2}
LOAD_THREADS=${A14_LOAD_THREADS:-6}
ATTEMPTED=0
CUTOFF_COUNT=0
FULL_SPEED_MAX_SEEN=0

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

numeric_summary()
{
    if [ -n "$1" ]; then
        printf '%s\n' "$1" | awk '{
            n=0; sum=0; max=0; min=0;
            for (i=1; i<=NF; i++) {
                if ($i ~ /^[0-9]+$/) {
                    n++; sum += $i;
                    if ($i > max) max=$i;
                    if (min == 0 || $i < min) min=$i;
                }
            }
            if (n) printf "%d %d %d", sum/n, min, max;
        }'
    fi
}

cpu_freq_summary()
{
    vals=""

    # Snapdragon X Elite exposes useful average-frequency telemetry per CPU.
    for f in /sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_avg_freq; do
        if [ -r "$f" ]; then
            v=$(cat "$f" 2>/dev/null)
            case "$v" in ''|*[!0-9]*) ;; *) vals="$vals $v" ;; esac
        fi
    done

    # Fall back to scaling_cur_freq only if cpuinfo_avg_freq is unavailable.
    if [ -z "$vals" ]; then
        for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq \
                 /sys/devices/system/cpu/cpufreq/policy*/scaling_cur_freq; do
            if [ -r "$f" ]; then
                v=$(cat "$f" 2>/dev/null)
                case "$v" in ''|*[!0-9]*) ;; *) vals="$vals $v" ;; esac
            fi
        done
    fi

    summary=$(numeric_summary "$vals")
    if [ -n "$summary" ]; then
        avg=$(printf '%s' "$summary" | awk '{print $1}')
        min=$(printf '%s' "$summary" | awk '{print $2}')
        max=$(printf '%s' "$summary" | awk '{print $3}')
        printf 'cpu_freq_avg_khz=%s cpu_freq_min_khz=%s cpu_freq_max_khz=%s' "$avg" "$min" "$max"
    else
        printf '%s' 'cpu_freq_avg_khz=unavailable cpu_freq_min_khz=unavailable cpu_freq_max_khz=unavailable'
    fi
}

cpu_cap_summary()
{
    vals=""
    native=""

    for f in /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq; do
        if [ -r "$f" ]; then
            v=$(cat "$f" 2>/dev/null)
            case "$v" in ''|*[!0-9]*) ;; *) vals="$vals $v" ;; esac
        fi
    done
    for f in /sys/devices/system/cpu/cpufreq/policy*/cpuinfo_max_freq; do
        if [ -r "$f" ]; then
            v=$(cat "$f" 2>/dev/null)
            case "$v" in ''|*[!0-9]*) ;; *) native="$native $v" ;; esac
        fi
    done

    cap=$(numeric_summary "$vals")
    hw=$(numeric_summary "$native")
    if [ -n "$cap" ]; then
        printf 'qos_scaling_max_avg_khz=%s qos_scaling_max_min_khz=%s qos_scaling_max_max_khz=%s' \
            "$(printf '%s' "$cap" | awk '{print $1}')" \
            "$(printf '%s' "$cap" | awk '{print $2}')" \
            "$(printf '%s' "$cap" | awk '{print $3}')"
    else
        printf 'qos_scaling_max_avg_khz=unavailable'
    fi
    if [ -n "$hw" ]; then
        printf ' cpu_native_max_avg_khz=%s' "$(printf '%s' "$hw" | awk '{print $1}')"
    fi
}

stop_load()
{
    for p in $LOAD_PIDS; do
        kill "$p" 2>/dev/null || true
    done
    for p in $LOAD_PIDS; do
        wait "$p" 2>/dev/null || true
    done
    LOAD_PIDS=""
}

start_load()
{
    stop_load
    i=0
    while [ "$i" -lt "$LOAD_THREADS" ]; do
        yes >/dev/null &
        LOAD_PIDS="$LOAD_PIDS $!"
        i=$((i + 1))
    done
    say "load_started=true threads=$LOAD_THREADS"
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
    pwm_enable=$(read_num "$HWMON/pwm1_enable")
    freq=$(cpu_freq_summary)
    caps=$(cpu_cap_summary)
    thermal=$(hottest_thermal)
    system_temp=$(printf '%s' "$thermal" | awk '{print $1}')
    system_zone=$(printf '%s' "$thermal" | cut -d' ' -f2-)

    say "sample profile_requested=$requested profile_reported=${profile:-?} n=$index ec_temp_mc=${ec_temp:-?} system_max_temp_mc=${system_temp:-?} system_max_zone=${system_zone:-?} fan1_rpm=${fan1:-?} fan2_readout=${fan2:-?} pwm1=${pwm1:-?} pwm2=${pwm2:-?} pwm1_enable=${pwm_enable:-?} $freq $caps"

    if [ "$requested" = full-speed ] && [ "$pwm1" = 255 ] && [ "$pwm2" = 255 ]; then
        FULL_SPEED_MAX_SEEN=1
    fi

    hottest=$system_temp
    case "$hottest" in ''|*[!0-9]*) hottest=-1 ;; esac
    case "$ec_temp" in
        ''|*[!0-9]*) ;;
        *) if [ "$ec_temp" -gt "$hottest" ]; then hottest=$ec_temp; fi ;;
    esac

    if [ "$hottest" -ge "$CUTOFF_MC" ]; then
        say "thermal_cutoff=true profile=$requested hottest_mc=$hottest cutoff_mc=$CUTOFF_MC"
        return 1
    fi
    return 0
}

wait_for_cool_baseline()
{
    stop_load
    restore_balanced
    waited=0

    while [ "$waited" -le "$COOLDOWN_MAX_S" ]; do
        thermal=$(hottest_thermal)
        system_temp=$(printf '%s' "$thermal" | awk '{print $1}')
        system_zone=$(printf '%s' "$thermal" | cut -d' ' -f2-)
        case "$system_temp" in
            ''|*[!0-9]*) say "cooldown_temp_unavailable=true"; return 0 ;;
        esac

        if [ "$system_temp" -le "$COOLDOWN_TARGET_MC" ]; then
            say "cooldown_ready=true temp_mc=$system_temp zone=$system_zone waited_s=$waited"
            return 0
        fi
        if [ "$waited" -eq 0 ] || [ $((waited % 10)) -eq 0 ]; then
            say "cooldown_wait temp_mc=$system_temp zone=$system_zone target_mc=$COOLDOWN_TARGET_MC waited_s=$waited"
        fi
        sleep 2
        waited=$((waited + 2))
    done

    say "cooldown_ready=false target_mc=$COOLDOWN_TARGET_MC max_wait_s=$COOLDOWN_MAX_S"
    return 1
}

run_profile()
{
    requested=$1
    wait_for_cool_baseline || return 2

    say ""
    say "===== PROFILE $requested FRESH LOAD ====="
    printf '%s\n' "$requested" > "$PROFILE" 2>/dev/null
    rc=$?
    say "profile_write_rc=$rc"
    if [ "$rc" -ne 0 ]; then
        return 1
    fi

    say "after_write_caps=$(cpu_cap_summary)"
    start_load
    sleep 2

    n=1
    while [ "$n" -le "$SAMPLES_PER_PROFILE" ]; do
        sleep "$SAMPLE_INTERVAL"
        sample "$requested" "$n"
        sample_rc=$?
        if [ "$sample_rc" -ne 0 ]; then
            stop_load
            restore_balanced
            return 3
        fi
        n=$((n + 1))
    done

    stop_load
    restore_balanced
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
    choices=$(cat "$(dirname "$PROFILE")/profile_choices" 2>/dev/null)
    say "profile_choices=$choices"
    for required in quiet power-saver balanced performance full-speed; do
        case " $choices " in
            *" $required "*) ;;
            *) say "ERROR: missing profile choice: $required"; ok=0 ;;
        esac
    done
fi

if [ "$ok" -eq 1 ]; then
    online=$(getconf _NPROCESSORS_ONLN 2>/dev/null)
    case "$online" in ''|*[!0-9]*) online=1 ;; esac
    case "$LOAD_THREADS" in ''|*[!0-9]*) LOAD_THREADS=6 ;; esac
    if [ "$LOAD_THREADS" -lt 1 ]; then LOAD_THREADS=1; fi
    if [ "$LOAD_THREADS" -gt "$online" ]; then LOAD_THREADS=$online; fi

    say "thermal_cutoff_mc=$CUTOFF_MC"
    say "cooldown_target_mc=$COOLDOWN_TARGET_MC"
    say "samples_per_profile=$SAMPLES_PER_PROFILE interval_s=$SAMPLE_INTERVAL"
    say "load_threads=$LOAD_THREADS online_cpus=$online"
    say "baseline_caps=$(cpu_cap_summary)"

    for requested in quiet power-saver balanced performance full-speed; do
        if [ "$ok" -eq 1 ]; then
            ATTEMPTED=$((ATTEMPTED + 1))
            run_profile "$requested"
            rc=$?
            case "$rc" in
                0) say "profile_capture=$requested complete" ;;
                3) CUTOFF_COUNT=$((CUTOFF_COUNT + 1)); say "profile_capture=$requested stopped_at_thermal_cutoff" ;;
                *) say "profile_capture=$requested failed rc=$rc"; ok=0 ;;
            esac
        fi
    done
fi

cleanup
sleep 2

say ""
say "===== FINAL ====="
if [ -n "$PROFILE" ]; then say "final_profile=$(cat "$PROFILE" 2>/dev/null)"; fi
if [ -n "$HWMON" ]; then
    say "final_ec_temp_mc=$(read_num "$HWMON/temp1_input")"
    say "final_fan1_rpm=$(read_num "$HWMON/fan1_input")"
fi
thermal=$(hottest_thermal)
say "final_system_max_temp_mc=$(printf '%s' "$thermal" | awk '{print $1}')"
say "final_system_max_zone=$(printf '%s' "$thermal" | cut -d' ' -f2-)"
say "profiles_attempted=$ATTEMPTED thermal_cutoff_profiles=$CUTOFF_COUNT"
say "full_speed_pwm255_seen=$FULL_SPEED_MAX_SEEN"

if [ "$ok" -eq 1 ] && [ "$ATTEMPTED" -eq 5 ] && [ "$FULL_SPEED_MAX_SEEN" -eq 1 ]; then
    if [ "$CUTOFF_COUNT" -eq 0 ]; then
        say "A14_EC_PROFILE_POLICY_VALIDATION=PASS"
    else
        say "A14_EC_PROFILE_POLICY_VALIDATION=PASS_WITH_CUTOFF"
    fi
else
    say "A14_EC_PROFILE_POLICY_VALIDATION=FAIL"
fi

true
