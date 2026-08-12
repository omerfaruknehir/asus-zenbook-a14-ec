#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Read-only diagnostic that distinguishes an A14 ADSP / FastRPC reverse-fs
# boot-order race from a crash correlated with reverse-fs attachment.
set -Eeuo pipefail

unit=a14-ssc-hexagonrpcd.service
release=${A14_KERNEL_RELEASE:-$(uname -r)}
initrd=${A14_INITRD:-"/boot/initrd.img-$release"}
report=${A14_ADSP_BOOT_ORDER_REPORT:-"$HOME/Downloads/a14-adsp-boot-order-diag.txt"}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for tool in awk cat date grep id journalctl mktemp modinfo readlink rm sudo systemctl tail tee uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run as your normal user, not with sudo"

sudo -v
boot_log=$(mktemp --tmpdir a14-adsp-boot-order.XXXXXX)
trap 'rm -f -- "$boot_log"' EXIT
sudo journalctl -b --no-pager -o short-monotonic > "$boot_log"

exec > >(tee "$report") 2>&1
printf '%s\n' 'A14 ADSP / FastRPC boot-order diagnostic'
printf '%s\n' '========================================'
printf 'timestamp=%s\n' "$(date --iso-8601=ns)"
printf 'kernel=%s\n' "$release"
printf 'cmdline=%s\n' "$(cat /proc/cmdline)"
printf 'initrd=%s\n' "$initrd"
printf '%s\n' 'state_changes_performed=false'
printf '%s\n' 'module_reload=false'
printf '%s\n' 'remoteproc_changes=false'
printf '%s\n' 'firmware_changes=false'
printf '%s\n' 'initramfs_changes=false'

printf '\n%s\n' '===== KERNEL CONFIG / MODULE SOURCE ====='
config=/boot/config-$release
if [ -r "$config" ]; then
    grep -E '^CONFIG_(QCOM_FASTRPC|QCOM_Q6V5_PAS|RPMSG|QCOM_GLINK_SMEM)=' "$config" || true
else
    printf 'kernel_config=unavailable path=%s\n' "$config"
fi
for module in fastrpc qcom_q6v5_pas; do
    printf '%s_filename=%s\n' "$module" "$(modinfo -k "$release" -F filename "$module" 2>/dev/null || printf unavailable)"
    if grep -q -E "^${module}[[:space:]]" /proc/modules; then
        printf '%s_loaded=true\n' "$module"
    else
        printf '%s_loaded=false-or-built-in\n' "$module"
    fi
done

printf '\n%s\n' '===== INITRAMFS MODULE CONTENT ====='
if [ -r "$initrd" ] && command -v lsinitramfs >/dev/null 2>&1; then
    initrd_modules=$(lsinitramfs "$initrd" 2>/dev/null | \
        grep -E '/(fastrpc|qcom_q6v5_pas)\.ko(\.(xz|zst|gz))?$' || true)
    if [ -n "$initrd_modules" ]; then
        printf '%s\n' "$initrd_modules"
    else
        printf '%s\n' 'matching_modules=none'
    fi
    if printf '%s\n' "$initrd_modules" | grep -q -E '/fastrpc\.ko(\.(xz|zst|gz))?$'; then
        fastrpc_initrd=present
    else
        fastrpc_initrd=absent
    fi
    if printf '%s\n' "$initrd_modules" | grep -q -E '/qcom_q6v5_pas\.ko(\.(xz|zst|gz))?$'; then
        pas_initrd=present
    else
        pas_initrd=absent
    fi
else
    fastrpc_initrd=unknown
    pas_initrd=unknown
    printf 'initramfs_check=unavailable path=%s\n' "$initrd"
fi
printf 'fastrpc_initramfs=%s\n' "$fastrpc_initrd"
printf 'qcom_q6v5_pas_initramfs=%s\n' "$pas_initrd"

printf '\n%s\n' '===== REVERSE-FS UNIT ====='
printf 'service_enabled=%s\n' "$(systemctl is-enabled "$unit" 2>/dev/null || true)"
printf 'service_active=%s\n' "$(systemctl is-active "$unit" 2>/dev/null || true)"
sudo systemctl cat "$unit" 2>&1 || true
systemctl show "$unit" --no-pager \
    -p Type -p Restart -p RestartUSec -p After -p Before -p Wants -p Requires \
    -p ActiveEnterTimestampMonotonic -p InactiveEnterTimestampMonotonic 2>&1 || true

printf '\n%s\n' '===== CURRENT REMOTEPROC / FASTRPC STATE ====='
rp=/sys/class/remoteproc/remoteproc0
if [ -d "$rp" ]; then
    printf 'remoteproc0_name=%s\n' "$(cat "$rp/name" 2>/dev/null || printf unavailable)"
    printf 'remoteproc0_state=%s\n' "$(cat "$rp/state" 2>/dev/null || printf unavailable)"
    printf 'remoteproc0_firmware=%s\n' "$(cat "$rp/firmware" 2>/dev/null || printf unavailable)"
else
    printf '%s\n' 'remoteproc0=missing'
fi
for dev in /dev/fastrpc-adsp /dev/fastrpc-cdsp; do
    if [ -e "$dev" ]; then
        printf 'device=%s target=%s\n' "$dev" "$(readlink -f "$dev" 2>/dev/null || printf present)"
    else
        printf 'missing_device=%s\n' "$dev"
    fi
done

first_event_line() {
    grep -m1 -E "$1" "$boot_log" || true
}

last_event_line() {
    grep -E "$1" "$boot_log" | tail -n 1 || true
}

line_seconds() {
    local line prefix
    line=$1
    [ -n "$line" ] || return 0
    prefix=${line%%]*}
    prefix=${prefix#*[}
    printf '%s' "${prefix//[[:space:]]/}"
}

event_seconds() {
    line_seconds "$(first_event_line "$1")"
}

last_event_seconds() {
    line_seconds "$(last_event_line "$1")"
}

event_count() {
    grep -Ec "$1" "$boot_log" || true
}

delta_seconds() {
    awk -v start="$1" -v end="$2" 'BEGIN { printf "%.3f", end - start }'
}

adsp_up=$(event_seconds 'remoteproc remoteproc0: remote processor adsp is now up')
fastrpc_probe=$(event_seconds 'qcom,fastrpc 6800000\.remoteproc.*no reserved DMA memory for FASTRPC')
service_first=$(event_seconds '(Starting|Started) a14-ssc-hexagonrpcd\.service|hexagonrpcd-a14\[')
secure_crash=$(event_seconds 'sns_secure\.c(:[0-9]+)?:[0-9]+|sns_secure\.c')
last_adsp_up=$(last_event_seconds 'remoteproc remoteproc0: remote processor adsp is now up')
last_adsp_crash=$(last_event_seconds 'remoteproc remoteproc0: handling crash #[0-9]+ in adsp')
last_service_start=$(last_event_seconds 'Started a14-ssc-hexagonrpcd\.service')
adsp_crash_count=$(event_count 'remoteproc remoteproc0: handling crash #[0-9]+ in adsp')
rfs_start_count=$(event_count 'Started a14-ssc-hexagonrpcd\.service')
rfs_attach_failure_count=$(event_count 'Could not attach to FastRPC node')
rfs_broken_pipe_count=$(event_count 'Could not fetch next FastRPC message: Broken pipe')

printf '\n%s\n' '===== DERIVED FIRST-BOOT TIMING ====='
printf 'adsp_first_up_seconds=%s\n' "${adsp_up:-unavailable}"
printf 'fastrpc_first_probe_seconds=%s\n' "${fastrpc_probe:-unavailable}"
printf 'reverse_fs_first_event_seconds=%s\n' "${service_first:-unavailable}"
printf 'sns_secure_first_crash_seconds=%s\n' "${secure_crash:-unavailable}"
if [ -n "$adsp_up" ] && [ -n "$fastrpc_probe" ]; then
    adsp_to_fastrpc=$(delta_seconds "$adsp_up" "$fastrpc_probe")
    printf 'adsp_to_fastrpc_seconds=%s\n' "$adsp_to_fastrpc"
else
    adsp_to_fastrpc=
fi
if [ -n "$fastrpc_probe" ] && [ -n "$secure_crash" ]; then
    fastrpc_to_crash=$(delta_seconds "$fastrpc_probe" "$secure_crash")
    printf 'fastrpc_to_sns_secure_crash_seconds=%s\n' "$fastrpc_to_crash"
else
    fastrpc_to_crash=
fi
if [ -n "$adsp_up" ] && [ -n "$secure_crash" ]; then
    printf 'adsp_to_sns_secure_crash_seconds=%s\n' "$(delta_seconds "$adsp_up" "$secure_crash")"
fi

printf '\n%s\n' '===== FULL-BOOT CORRELATION ====='
printf 'adsp_crash_count=%s\n' "$adsp_crash_count"
printf 'reverse_fs_start_count=%s\n' "$rfs_start_count"
printf 'reverse_fs_attach_failure_count=%s\n' "$rfs_attach_failure_count"
printf 'reverse_fs_broken_pipe_count=%s\n' "$rfs_broken_pipe_count"
printf 'last_adsp_crash_seconds=%s\n' "${last_adsp_crash:-unavailable}"
printf 'last_adsp_up_seconds=%s\n' "${last_adsp_up:-unavailable}"
printf 'last_reverse_fs_start_seconds=%s\n' "${last_service_start:-unavailable}"

if [ "$adsp_crash_count" -gt 0 ] && \
        [ "$rfs_broken_pipe_count" -eq "$adsp_crash_count" ]; then
    rfs_crash_correlation=one-broken-pipe-session-per-adsp-crash
else
    rfs_crash_correlation=no-one-to-one-count-match
fi
printf 'reverse_fs_crash_correlation=%s\n' "$rfs_crash_correlation"

if [ -n "$last_adsp_crash" ] && [ -n "$last_adsp_up" ] && \
        [ -n "$last_service_start" ] && \
        awk -v crash="$last_adsp_crash" -v up="$last_adsp_up" -v rfs="$last_service_start" \
            'BEGIN { exit !(up > crash && rfs < up) }'; then
    recovery_tail=adsp-recovered-without-later-reverse-fs-start
else
    recovery_tail=no-unserved-recovery-tail-observed
fi
printf 'recovery_tail=%s\n' "$recovery_tail"

printf '\n%s\n' '===== RELEVANT BOOT EVENTS ====='
grep -E \
    'remoteproc0: (adsp is available|powering up adsp|Booting fw image|remote processor adsp is now up|handling crash)|qcom,fastrpc 6800000\.remoteproc|sns_registry|sns_secure|sns_rps|a14-ssc-hexagonrpcd|hexagonrpcd-a14' \
    "$boot_log" || true

printf '\n%s\n' '===== RESULT ====='
if [ "$pas_initrd" = present ] && [ "$fastrpc_initrd" = absent ]; then
    printf '%s\n' 'initramfs_ordering=remoteproc-present-fastrpc-absent'
else
    printf 'initramfs_ordering=pas-%s-fastrpc-%s\n' "$pas_initrd" "$fastrpc_initrd"
fi
if [ "$rfs_crash_correlation" = one-broken-pipe-session-per-adsp-crash ] && \
        [ "$recovery_tail" = adsp-recovered-without-later-reverse-fs-start ]; then
    printf '%s\n' 'timing_result=reverse-fs-session-correlates-with-each-crash;do-not-apply-initramfs-ordering-fix'
elif [ -n "$adsp_to_fastrpc" ] && [ -n "$fastrpc_to_crash" ] && \
        awk -v a="$adsp_to_fastrpc" -v b="$fastrpc_to_crash" 'BEGIN { exit !(a >= 5 && b >= 0 && b < 1) }'; then
    printf '%s\n' 'timing_result=fastrpc-arrived-near-sns-secure-timeout'
else
    printf '%s\n' 'timing_result=no-specific-boot-order-signature'
fi
printf 'report=%s\n' "$report"
printf '%s\n' 'state_changes_performed=false'
