#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Read-only recorder for intermittent Qualcomm battery/power-supply visibility.
set -Eeuo pipefail

duration=${A14_BATTERY_DIAG_SECONDS:-90}
interval=${A14_BATTERY_DIAG_INTERVAL:-0.5}
report=${A14_BATTERY_DIAG_REPORT:-"$HOME/Downloads/a14-battery-flap-diag.txt"}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for tool in awk cat date grep journalctl ls sleep sudo uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run as your normal user, not with sudo"
case "$duration" in *[!0-9]*|'') fail "A14_BATTERY_DIAG_SECONDS must be an integer";; esac
[ "$duration" -ge 10 ] && [ "$duration" -le 600 ] || fail "duration must be 10..600 seconds"

sudo -v
start_epoch=$(date +%s)
start_iso=$(date --iso-8601=ns)

exec > >(tee "$report") 2>&1
printf '%s\n' 'A14 battery / PMIC-GLINK flap diagnostic'
printf '%s\n' '========================================'
printf 'started=%s\n' "$start_iso"
printf 'duration_seconds=%s\n' "$duration"
printf 'sample_interval_seconds=%s\n' "$interval"
printf 'kernel=%s\n' "$(uname -r)"
printf 'cmdline=%s\n' "$(cat /proc/cmdline)"
printf '%s\n' 'state_changes_performed=false'
printf '%s\n' 'module_reload=false'
printf '%s\n' 'runtime_pm_changes=false'
printf '%s\n' 'firmware_changes=false'

printf '\n%s\n' '===== INITIAL MODULES / POWER SUPPLIES ====='
grep -E '^(qcom_battmgr|pmic_glink|qcom_pmic_glink)[[:space:]]' /proc/modules || true
ls -la /sys/class/power_supply 2>/dev/null || true

snapshot() {
    local now names dev key value out
    now=$(date --iso-8601=ns)
    names=$(for dev in /sys/class/power_supply/*; do
        [ -e "$dev" ] || continue
        printf '%s ' "${dev##*/}"
    done)
    printf '%s supplies=[%s]' "$now" "$names"

    for dev in /sys/class/power_supply/qcom-battmgr-bat /sys/class/power_supply/BAT*; do
        [ -d "$dev" ] || continue
        printf ' battery=%s' "${dev##*/}"
        for key in present status capacity voltage_now current_now charge_now charge_full charge_full_design energy_now energy_full energy_full_design temp; do
            [ -r "$dev/$key" ] || continue
            value=$(cat "$dev/$key" 2>/dev/null || printf '?')
            printf ' %s=%s' "$key" "$value"
        done
    done
    printf '\n'
}

printf '\n%s\n' '===== POLLED POWER-SUPPLY STATE CHANGES ====='
end=$((start_epoch + duration))
prev=
while [ "$(date +%s)" -lt "$end" ]; do
    line=$(snapshot)
    # Emit only changes so a 90 s capture remains compact while preserving
    # the exact transition timestamp.
    state=${line#* supplies=}
    if [ "$state" != "$prev" ]; then
        printf '%s\n' "$line"
        prev=$state
    fi
    sleep "$interval"
done

printf '\n%s\n' '===== UPOWER VIEW ====='
if command -v upower >/dev/null 2>&1; then
    upower -e 2>&1 || true
    for dev in $(upower -e 2>/dev/null | grep -E 'battery|BAT|qcom' || true); do
        printf '%s\n' "--- $dev ---"
        upower -i "$dev" 2>&1 || true
    done
else
    printf '%s\n' 'upower=unavailable'
fi

printf '\n%s\n' '===== KERNEL EVENTS DURING CAPTURE ====='
sudo journalctl -k -b --since "@$start_epoch" --no-pager -o short-monotonic 2>/dev/null | \
    grep -Ei 'qcom[_-]battmgr|pmic[_-]glink|power_supply|battery|charger|charger_pd|PDR:|remoteproc|glink.*(down|up|state|restart)|subsystem.*restart|SSR' || true

printf '\n%s\n' '===== FINAL POWER SUPPLIES ====='
ls -la /sys/class/power_supply 2>/dev/null || true
printf 'completed=%s\n' "$(date --iso-8601=ns)"
printf 'report=%s\n' "$report"
printf '%s\n' 'state_changes_performed=false'
