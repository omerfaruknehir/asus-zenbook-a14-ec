#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Read-only TLMM/pinctrl audit for the camera-related CAMP GPIO candidates.
# This script does not load SSC/HPD, change pinmux state, touch clocks, mount
# filesystems, or access the CPAS ownership register.
set -Eeuo pipefail

pins=(96 97 98 99 100 101 102 103 104 105 106)
report=${A14_AOS_TLMM_REPORT:-"$HOME/Downloads/a14-aos-tlmm-pin-audit.txt"}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for tool in basename cat find grep lsmod sed stat sudo tee tr uname wc; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done

pin_regex='pin (96|97|98|99|100|101|102|103|104|105|106)([^0-9]|$)'
name_regex='(^|[^0-9])(gpio[_ -]?(96|97|98|99|100|101|102|103|104|105|106))([^0-9]|$)'
line_regex='(^|[[:space:]])(line[[:space:]]+)?(96|97|98|99|100|101|102|103|104|105|106):'

exec > >(tee "$report") 2>&1

printf '%s\n' 'A14 AOS TLMM/pinctrl read-only audit'
printf '%s\n' '=================================='
printf 'kernel_release=%s\n' "$(uname -r)"
printf 'cmdline=%s\n' "$(cat /proc/cmdline)"
printf 'report=%s\n' "$report"
printf '%s\n' 'ssc_activation=false'
printf '%s\n' 'pin_state_changes=false'
printf '%s\n' 'clock_state_changes=false'
printf '%s\n' 'filesystem_mount_changes=false'
printf '%s\n' 'cpas_ownership_mux_access=false'
printf 'candidate_gpios=%s\n' "${pins[*]}"

if grep -Eq '^qcom_ssc_hpd[[:space:]]' /proc/modules; then
    printf '%s\n' 'qcom_ssc_hpd_loaded=true'
else
    printf '%s\n' 'qcom_ssc_hpd_loaded=false'
fi

printf '\n%s\n' '===== PINCTRL DEBUGFS ====='
controllers=0
matches=0
if grep -qsE '[[:space:]]/sys/kernel/debug[[:space:]]+debugfs[[:space:]]' /proc/mounts; then
    # Reading pinctrl debugfs typically requires root. sudo is used only for
    # read operations; no mount, write, bind/unbind or pinctrl operation occurs.
    sudo -v
    mapfile -t ctrl_paths < <(sudo find /sys/kernel/debug/pinctrl \
        -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null || true)
    for ctrl in "${ctrl_paths[@]}"; do
        controllers=$((controllers + 1))
        printf '\ncontroller=%s\n' "$(basename "$ctrl")"
        # pinmux identifies the function/owner while pinconf exposes the
        # currently programmed bias, drive strength and input/output state when
        # the Qualcomm pinctrl driver provides those debugfs views.
        for file in pinmux-pins pins pingroups pinconf-pins pinconf-groups; do
            path="$ctrl/$file"
            sudo test -r "$path" 2>/dev/null || continue
            printf '%s\n' "--- $file ---"
            out=$(sudo grep -E "$pin_regex|$name_regex" "$path" 2>/dev/null || true)
            if [ -n "$out" ]; then
                printf '%s\n' "$out"
                count=$(printf '%s\n' "$out" | wc -l)
                matches=$((matches + count))
            else
                printf '%s\n' '(no candidate-pin matches)'
            fi
        done
    done
else
    printf '%s\n' 'debugfs_pinctrl_available=false'
    printf '%s\n' 'debugfs_note=debugfs is not mounted; audit deliberately did not mount it'
fi
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
    # gpioinfo is read-only. Its output format differs between libgpiod v1/v2,
    # so retain exact candidate-offset lines without assuming a specific parser.
    gpio_dump=$(gpioinfo 2>&1 || true)
    gpio_matches=$(printf '%s\n' "$gpio_dump" | grep -E "$line_regex" || true)
    if [ -n "$gpio_matches" ]; then
        printf '%s\n' "$gpio_matches"
    else
        printf '%s\n' '(no candidate GPIO offsets matched gpioinfo output)'
    fi
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
