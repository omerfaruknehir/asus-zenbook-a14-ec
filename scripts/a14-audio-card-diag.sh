#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Read-only diagnostic for missing X1E80100 ALSA/ASoC card registration.
set -Eeuo pipefail

report=${A14_AUDIO_DIAG_REPORT:-"$HOME/Downloads/a14-audio-card-diag.txt"}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for tool in cat date find grep journalctl ls lsmod readlink sudo uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run as your normal user, not with sudo"

sudo -v
exec > >(tee "$report") 2>&1

printf '%s\n' 'A14 X1E80100 audio-card diagnostic'
printf '%s\n' '================================='
printf 'timestamp=%s\n' "$(date --iso-8601=ns)"
printf 'kernel=%s\n' "$(uname -r)"
printf 'cmdline=%s\n' "$(cat /proc/cmdline)"
printf '%s\n' 'state_changes_performed=false'
printf '%s\n' 'module_reload=false'
printf '%s\n' 'remoteproc_changes=false'

printf '\n%s\n' '===== ALSA CORE VIEW ====='
cat /proc/asound/cards 2>/dev/null || true
ls -la /sys/class/sound 2>/dev/null || true

printf '\n%s\n' '===== AUDIO-RELATED MODULES ====='
lsmod | grep -Ei '^(snd|soundwire|q6|qcom.*(apm|audio|sound)|apr|gpr|wcd|lpass|pinctrl_lpass)' || true

printf '\n%s\n' '===== REMOTEPROC STATE ====='
for r in /sys/class/remoteproc/remoteproc*; do
    [ -d "$r" ] || continue
    printf '%s' "${r##*/}"
    for key in name state firmware recovery; do
        [ -r "$r/$key" ] || continue
        printf ' %s=%s' "$key" "$(cat "$r/$key" 2>/dev/null || printf '?')"
    done
    printf '\n'
done

printf '\n%s\n' '===== SOUND / ASoC PLATFORM DEVICES ====='
for d in /sys/bus/platform/devices/*; do
    [ -e "$d" ] || continue
    base=${d##*/}
    case "$base" in
        *sound*|*audio*|*adsp*|*lpass*|*gpr*|*apr*|*wcd*|*swr*|*soundwire*) ;;
        *) continue ;;
    esac
    printf '%s' "$base"
    [ -L "$d/driver" ] && printf ' driver=%s' "$(basename "$(readlink -f "$d/driver")")"
    [ -r "$d/modalias" ] && printf ' modalias=%s' "$(cat "$d/modalias" 2>/dev/null || true)"
    printf '\n'
done

printf '\n%s\n' '===== SOUNDWIRE BUS ====='
find /sys/bus/soundwire/devices -maxdepth 2 -type f \( -name status -o -name modalias -o -name name \) -print -exec cat {} \; 2>/dev/null || true
ls -la /sys/bus/soundwire/devices 2>/dev/null || true

printf '\n%s\n' '===== DEVICE-TREE SOUND NODE ====='
for n in /sys/firmware/devicetree/base/sound /sys/firmware/devicetree/base/*sound*; do
    [ -d "$n" ] || continue
    printf 'node=%s\n' "$n"
    for key in status compatible model audio-routing; do
        [ -r "$n/$key" ] || continue
        printf '%s=' "$key"
        tr '\0' '\n' < "$n/$key" 2>/dev/null || true
    done
    printf '\n'
done

printf '\n%s\n' '===== AUDIO FIRMWARE / TOPOLOGY FILES ====='
find /lib/firmware /usr/lib/firmware -type f 2>/dev/null | \
    grep -Ei 'x1e80100|zenbook.*a14|audioreach|adsp|\.tplg($|\.)' | sort -u | tail -200 || true

printf '\n%s\n' '===== BOOT KERNEL AUDIO LOG ====='
sudo journalctl -k -b --no-pager -o short-monotonic | \
    grep -Ei 'snd|ASoC|audio|audioreach|qcom[-_, ]?apm|q6|APR|GPR|ADSP|remoteproc|soundwire|swr|wcd|lpass|tplg|topolog|firmware.*(audio|adsp)|X1E80100.*sound|sound.*X1E80100' || true

printf '\n%s\n' '===== RESULT LOCATION ====='
printf 'report=%s\n' "$report"
printf '%s\n' 'state_changes_performed=false'
