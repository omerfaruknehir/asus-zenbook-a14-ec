#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Read-only TLMM/pinctrl audit for the camera-related CAMP GPIO candidates.
# This script does not load SSC/HPD, change pinmux state, touch clocks, or
# access the CPAS ownership register.
set -Eeuo pipefail

pins=(96 97 98 99 100 101 102 103 104 105 106)
report=${A14_AOS_TLMM_REPORT:-"$HOME/Downloads/a14-aos-tlmm-pin-audit.txt"}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for tool in cat find grep lsmod mount readlink sed sudo tee; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done

ensure_debugfs() {
    if mountpoint -q /sys/kernel/debug 2>/dev/null; then
        return 0
    fi
    sudo mount -t debugfs debugfs /sys/kernel/debug
}

pin_regex='pin (96|97|98|99|100|101|102|103|104|105|106)([^0-9]|$)'
name_regex='(^|[^0-9])(gpio[_ -]?(96|97|98|99|100|101|102|103|104|105|106))([^0-9]|$)'

exec > >(tee "$report") 2>&1

printf '%s\n' 'A14 AOS TLMM/pinctrl read-only audit'
printf '%s\n' '=================================='
printf 'kernel_release=%s\n' "$(uname -r)"
printf 'cmdline=%s\n' "$(cat /proc/cmdline)"
printf 'report=%s\n' "$report"
printf '%s\n' 'ssc_activation=false'
printf '%s\n' 'pin_state_changes=false'
printf '%s\n' 'clock_state_changes=false'
printf '%s\n' 'cpas_ownership_mux_access=false'
printf 'candidate_gpios=%s\n' "${pins[*]}"

if grep -Eq '^qcom_ssc_hpd[[:space:]]' /proc/modules; then
    printf '%s\n' 'qcom_ssc_hpd_loaded=true'
else
    printf '%s\n' 'qcom_ssc_hpd_loaded=false'
fi

printf '\n%s\n' '===== PINCTRL DEBUGFS ====='
ensure_debugfs
controllers=0
matches=0
for ctrl in /sys/kernel/debug/pinctrl/*; do
    [ -d "$ctrl" ] || continue
    controllers=$((controllers + 1))
    printf '\ncontroller=%s\n' "$(basename "$ctrl")"
    for file in pinmux-pins pins pingroups; do
        path="$ctrl/$file"
        [ -r "$path" ] || continue
        printf '%s\n' "--- $file ---"
        out=$(grep -E "$pin_regex|$name_regex" "$path" 2>/dev/null || true)
        if [ -n "$out" ]; then
            printf '%s\n' "$out"
            matches=$((matches + $(printf '%s\n' "$out" | wc -l)))
        else
            printf '%s\n' '(no candidate-pin matches)'
        fi
    done
done
printf '\npinctrl_controller_count=%s\n' "$controllers"
printf 'pinctrl_candidate_match_lines=%s\n' "$matches"

printf '\n%s\n' '===== LIVE DEVICE-TREE TEXT REFERENCES ====='
# DT properties are NUL-separated/binary. Search only printable string content;
# this is diagnostic and does not modify the live tree.
dt=/sys/firmware/devicetree/base
if [ -d "$dt" ]; then
    dt_matches=0
    while IFS= read -r -d '' f; do
        # Skip very large binary blobs. Camera/pinctrl string properties are tiny.
        size=$(stat -c %s "$f" 2>/dev/null || printf '0')
        [ "$size" -le 65536 ] || continue
        text=$(tr '\000' '\n' < "$f" 2>/dev/null | \
            grep -Eai 'cam_aon|camera|hm1092|ov02c10|gpio(96|97|98|99|100|101|102|103|104|105|106)' || true)
        [ -n "$text" ] || continue
        rel=${f#"$dt"/}
        printf 'dt_property=%s\n' "$rel"
        printf '%s\n' "$text" | sed 's/^/  /'
        dt_matches=$((dt_matches + 1))
    done < <(find "$dt" -type f -print0)
    printf 'dt_matching_properties=%s\n' "$dt_matches"
else
    printf '%s\n' 'device_tree_available=false'
fi

printf '\n%s\n' '===== GPIO CHARACTER-DEVICE SNAPSHOT ====='
if command -v gpioinfo >/dev/null 2>&1; then
    # gpioinfo syntax/output differs between libgpiod versions; run the global
    # read-only listing and retain only exact candidate offsets where possible.
    gpio_dump=$(gpioinfo 2>&1 || true)
    printf '%s\n' "$gpio_dump" | awk '
        BEGIN { want[96]=want[97]=want[98]=want[99]=want[100]=want[101]=want[102]=want[103]=want[104]=want[105]=want[106]=1 }
        /^gpiochip/ { chip=$0; next }
        {
            line=$0
            if (match(line, /line[[:space:]]+([0-9]+):/, m)) {
                n=m[1]+0
                if (want[n]) { print chip; print line }
            } else if (match(line, /^[[:space:]]*([0-9]+):/, m)) {
                n=m[1]+0
                if (want[n]) { print chip; print line }
            }
        }' || true
else
    printf '%s\n' 'gpioinfo=unavailable'
fi

printf '\n%s\n' '===== CURRENT CAMERA OWNER STATE ====='
for dev in /sys/bus/platform/devices/acb7000.isp \
           /sys/bus/platform/devices/ac15000.cci \
           /sys/bus/platform/devices/ac16000.cci; do
    [ -d "$dev" ] || continue
    printf 'device=%s runtime_status=%s\n' \
        "$(basename "$dev")" "$(cat "$dev/power/runtime_status" 2>/dev/null || printf 'unknown')"
done

printf '\n%s\n' 'audit_result=complete'
printf '%s\n' 'state_changes_performed=false'
