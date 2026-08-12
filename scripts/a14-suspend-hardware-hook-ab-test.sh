#!/usr/bin/env bash
# One-cycle A/B test that excludes only the unowned A14 hardware-prep
# system-sleep hook. The hook file is never edited: /dev/null is bind-mounted
# over it temporarily and unmounted immediately after the suspend cycle.

set -u

report=${A14_HARDWARE_HOOK_AB_REPORT:-"$HOME/Downloads/a14-suspend-hardware-hook-ab-test.txt"}
hook=/usr/lib/systemd/system-sleep/85-a14-x1e-suspend-hardware
expected_sha256=01967e3601edf7dbecf193841084f736ee20767121d20abe0a9f17f13ec695d4
wait_iterations=${A14_HOOK_AB_WAIT_ITERATIONS:-300}
hook_hidden=false

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

suspend_success_count() {
    sudo awk '$1 == "success:" { print $2; found=1 } END { if (!found) print 0 }' \
        /sys/kernel/debug/suspend_stats 2>/dev/null
}

restore_hook() {
    if [ "$hook_hidden" = true ]; then
        if sudo mountpoint -q -- "$hook"; then
            sudo umount -- "$hook" || {
                printf 'CRITICAL: failed to unmount temporary hook mask: %s\n' "$hook" >&2
                return 1
            }
        fi
        hook_hidden=false
        printf 'hook_restored=true\n'
        sudo stat -Lc 'hook_after_restore: type=%F mode=%a owner=%U:%G' -- "$hook" 2>&1 || true
        sudo sha256sum -- "$hook" 2>&1 || true
    fi
}

cleanup() {
    restore_hook || true
}
trap cleanup EXIT HUP INT TERM

for tool in awk cat date dirname grep id journalctl mkdir mount mountpoint sed \
        sha256sum sleep stat sudo systemctl tee umount uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail 'run as your normal user, not with sudo'

mkdir -p -- "$(dirname "$report")"
sudo -v || fail 'sudo authentication failed; no state changed'
sudo test -f "$hook" || fail "target hook is missing: $hook"
sudo test -r /sys/kernel/debug/suspend_stats || fail 'debugfs suspend_stats is unavailable'

actual_sha256=$(sudo sha256sum -- "$hook" | awk '{print $1}')
[ "$actual_sha256" = "$expected_sha256" ] || \
    fail "target hook hash changed: expected $expected_sha256 got $actual_sha256"
sudo mountpoint -q -- "$hook" && fail "target hook is already a mount point: $hook"

exec > >(tee "$report") 2>&1

printf '%s\n' 'A14 suspend A/B: hardware-prep hook excluded'
printf '%s\n' '================================================'
printf 'timestamp=%s\n' "$(date --iso-8601=ns)"
printf 'kernel=%s\n' "$(uname -r)"
printf 'boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id)"
printf 'target_hook=%s\n' "$hook"
printf 'target_sha256=%s\n' "$actual_sha256"
printf '%s\n' 'hook_file_edited=false'
printf '%s\n' 'temporary_bind_mount_source=/dev/null'
printf '%s\n' 'firmware_changes=false'
printf '%s\n' 'module_reload=false'
printf '%s\n' 'remoteproc_manual_control=false'
printf '%s\n' 'service_disable=false'
printf '%s\n' 'state_changes_performed=temporary-hook-bind-mask-and-suspend'

printf '\n===== TARGET BEFORE MASK =====\n'
sudo stat -Lc 'type=%F mode=%a owner=%U:%G size=%s' -- "$hook"
sudo sha256sum -- "$hook"

success_before=$(suspend_success_count)
test_start=$(date --iso-8601=seconds)

sudo mount --bind /dev/null "$hook" || fail 'temporary hook bind mount failed'
hook_hidden=true
sudo mountpoint -q -- "$hook" || fail 'temporary hook bind mount was not established'
sudo test ! -x "$hook" || fail 'masked hook is unexpectedly executable'

printf '\n===== TARGET WHILE MASKED =====\n'
sudo stat -Lc 'type=%F mode=%a owner=%U:%G size=%s' -- "$hook"
printf '%s\n' 'hook_temporarily_hidden=true'

printf '\nSave other work. The machine should remain asleep until you wake it manually.\n'
printf '%s\n' 'Do not touch the keyboard, touchpad, lid, mouse, or power button after pressing Enter.'
read -r -p 'Press Enter to suspend, or Ctrl-C to cancel: '

printf 'suspend_request=%s\n' "$(date --iso-8601=ns)"
sudo systemctl suspend
printf 'systemctl_command_return=%s\n' "$(date --iso-8601=ns)"

completed=false
success_after=$success_before
i=0
while [ "$i" -lt "$wait_iterations" ]; do
    success_after=$(suspend_success_count)
    if [ "$success_after" -gt "$success_before" ]; then
        completed=true
        break
    fi
    i=$((i + 1))
    sleep 0.2
done

printf 'suspend_completion_observed=%s\n' "$(date --iso-8601=ns)"
printf 'suspend_success_before=%s\n' "$success_before"
printf 'suspend_success_after=%s\n' "$success_after"
printf 'suspend_completed=%s\n' "$completed"

restore_hook || fail 'target hook could not be restored'

printf '\n===== KERNEL EVENTS DURING TEST =====\n'
sudo journalctl -k -b --since "$test_start" --no-pager 2>/dev/null || true

printf '\n===== SLEEP-SERVICE EVENTS DURING TEST =====\n'
sudo journalctl -b --since "$test_start" --no-pager \
    -u systemd-suspend.service 2>/dev/null || true

printf '\n===== WAKEUP SOURCES AFTER TEST =====\n'
sudo cat /sys/kernel/debug/wakeup_sources 2>&1 || true

printf '\n===== RESULT =====\n'
if [ "$completed" = true ]; then
    printf '%s\n' 'result=suspend-cycle-completed-with-hardware-prep-hook-excluded'
    printf '%s\n' 'interpretation=manual-versus-spontaneous-wake-requires-user-observation'
else
    printf '%s\n' 'result=suspend-completion-not-observed'
fi
printf 'report=%s\n' "$report"
