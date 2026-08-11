#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Read-only diagnostic for ASUS Zenbook A14 X1E80100 ADSP firmware/config source.
set -Eeuo pipefail

release=${A14_KERNEL_RELEASE:-$(uname -r)}
report=${A14_ADSP_FW_DIAG_REPORT:-"$HOME/Downloads/a14-adsp-firmware-diag.txt"}
rel="qcom/x1e80100/ASUSTeK/zenbook-a14"
base="/usr/lib/firmware/$rel"
updates="/usr/lib/firmware/updates/$rel"
initrd="/boot/initrd.img-$release"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for tool in cat date dpkg grep journalctl ls readlink sha256sum stat sudo uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run as your normal user, not with sudo"
sudo -v

exec > >(tee "$report") 2>&1
printf '%s\n' 'A14 ADSP firmware-source diagnostic'
printf '%s\n' '=================================='
printf 'timestamp=%s\n' "$(date --iso-8601=ns)"
printf 'kernel=%s\n' "$release"
printf 'cmdline=%s\n' "$(cat /proc/cmdline)"
printf '%s\n' 'state_changes_performed=false'
printf '%s\n' 'firmware_changes=false'
printf '%s\n' 'remoteproc_changes=false'

printf '\n%s\n' '===== FIRMWARE LOADER SEARCH PATH ====='
printf 'firmware_class.path=%s\n' "$(cat /sys/module/firmware_class/parameters/path 2>/dev/null || true)"
printf '%s\n' 'kernel_default_priority=/lib/firmware/updates[/UTS_RELEASE] before /lib/firmware'

printf '\n%s\n' '===== REMOTEPROC CURRENT STATE ====='
for d in /sys/class/remoteproc/remoteproc*; do
    [ -d "$d" ] || continue
    printf '%s name=%s state=%s firmware=%s recovery=%s\n' \
        "${d##*/}" \
        "$(cat "$d/name" 2>/dev/null || true)" \
        "$(cat "$d/state" 2>/dev/null || true)" \
        "$(cat "$d/firmware" 2>/dev/null || true)" \
        "$(cat "$d/recovery" 2>/dev/null || true)"
done

printf '\n%s\n' '===== BASE VS UPDATES ASUS FIRMWARE ====='
files=(
    qcadsp8380.mbn
    adsp_dtbs.elf
    adspr.jsn
    adsps.jsn
    adspua.jsn
    qccdsp8380.mbn
    cdsp_dtbs.elf
    cdspr.jsn
    battmgr.jsn
)
for name in "${files[@]}"; do
    printf '\n--- %s ---\n' "$name"
    for root in "$updates" "$base"; do
        p="$root/$name"
        if [ -L "$p" ]; then
            printf 'path=%s type=symlink target=%s\n' "$p" "$(readlink -f "$p" 2>/dev/null || readlink "$p")"
        fi
        if [ -f "$p" ]; then
            stat -c 'path=%n size=%s mtime=%y inode=%i' "$p"
            sha256sum "$p"
            owner=$(dpkg -S "$p" 2>/dev/null || true)
            [ -n "$owner" ] && printf 'dpkg_owner=%s\n' "$owner" || printf 'dpkg_owner=none\n'
        else
            printf 'missing=%s\n' "$p"
        fi
    done
    if [ -f "$updates/$name" ] && [ -f "$base/$name" ]; then
        u=$(sha256sum "$updates/$name" | awk '{print $1}')
        b=$(sha256sum "$base/$name" | awk '{print $1}')
        if [ "$u" = "$b" ]; then
            printf 'comparison=identical\n'
        else
            printf 'comparison=DIFFERENT\n'
        fi
    fi
done

printf '\n%s\n' '===== DIRECTORY OWNERSHIP / MTIME ====='
for root in "$updates" "$base"; do
    if [ -d "$root" ]; then
        stat -c 'directory=%n mtime=%y' "$root"
        ls -la --time-style=full-iso "$root"
    else
        printf 'missing_directory=%s\n' "$root"
    fi
done

printf '\n%s\n' '===== INITRAMFS ASUS ADSP CONTENT ====='
if [ -f "$initrd" ] && command -v lsinitramfs >/dev/null 2>&1; then
    lsinitramfs "$initrd" 2>/dev/null | \
        grep -E '(^|/)(firmware/)?(updates/)?qcom/x1e80100/ASUSTeK/zenbook-a14/(qcadsp8380\.mbn|adsp_dtbs\.elf|adspr\.jsn|adsps\.jsn|adspua\.jsn|qccdsp8380\.mbn|cdsp_dtbs\.elf|cdspr\.jsn|battmgr\.jsn)$' || true
else
    printf 'initramfs_check=unavailable initrd=%s\n' "$initrd"
fi

printf '\n%s\n' '===== BOOT ADSP / SENSOR-REGISTRY / AUDIO FAILURE ====='
sudo journalctl -k -b --no-pager -o short-monotonic | \
    grep -Ei 'remoteproc0|remoteproc1|qcom_q6v5_pas|sns_registry|sns_secure|sns_rps|audio_pd|charger_pd|qcom-apm|gprsvc|snd-x1e80100|soundwire|lpass.*pinctrl|Failed to get clk .core.|fatal error received' || true

printf '\n%s\n' '===== RESULT ====='
printf 'report=%s\n' "$report"
printf '%s\n' 'state_changes_performed=false'
printf '%s\n' 'firmware_changes=false'
