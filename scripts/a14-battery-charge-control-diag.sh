#!/bin/sh

label=${1:-snapshot}
out=${A14_BATTERY_DIAG_OUT:-$HOME/Downloads/a14-battery-charge-control-diag.txt}

section() {
    printf '\n===== %s =====\n' "$1"
}

show_file() {
    path=$1
    if [ -r "$path" ]; then
        printf '%s=' "$path"
        cat "$path" 2>/dev/null || true
    fi
}

{
    printf '\n\n########################################\n'
    printf 'A14 BATTERY CHARGE CONTROL SNAPSHOT\n'
    printf 'label=%s\n' "$label"
    printf 'time=%s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
    printf 'kernel=%s\n' "$(uname -r)"
    printf '########################################\n'

    section "POWER SUPPLY SYSFS"
    found=0
    for bat in /sys/class/power_supply/*; do
        [ -d "$bat" ] || continue
        type=$(cat "$bat/type" 2>/dev/null || true)
        [ "$type" = Battery ] || continue
        found=1
        printf '\n-- %s --\n' "$bat"
        for name in \
            status capacity present \
            charge_control_start_threshold charge_control_end_threshold \
            charge_control_limit charge_control_limit_max \
            current_now power_now voltage_now; do
            show_file "$bat/$name"
        done
    done
    [ "$found" -eq 1 ] || printf 'No Battery power_supply node found.\n'

    section "UPOWER"
    if command -v upower >/dev/null 2>&1; then
        printf '%s\n' '-- devices --'
        upower -e 2>&1 || true
        printf '%s\n' '-- battery objects --'
        for dev in $(upower -e 2>/dev/null | grep -E '/battery_|/DisplayDevice$' || true); do
            printf '\n[%s]\n' "$dev"
            upower -i "$dev" 2>&1 | grep -Ei \
                'state:|percentage:|energy-rate:|time to|charge|threshold|native-path|power supply' || true
        done
    else
        printf 'upower command not installed.\n'
    fi

    section "UPOWER DBUS BATTERY PROPERTIES"
    if command -v busctl >/dev/null 2>&1; then
        if command -v upower >/dev/null 2>&1; then
            for dev in $(upower -e 2>/dev/null | grep '/battery_' || true); do
                printf '\n[%s]\n' "$dev"
                busctl get-property org.freedesktop.UPower "$dev" org.freedesktop.UPower.Device ChargeThresholdSupported 2>&1 || true
                busctl get-property org.freedesktop.UPower "$dev" org.freedesktop.UPower.Device ChargeThresholdEnabled 2>&1 || true
                busctl get-property org.freedesktop.UPower "$dev" org.freedesktop.UPower.Device ChargeStartThreshold 2>&1 || true
                busctl get-property org.freedesktop.UPower "$dev" org.freedesktop.UPower.Device ChargeEndThreshold 2>&1 || true
                busctl get-property org.freedesktop.UPower "$dev" org.freedesktop.UPower.Device State 2>&1 || true
                busctl get-property org.freedesktop.UPower "$dev" org.freedesktop.UPower.Device Percentage 2>&1 || true
            done
        fi
    else
        printf 'busctl command not installed.\n'
    fi

    section "QCOM BATTMGR KERNEL LOG"
    journalctl -k -b --no-pager 2>/dev/null | grep -Ei \
        'qcom[-_ ]?battmgr|battmgr|charge.*threshold|charge.*control|pmic.*glink|battery.*glink' | tail -n 250 || true

    section "UPOWER SERVICE LOG"
    journalctl -b -u upower --no-pager 2>/dev/null | tail -n 200 || true

    section "NOTES"
    printf '%s\n' 'This script is read-only. It does not change charge thresholds, firmware state, or UPower settings.'
} >>"$out"

printf 'Battery charge-control snapshot appended to: %s\n' "$out"
printf 'label=%s\n' "$label"
