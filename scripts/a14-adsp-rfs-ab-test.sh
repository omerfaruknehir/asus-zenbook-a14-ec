#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Reversible A/B test: stop only the experimental A14 SSC Hexagon reverse-
# filesystem service and observe whether the already-recovering ADSP stabilizes.
set -Eeuo pipefail

unit=a14-ssc-hexagonrpcd.service
runtime=/var/lib/a14-ssc/runtime
report=${A14_ADSP_RFS_AB_REPORT:-"$HOME/Downloads/a14-adsp-rfs-ab-test.txt"}
observe_seconds=${A14_ADSP_RFS_AB_SECONDS:-15}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for tool in cat date find grep journalctl ls sha256sum sleep sudo systemctl tee; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run as your normal user, not with sudo"
case "$observe_seconds" in *[!0-9]*|'') fail "A14_ADSP_RFS_AB_SECONDS must be an integer";; esac
[ "$observe_seconds" -ge 8 ] && [ "$observe_seconds" -le 60 ] || fail "observation must be 8..60 seconds"
case " $(cat /proc/cmdline) " in
    *' a14_aos_f0_icp_owner_test=1 '*) fail "run this A/B only from the normal boot, not the AOS one-shot boot";;
    *) ;;
esac

sudo -v
exec > >(tee "$report") 2>&1
printf '%s\n' 'A14 ADSP / SSC reverse-filesystem A/B'
printf '%s\n' '======================================='
printf 'timestamp=%s\n' "$(date --iso-8601=ns)"
printf 'unit=%s\n' "$unit"
printf 'runtime=%s\n' "$runtime"
printf 'observation_seconds=%s\n' "$observe_seconds"
printf '%s\n' 'firmware_changes=false'
printf '%s\n' 'module_reload=false'
printf '%s\n' 'remoteproc_manual_control=false'
printf '%s\n' 'service_disable=false'

active_before=$(systemctl is-active "$unit" 2>/dev/null || true)
enabled_before=$(systemctl is-enabled "$unit" 2>/dev/null || true)
printf 'service_active_before=%s\n' "$active_before"
printf 'service_enabled_before=%s\n' "$enabled_before"

printf '\n%s\n' '===== UNIT ====='
systemctl --no-pager --full status "$unit" 2>&1 || true
systemctl cat "$unit" 2>&1 || true

printf '\n%s\n' '===== REVERSE-FS SENSOR CONTENT ====='
if [ -d "$runtime" ]; then
    find "$runtime" -maxdepth 4 -type f \
        \( -path '*/sensors/*' -o -name 'qsh_camera*.json' -o -name '*ov02c10*' \) \
        -print | sort
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        sha256sum "$f"
    done < <(find "$runtime" -maxdepth 4 -type f \
        \( -path '*/sensors/*' -o -name 'qsh_camera*.json' -o -name '*ov02c10*' \) \
        -print | sort)
else
    printf 'runtime_directory=missing\n'
fi

crash_count() {
    sudo journalctl -k -b --no-pager -o cat 2>/dev/null | \
        grep -Ec 'remoteproc remoteproc0: handling crash #[0-9]+' || true
}

state_line() {
    local rp=/sys/class/remoteproc/remoteproc0
    printf 'adsp_state=%s adsp_firmware=%s\n' \
        "$(cat "$rp/state" 2>/dev/null || printf unavailable)" \
        "$(cat "$rp/firmware" 2>/dev/null || printf unavailable)"
}

printf '\n%s\n' '===== BASELINE ====='
crashes_before=$(crash_count)
printf 'adsp_crashes_before=%s\n' "$crashes_before"
state_line
cat /proc/asound/cards 2>/dev/null || true

if [ "$active_before" = active ]; then
    printf '\n%s\n' '===== STOP ONLY EXPERIMENTAL REVERSE-FS SERVICE ====='
    stop_time=$(date --iso-8601=seconds)
    printf 'stop_time=%s\n' "$stop_time"
    sudo systemctl stop "$unit"
    printf 'service_active_after_stop=%s\n' "$(systemctl is-active "$unit" 2>/dev/null || true)"
    printf '%s\n' 'service_left_enabled=true'
    printf '%s\n' 'service_left_stopped_for_current_boot=true'
else
    printf '\n%s\n' '===== SERVICE ALREADY INACTIVE ====='
    stop_time=$(date --iso-8601=seconds)
    printf '%s\n' 'no_service_state_change=true'
fi

sleep "$observe_seconds"

printf '\n%s\n' '===== AFTER OBSERVATION ====='
crashes_after=$(crash_count)
printf 'adsp_crashes_after=%s\n' "$crashes_after"
if [ "$crashes_after" -ge "$crashes_before" ]; then
    printf 'new_adsp_crashes=%s\n' "$((crashes_after - crashes_before))"
else
    printf 'new_adsp_crashes=unknown-counter-reset\n'
fi
state_line
cat /proc/asound/cards 2>/dev/null || true

printf '\n%s\n' '===== KERNEL EVENTS AFTER SERVICE STOP ====='
sudo journalctl -k -b --since "$stop_time" --no-pager -o short-monotonic 2>/dev/null | \
    grep -Ei 'sensor_process|sns_registry|sns_secure|sns_rps|remoteproc0|audio_pd|charger_pd|qcom-apm|gprsvc|snd-x1e80100|soundwire' || true

printf '\n%s\n' '===== SERVICE LOG AROUND TEST ====='
sudo journalctl -b --since "$stop_time" -u "$unit" --no-pager -o short-monotonic 2>/dev/null || true

printf '\n%s\n' '===== RESULT ====='
if [ "$active_before" != active ]; then
    result=service-was-not-active
elif [ "$crashes_after" -eq "$crashes_before" ]; then
    result=no-new-adsp-crashes-after-rfs-stop
else
    result=adsp-still-crashing-after-rfs-stop
fi
printf 'result=%s\n' "$result"
printf 'report=%s\n' "$report"
printf '%s\n' 'firmware_changes=false'
printf '%s\n' 'module_reload=false'
printf '%s\n' 'remoteproc_manual_control=false'
printf '%s\n' 'service_disable=false'
printf '%s\n' 'restore_command=sudo systemctl start a14-ssc-hexagonrpcd.service'
