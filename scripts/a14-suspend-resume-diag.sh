#!/usr/bin/env bash
# One-cycle suspend/resume regression check for the Zenbook A14 audio, ADSP,
# SoundWire and camera paths. The script changes no driver, firmware, service,
# module or remoteproc state; the only state transition it requests is suspend.

set -u

report=${A14_SUSPEND_DIAG_REPORT:-"$HOME/Downloads/a14-suspend-resume-diag.txt"}
settle_seconds=${A14_SUSPEND_SETTLE_SECONDS:-10}
tmpdir=$(mktemp -d)
start_time=$(date --iso-8601=seconds)

cleanup() {
    rm -rf -- "$tmpdir"
}
trap cleanup EXIT

remoteproc_snapshot() {
    local r name state firmware

    for r in /sys/class/remoteproc/remoteproc*; do
        [ -d "$r" ] || continue
        name=$(cat "$r/name" 2>/dev/null || printf unknown)
        state=$(cat "$r/state" 2>/dev/null || printf unknown)
        firmware=$(cat "$r/firmware" 2>/dev/null || printf unknown)
        printf '%s name=%s state=%s firmware=%s\n' \
            "$(basename "$r")" "$name" "$state" "$firmware"
    done
}

adsp_state() {
    local r

    for r in /sys/class/remoteproc/remoteproc*; do
        [ -d "$r" ] || continue
        if [ "$(cat "$r/name" 2>/dev/null || true)" = adsp ]; then
            cat "$r/state" 2>/dev/null || printf unknown
            return
        fi
    done
    printf missing
}

adsp_crash_count() {
    sudo journalctl -k -b --no-pager 2>/dev/null | grep -Eic \
        'sns_secure\.c:578|remoteproc[^:]*:.*(adsp.*crash|fatal)|q6v5.*(crash|fatal)|adsp.*(fatal|crash)'
}

audio_card_present() {
    grep -q 'X1E80100-ASUS-Zenbook-A14' /proc/asound/cards 2>/dev/null
}

pcm_count() {
    find /sys/class/sound -maxdepth 1 -type l -name 'pcmC*' 2>/dev/null | wc -l
}

soundwire_device_count() {
    find /sys/bus/soundwire/devices -mindepth 1 -maxdepth 1 -type l \
        -name 'sdw:*' 2>/dev/null | wc -l
}

camera_snapshot() {
    local output=$1

    if ! command -v cam >/dev/null 2>&1; then
        printf '%s\n' 'cam_command=missing' | tee "$output"
        return 2
    fi

    timeout 25 cam -l 2>&1 | tee "$output"
}

full_snapshot() {
    local label=$1 camera_output=$2

    printf '\n===== %s: REMOTEPROC =====\n' "$label"
    remoteproc_snapshot
    printf '\n===== %s: ALSA =====\n' "$label"
    cat /proc/asound/cards 2>/dev/null || true
    aplay -l 2>&1 || true
    arecord -l 2>&1 || true
    printf '\n===== %s: SOUNDWIRE =====\n' "$label"
    find /sys/bus/soundwire/devices -mindepth 1 -maxdepth 1 \
        -printf '%f\n' 2>/dev/null | sort || true
    printf '\n===== %s: PIPEWIRE =====\n' "$label"
    wpctl status 2>&1 || true
    printf '\n===== %s: CAMERA ENUMERATION =====\n' "$label"
    camera_snapshot "$camera_output" || true
}

mkdir -p -- "$(dirname "$report")"

sudo -v || {
    printf '%s\n' 'sudo authentication failed; no suspend requested' >&2
    exit 1
}

exec > >(tee "$report") 2>&1

printf '%s\n' 'A14 suspend/resume audio, ADSP, SoundWire and camera diagnostic'
printf '%s\n' '================================================================'
printf 'timestamp=%s\n' "$(date --iso-8601=ns)"
printf 'kernel=%s\n' "$(uname -r)"
printf 'boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id)"
printf 'settle_seconds=%s\n' "$settle_seconds"
printf '%s\n' 'state_changes_performed=suspend-only'
printf '%s\n' 'firmware_changes=false'
printf '%s\n' 'module_reload=false'
printf '%s\n' 'remoteproc_manual_control=false'
printf '%s\n' 'service_changes=false'

crashes_before=$(adsp_crash_count)
adsp_before=$(adsp_state)
pcm_before=$(pcm_count)
soundwire_before=$(soundwire_device_count)
if audio_card_present; then audio_before=present; else audio_before=missing; fi

full_snapshot BEFORE "$tmpdir/camera-before.txt"

printf '\n===== BASELINE SUMMARY =====\n'
printf 'adsp_state_before=%s\n' "$adsp_before"
printf 'adsp_crashes_before=%s\n' "$crashes_before"
printf 'audio_card_before=%s\n' "$audio_before"
printf 'pcm_endpoints_before=%s\n' "$pcm_before"
printf 'soundwire_devices_before=%s\n' "$soundwire_before"

printf '\nThe machine will suspend once. Save other work first.\n'
printf 'Resume it normally, then leave this terminal open for %s seconds.\n' "$settle_seconds"
read -r -p 'Press Enter to suspend, or Ctrl-C to cancel: '

suspend_request=$(date --iso-8601=ns)
printf 'suspend_request=%s\n' "$suspend_request"
sudo systemctl suspend
resume_return=$(date --iso-8601=ns)
printf 'resume_return=%s\n' "$resume_return"
printf 'waiting_for_userspace_seconds=%s\n' "$settle_seconds"
sleep "$settle_seconds"

crashes_after=$(adsp_crash_count)
adsp_after=$(adsp_state)
pcm_after=$(pcm_count)
soundwire_after=$(soundwire_device_count)
if audio_card_present; then audio_after=present; else audio_after=missing; fi

full_snapshot AFTER "$tmpdir/camera-after.txt"

printf '\n===== EVENTS SINCE TEST START =====\n'
sudo journalctl -k -b --since "$start_time" --no-pager 2>/dev/null | \
    grep -Ei 'PM: suspend|PM: resume|suspend entry|suspend exit|remoteproc|adsp|q6|apr|gpr|ASoC|snd|audio|soundwire|wcd|wsa|camss|cci|camera|ov02c10|hm1092|iris|crash|fatal|timeout|fail|error' || true

new_crashes=$((crashes_after - crashes_before))
camera_before_ok=false
camera_after_ok=false
grep -Eq '^[[:space:]]*[0-9]+:' "$tmpdir/camera-before.txt" 2>/dev/null && camera_before_ok=true
grep -Eq '^[[:space:]]*[0-9]+:' "$tmpdir/camera-after.txt" 2>/dev/null && camera_after_ok=true

result=pass
if [ "$adsp_after" != running ] || [ "$new_crashes" -ne 0 ] || \
   [ "$audio_after" != present ] || [ "$pcm_after" -lt "$pcm_before" ] || \
   [ "$soundwire_after" -lt "$soundwire_before" ] || \
   { [ "$camera_before_ok" = true ] && [ "$camera_after_ok" != true ]; }; then
    result=regression-detected
fi

printf '\n===== RESULT =====\n'
printf 'adsp_state_before=%s\n' "$adsp_before"
printf 'adsp_state_after=%s\n' "$adsp_after"
printf 'adsp_crashes_before=%s\n' "$crashes_before"
printf 'adsp_crashes_after=%s\n' "$crashes_after"
printf 'new_adsp_crashes=%s\n' "$new_crashes"
printf 'audio_card_before=%s\n' "$audio_before"
printf 'audio_card_after=%s\n' "$audio_after"
printf 'pcm_endpoints_before=%s\n' "$pcm_before"
printf 'pcm_endpoints_after=%s\n' "$pcm_after"
printf 'soundwire_devices_before=%s\n' "$soundwire_before"
printf 'soundwire_devices_after=%s\n' "$soundwire_after"
printf 'camera_enumeration_before=%s\n' "$camera_before_ok"
printf 'camera_enumeration_after=%s\n' "$camera_after_ok"
printf 'result=%s\n' "$result"
printf 'report=%s\n' "$report"

printf '\nAutomatic checks do not prove that samples flow. If result=pass, run:\n'
printf '%s\n' '  speaker-test -c 2 -t wav -l 1'
printf '%s\n' '  arecord -D default -f S16_LE -r 48000 -c 2 -d 5 /tmp/a14-mic-after-resume.wav'
printf '%s\n' '  aplay /tmp/a14-mic-after-resume.wav'
