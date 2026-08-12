#!/usr/bin/env bash
# Cumulative suspend A/B stage 3: exclude all installed A14-specific
# system-sleep hooks. Stop the Aegis and keyboard userspace services before
# masking the hooks so camera and HID work has settled before suspend.

set -u

report=${A14_KEYBOARD_HOOK_AB_REPORT:-"$HOME/Downloads/a14-suspend-keyboard-hook-ab-test.txt"}
hardware_hook=/usr/lib/systemd/system-sleep/85-a14-x1e-suspend-hardware
aegis_hook=/usr/lib/systemd/system-sleep/aegis-hello
keyboard_hook=/usr/lib/systemd/system-sleep/a14-kbd-leds
hardware_sha=01967e3601edf7dbecf193841084f736ee20767121d20abe0a9f17f13ec695d4
aegis_sha=19231d1dbc7d7d9402c95afe999c1360dfac970d1a0c6241c52e197b47de388b
keyboard_sha=d60782eac68afcbd202ccc7996f095eaca9d00f66d05f57e201cfc76d4f79797
wait_iterations=${A14_HOOK_AB_WAIT_ITERATIONS:-300}
masked_hooks=
aegis_was_active=false
keyboard_was_active=false

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

suspend_success_count() {
    sudo awk '$1 == "success:" { print $2; found=1 } END { if (!found) print 0 }' \
        /sys/kernel/debug/suspend_stats 2>/dev/null
}

mask_hook() {
    local hook=$1

    sudo mountpoint -q -- "$hook" && fail "hook is already a mount point: $hook"
    sudo mount --bind /dev/null "$hook" || fail "failed to mask hook: $hook"
    sudo mountpoint -q -- "$hook" || fail "hook mask was not established: $hook"
    sudo test ! -x "$hook" || fail "masked hook remains executable: $hook"
    masked_hooks="$hook $masked_hooks"
    printf 'hook_masked=%s\n' "$hook"
}

restore_state() {
    local hook

    for hook in $masked_hooks; do
        if sudo mountpoint -q -- "$hook"; then
            sudo umount -- "$hook" || {
                printf 'CRITICAL: failed to unmount hook mask: %s\n' "$hook" >&2
                continue
            }
        fi
        printf 'hook_restored=%s\n' "$hook"
    done
    masked_hooks=

    if [ "$keyboard_was_active" = true ]; then
        sudo systemctl start a14-kbd-userspace.service || true
        printf '%s\n' 'keyboard_service_restored=true'
        keyboard_was_active=false
    fi

    if [ "$aegis_was_active" = true ]; then
        sudo systemctl start aegis-hello.service || true
        printf '%s\n' 'aegis_service_restored=true'
        aegis_was_active=false
    fi
}

cleanup() {
    restore_state || true
}
trap cleanup EXIT HUP INT TERM

for tool in awk cat date dirname id journalctl mkdir mount mountpoint \
        sha256sum sleep stat sudo systemctl tee umount uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail 'run as your normal user, not with sudo'

mkdir -p -- "$(dirname "$report")"
sudo -v || fail 'sudo authentication failed; no state changed'
sudo test -r /sys/kernel/debug/suspend_stats || fail 'debugfs suspend_stats is unavailable'
sudo test ! -e /run/a14-kbd-sleeping || \
    fail '/run/a14-kbd-sleeping already exists; reboot or clear the stale keyboard sleep state first'

for item in \
        "$hardware_hook:$hardware_sha" \
        "$aegis_hook:$aegis_sha" \
        "$keyboard_hook:$keyboard_sha"; do
    hook=${item%%:*}
    expected=${item##*:}
    sudo test -f "$hook" || fail "target hook is missing: $hook"
    actual=$(sudo sha256sum -- "$hook" | awk '{print $1}')
    [ "$actual" = "$expected" ] || \
        fail "hook hash changed: $hook expected=$expected actual=$actual"
done

exec > >(tee "$report") 2>&1

printf '%s\n' 'A14 suspend A/B stage 3: all custom A14 sleep hooks excluded'
printf '%s\n' '==============================================================='
printf 'timestamp=%s\n' "$(date --iso-8601=ns)"
printf 'kernel=%s\n' "$(uname -r)"
printf 'boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id)"
printf '%s\n' 'hook_files_edited=false'
printf '%s\n' 'temporary_bind_mount_source=/dev/null'
printf '%s\n' 'firmware_changes=false'
printf '%s\n' 'module_reload=false'
printf '%s\n' 'remoteproc_manual_control=false'
printf '%s\n' 'service_disable=false'
printf '%s\n' 'state_changes_performed=temporary-hook-bind-masks-service-stops-and-suspend'

if sudo systemctl is-active --quiet aegis-hello.service; then
    aegis_was_active=true
    sudo systemctl stop aegis-hello.service || fail 'failed to stop Aegis Hello before test'
fi
printf 'aegis_was_active=%s\n' "$aegis_was_active"

if sudo systemctl is-active --quiet a14-kbd-userspace.service; then
    keyboard_was_active=true
    sudo systemctl stop a14-kbd-userspace.service || \
        fail 'failed to stop the A14 keyboard userspace service before test'
fi
printf 'keyboard_was_active=%s\n' "$keyboard_was_active"
printf '%s\n' 'service_settle_seconds=3'
sleep 3

mask_hook "$hardware_hook"
mask_hook "$aegis_hook"
mask_hook "$keyboard_hook"

printf '\n===== MASKED TARGETS =====\n'
sudo stat -Lc 'path=%n type=%F mode=%a owner=%U:%G' -- \
    "$hardware_hook" "$aegis_hook" "$keyboard_hook"

printf '\n===== SERVICES BEFORE SUSPEND =====\n'
printf 'aegis_active=%s\n' "$(sudo systemctl is-active aegis-hello.service 2>/dev/null || true)"
printf 'keyboard_active=%s\n' "$(sudo systemctl is-active a14-kbd-userspace.service 2>/dev/null || true)"

success_before=$(suspend_success_count)
test_start=$(date --iso-8601=seconds)

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

restore_state

printf '\n===== KERNEL EVENTS DURING TEST =====\n'
sudo journalctl -k -b --since "$test_start" --no-pager 2>/dev/null || true

printf '\n===== SLEEP-SERVICE EVENTS DURING TEST =====\n'
sudo journalctl -b --since "$test_start" --no-pager \
    -u systemd-suspend.service 2>/dev/null || true

printf '\n===== WAKEUP SOURCES AFTER TEST =====\n'
sudo cat /sys/kernel/debug/wakeup_sources 2>&1 || true

printf '\n===== RESULT =====\n'
if [ "$completed" = true ]; then
    printf '%s\n' 'result=suspend-cycle-completed-with-all-custom-a14-hooks-excluded'
    printf '%s\n' 'interpretation=manual-versus-spontaneous-wake-requires-user-observation'
else
    printf '%s\n' 'result=suspend-completion-not-observed'
fi
printf 'report=%s\n' "$report"
