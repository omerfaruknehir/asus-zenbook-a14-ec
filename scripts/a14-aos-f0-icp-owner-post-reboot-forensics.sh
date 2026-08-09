#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Read-only post-reboot forensics for a Stage C ICP-owner attempt.
# This script never accesses the Stage C probe or changes camera/clock state.
set -Eeuo pipefail

marker=${A14_AOS_F0_ICP_OWNER_MARKER:-"$HOME/Downloads/a14-aos-f0-icp-owner-last-run.txt"}
out=${A14_AOS_F0_ICP_OWNER_FORENSICS:-"$HOME/Downloads/a14-aos-f0-icp-owner-post-reboot-forensics.txt"}
prev_klog=${A14_AOS_F0_ICP_OWNER_PREV_KLOG:-"$HOME/Downloads/a14-aos-f0-icp-owner-previous-boot-kernel.log"}
prev_journal=${A14_AOS_F0_ICP_OWNER_PREV_JOURNAL:-"$HOME/Downloads/a14-aos-f0-icp-owner-previous-boot-journal.log"}
pstore_out=${A14_AOS_F0_ICP_OWNER_PSTORE:-"$HOME/Downloads/a14-aos-f0-icp-owner-pstore.txt"}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for tool in cat grep journalctl sed sudo tee; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this collector as your normal user, not with sudo"
[ -s "$marker" ] || fail "persistent Stage C marker is missing: $marker"
grep -Fqx 'operation=platform-power-f0-icp-real-owners-no-mmio-v1' "$marker" || \
    fail "persistent marker is not a Stage C owner attempt"

marker_boot_id=$(sed -n 's/^boot_id=//p' "$marker" | head -n 1)
marker_status=$(sed -n 's/^status=//p' "$marker" | head -n 1)
marker_started=$(sed -n 's/^started=//p' "$marker" | head -n 1)
[ -n "$marker_boot_id" ] || fail "marker has no boot_id"
current_boot_id=$(cat /proc/sys/kernel/random/boot_id)

printf '%s\n' 'A14 Stage C post-reboot forensics'
printf '%s\n' '================================='
printf '%s\n' 'operation=read-only-forensics'
printf '%s\n' 'hardware_probe_write=false'
printf '%s\n' 'camera_state_change=false'
printf '%s\n' 'clock_state_change=false'
printf 'marker_boot_id=%s\n' "$marker_boot_id"
printf 'current_boot_id=%s\n' "$current_boot_id"
printf 'marker_status=%s\n' "${marker_status:-missing}"
printf 'marker_started=%s\n' "${marker_started:-missing}"
if [ "$marker_boot_id" = "$current_boot_id" ]; then
    fail "marker belongs to current boot; this collector is only for a completed/rebooted boot"
fi

printf '\n%s\n' '===== AVAILABLE BOOTS ====='
sudo journalctl --list-boots --no-pager || true

printf '\n%s\n' '===== READ MARKER BOOT ====='
# Use the exact boot ID recorded before the Stage C write rather than assuming -1.
set +e
sudo journalctl -k -b "$marker_boot_id" --no-pager -o short-monotonic > "$prev_klog"
krc=$?
sudo journalctl -b "$marker_boot_id" --no-pager -o short-monotonic > "$prev_journal"
jrc=$?
set -e
[ "$krc" -eq 0 ] || fail "kernel journal for marker boot $marker_boot_id is unavailable"
[ "$jrc" -eq 0 ] || fail "full journal for marker boot $marker_boot_id is unavailable"
[ -s "$prev_klog" ] || fail "marker-boot kernel journal is empty"
[ -s "$prev_journal" ] || fail "marker-boot full journal is empty"
printf '%s\n' 'marker_boot_journal=available'

begin_count=$(grep -Fc 'AON-F0-ICP-OWNER-DIAG begin direct-mmio=false ssc=false' "$prev_klog" || true)
targets_count=$(grep -Fc 'AON-F0-ICP-OWNER-DIAG targets-ok hold-ms=250' "$prev_klog" || true)
icp_restore_count=$(grep -Fc 'AON-F0-ICP-OWNER-DIAG icp-restore-ok' "$prev_klog" || true)
cci0_restore_count=$(grep -Fc 'AON-F0-ICP-OWNER-DIAG cci-put device=ac15000.cci ret=0' "$prev_klog" || true)
cci1_restore_count=$(grep -Fc 'AON-F0-ICP-OWNER-DIAG cci-put device=ac16000.cci ret=0' "$prev_klog" || true)
complete_ok_count=$(grep -Ec 'AON-F0-ICP-OWNER-DIAG complete ret=0 camnoc-limited=[01]' "$prev_klog" || true)
fault_count=$(grep -Eic 'watchdog|panic|SError|Call trace|Internal error|Oops|BUG:|Kernel panic' "$prev_klog" || true)
shutdown_count=$(grep -Eic 'systemd-shutdown|reboot: Restarting system|Power down|Reached target.*Reboot|Shutting down' "$prev_journal" || true)

printf '\n%s\n' '===== STAGE C COUNTS ====='
printf 'begin_count=%s\n' "$begin_count"
printf 'targets_ok_count=%s\n' "$targets_count"
printf 'icp_restore_ok_count=%s\n' "$icp_restore_count"
printf 'cci0_restore_ok_count=%s\n' "$cci0_restore_count"
printf 'cci1_restore_ok_count=%s\n' "$cci1_restore_count"
printf 'complete_ret0_count=%s\n' "$complete_ok_count"
printf 'kernel_fault_marker_count=%s\n' "$fault_count"
printf 'orderly_shutdown_marker_count=%s\n' "$shutdown_count"

printf '\n%s\n' '===== STAGE C KERNEL LINES ====='
grep -E 'AON-F0-ICP-OWNER-DIAG|A14 isolated F0 ICP owner diagnostic|watchdog|panic|SError|Call trace|Internal error|Oops|BUG:' "$prev_klog" || true

printf '\n%s\n' '===== BOOT TERMINATION EVIDENCE ====='
grep -Ei 'systemd-shutdown|reboot: Restarting system|Power down|Reached target.*Reboot|Shutting down|watchdog|panic|SError|Call trace|Internal error|Oops|BUG:' "$prev_journal" | tail -n 120 || true

printf '\n%s\n' '===== PSTORE ====='
: > "$pstore_out"
if sudo test -d /sys/fs/pstore; then
    # Never remove pstore records; snapshot them only.
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        printf '%s\n' "--- $f ---" | tee -a "$pstore_out"
        sudo cat "$f" 2>/dev/null | tee -a "$pstore_out" || true
    done < <(sudo find /sys/fs/pstore -maxdepth 1 -type f -print 2>/dev/null)
fi
if [ -s "$pstore_out" ]; then
    printf '%s\n' 'pstore_records=present'
else
    printf '%s\n' 'pstore_records=none'
fi

classification=indeterminate
if [ "$complete_ok_count" -ge 1 ] && [ "$icp_restore_count" -ge 1 ] && \
   [ "$cci0_restore_count" -ge 1 ] && [ "$cci1_restore_count" -ge 1 ]; then
    classification=stage-c-kernel-cleanup-completed-before-reboot
elif [ "$targets_count" -ge 1 ] && [ "$complete_ok_count" -eq 0 ]; then
    classification=stage-c-target-hold-reached-without-recorded-cleanup-completion
elif [ "$begin_count" -ge 1 ] && [ "$targets_count" -eq 0 ]; then
    classification=stage-c-began-without-recorded-target-hold
fi

{
    printf '%s\n' 'A14 Stage C post-reboot forensic summary'
    printf 'marker_boot_id=%s\n' "$marker_boot_id"
    printf 'current_boot_id=%s\n' "$current_boot_id"
    printf 'marker_status=%s\n' "${marker_status:-missing}"
    printf 'marker_started=%s\n' "${marker_started:-missing}"
    printf 'begin_count=%s\n' "$begin_count"
    printf 'targets_ok_count=%s\n' "$targets_count"
    printf 'icp_restore_ok_count=%s\n' "$icp_restore_count"
    printf 'cci0_restore_ok_count=%s\n' "$cci0_restore_count"
    printf 'cci1_restore_ok_count=%s\n' "$cci1_restore_count"
    printf 'complete_ret0_count=%s\n' "$complete_ok_count"
    printf 'kernel_fault_marker_count=%s\n' "$fault_count"
    printf 'orderly_shutdown_marker_count=%s\n' "$shutdown_count"
    printf 'classification=%s\n' "$classification"
    printf 'previous_boot_kernel_log=%s\n' "$prev_klog"
    printf 'previous_boot_journal=%s\n' "$prev_journal"
    printf 'pstore=%s\n' "$pstore_out"
} > "$out"

printf '\n%s\n' '===== FORENSIC RESULT ====='
cat "$out"
printf '%s\n' 'No Stage C hardware action was performed.'
