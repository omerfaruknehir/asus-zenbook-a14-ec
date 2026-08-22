#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Read-only ASUS Zenbook A14 WSA884x/VISENSE/SP-SPVI prerequisite audit.
set -euo pipefail

say() { printf '%s\n' "$*"; }
section() { printf '\n===== %s =====\n' "$*"; }

section 'SYSTEM'
printf 'kernel=%s\n' "$(uname -r)"
printf 'machine=%s\n' "$(uname -m)"
printf 'time=%s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"

section 'ALSA CARDS'
cat /proc/asound/cards 2>/dev/null || true

card=''
while read -r n rest; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    if grep -qiE 'X1E80100|Zenbook|A14' <<<"$rest"; then
        card="$n"
        break
    fi
done < <(sed 's/^ *//' /proc/asound/cards 2>/dev/null || true)

if [[ -z "$card" ]]; then
    # Fallback: use the first ALSA card whose long name mentions X1E80100/A14.
    for p in /sys/class/sound/card[0-9]*; do
        [[ -e "$p" ]] || continue
        n=${p##*card}
        name=$(cat "$p/id" 2>/dev/null || true)
        if grep -qiE 'X1E80100|Zenbook|A14' <<<"$name"; then
            card="$n"
            break
        fi
    done
fi

printf 'selected_card=%s\n' "${card:-NOT_FOUND}"

section 'PCM DEVICES'
cat /proc/asound/pcm 2>/dev/null || true
command -v aplay >/dev/null && aplay -l 2>/dev/null || true
command -v arecord >/dev/null && arecord -l 2>/dev/null || true

if [[ -n "$card" ]] && command -v amixer >/dev/null; then
    section 'WSA / VISENSE / SP MIXER CONTROLS'
    controls=$(amixer -c "$card" scontrols 2>/dev/null | \
        grep -Ei 'WSA|VISENSE|SPKR|VI|PA Volume' || true)
    printf '%s\n' "$controls"

    section 'SAFETY GAIN METADATA'
    for ctl in \
        'WSA WSA_RX0 Digital Volume' \
        'WSA WSA_RX1 Digital Volume' \
        'SpkrLeft PA Volume' \
        'SpkrRight PA Volume'; do
        echo "--- $ctl ---"
        amixer -c "$card" cget "name=$ctl" 2>/dev/null || echo 'not-present'
    done

    section 'VISENSE ROUTING STATE (READ ONLY)'
    for ctl in \
        'SpkrLeft VISENSE Switch' \
        'SpkrRight VISENSE Switch' \
        'WSA WSA_AIF_VI Mixer WSA_SPKR_VI_1' \
        'WSA WSA_AIF_VI Mixer WSA_SPKR_VI_2'; do
        echo "--- $ctl ---"
        amixer -c "$card" cget "name=$ctl" 2>/dev/null || echo 'not-present'
    done
else
    section 'MIXER AUDIT'
    echo 'Skipped: A14 ALSA card or amixer not available.'
fi

section 'WSA884x HWMON'
found=0
for h in /sys/class/hwmon/hwmon*; do
    [[ -r "$h/name" ]] || continue
    name=$(cat "$h/name" 2>/dev/null || true)
    [[ "$name" == wsa884x* ]] || continue
    found=1
    echo "--- $h ($name) ---"
    for f in "$h"/temp*_input "$h"/temp*_label "$h"/in*_input "$h"/curr*_input; do
        [[ -r "$f" ]] || continue
        printf '%s=%s\n' "$(basename "$f")" "$(cat "$f" 2>/dev/null || echo unreadable)"
    done
done
[[ "$found" -eq 1 ]] || echo 'No wsa884x hwmon devices found.'

section 'SOUNDWIRE DEVICES'
if [[ -d /sys/bus/soundwire/devices ]]; then
    for d in /sys/bus/soundwire/devices/*; do
        [[ -e "$d" ]] || continue
        echo "--- $(basename "$d") ---"
        for f in modalias dev_num status; do
            [[ -r "$d/$f" ]] && printf '%s=%s\n' "$f" "$(cat "$d/$f" 2>/dev/null || true)"
        done
        [[ -L "$d/driver" ]] && printf 'driver=%s\n' "$(basename "$(readlink -f "$d/driver")")"
        [[ -r "$d/power/runtime_status" ]] && printf 'runtime_status=%s\n' "$(cat "$d/power/runtime_status")"
    done
else
    echo '/sys/bus/soundwire/devices missing'
fi

section 'LOADED AUDIO MODULES'
lsmod 2>/dev/null | grep -Ei 'wsa884|soundwire|qcom.*sdw|lpass.*wsa|q6|gpr|apm|audio' || true

section 'DT / ASoC V1 MARKERS'
for p in /proc/device-tree/sound /proc/device-tree/*sound*; do
    [[ -e "$p" ]] || continue
    find "$p" -maxdepth 3 -type f -name 'link-name' -print0 2>/dev/null | \
        while IFS= read -r -d '' f; do
            v=$(tr -d '\000' < "$f" 2>/dev/null || true)
            printf '%s: %s\n' "$f" "$v"
        done
 done

section 'KERNEL LOG: WSA / SOUNDWIRE / AUDIoreach'
if dmesg >/dev/null 2>&1; then
    dmesg | grep -Ei 'wsa884|visense|speaker|spkr|soundwire|audio.?reach|q6apm|gpr|lpass|WSA VI' | tail -n 300 || true
else
    echo 'dmesg not readable as this user; rerun with sudo for kernel-log evidence.'
fi

section 'CLASSIFICATION'
if [[ -z "$card" ]]; then
    echo 'result=NO_A14_ALSA_CARD'
    exit 0
fi

left_vi=$(amixer -c "$card" cget "name=SpkrLeft VISENSE Switch" 2>/dev/null || true)
right_vi=$(amixer -c "$card" cget "name=SpkrRight VISENSE Switch" 2>/dev/null || true)
vi1=$(amixer -c "$card" cget "name=WSA WSA_AIF_VI Mixer WSA_SPKR_VI_1" 2>/dev/null || true)
vi2=$(amixer -c "$card" cget "name=WSA WSA_AIF_VI Mixer WSA_SPKR_VI_2" 2>/dev/null || true)

if [[ -n "$left_vi" && -n "$right_vi" && -n "$vi1" && -n "$vi2" ]]; then
    echo 'result=VISENSE_CONTROLS_PRESENT'
    echo 'next=transport-only live test; do not raise speaker gain'
else
    echo 'result=VISENSE_TRANSPORT_INCOMPLETE_OR_NOT_EXPOSED'
    echo 'next=V1 kernel transport patch remains prerequisite'
fi

echo 'safety=READ_ONLY_NO_MIXER_WRITES_NO_GAIN_CHANGES'
