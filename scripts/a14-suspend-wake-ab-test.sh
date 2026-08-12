#!/usr/bin/env bash
# Minimal suspend/wake discriminator for the ASUS Zenbook A14.
#
# Unlike the broader suspend/resume diagnostic, this collector deliberately
# performs no camera enumeration, PipeWire query, ALSA open, module reload,
# service restart, firmware change or remoteproc operation before suspend.

set -u

report=${A14_WAKE_AB_REPORT:-"$HOME/Downloads/a14-suspend-wake-ab-test.txt"}
settle_seconds=${A14_WAKE_SETTLE_SECONDS:-5}
wait_iterations=${A14_WAKE_WAIT_ITERATIONS:-300}
tmpdir=$(mktemp -d)

cleanup() {
    rm -rf -- "$tmpdir"
}
trap cleanup EXIT

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

suspend_success_count() {
    sudo awk '$1 == "success:" { print $2; found=1 } END { if (!found) print 0 }' \
        /sys/kernel/debug/suspend_stats 2>/dev/null
}

snapshot_wakeup_sources() {
    local output=$1

    sudo cat /sys/kernel/debug/wakeup_sources >"$output" 2>&1 || true
}

snapshot_interrupts() {
    local output=$1

    cat /proc/interrupts >"$output" 2>&1 || true
}

print_irq_identity() {
    local irq path value

    for irq in /sys/kernel/irq/[0-9]*; do
        [ -d "$irq" ] || continue
        printf 'irq=%s' "${irq##*/}"
        for path in actions chip_name hwirq type wakeup; do
            if [ -r "$irq/$path" ]; then
                value=$(tr '\n' ',' <"$irq/$path" 2>/dev/null || true)
                printf ' %s=%s' "$path" "${value%,}"
            fi
        done
        printf '\n'
    done
}

print_snapshot() {
    local label=$1 wakeup_file=$2 interrupts_file=$3

    printf '\n===== %s: WAKEUP SOURCES =====\n' "$label"
    cat "$wakeup_file"
    printf '\n===== %s: INTERRUPTS =====\n' "$label"
    cat "$interrupts_file"
}

for tool in awk cat date dirname grep id journalctl mkdir mktemp sleep sudo \
        systemctl tee tr uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail 'run as your normal user, not with sudo'
mkdir -p -- "$(dirname "$report")"
sudo -v || fail 'sudo authentication failed; no suspend requested'
sudo test -r /sys/kernel/debug/suspend_stats || fail 'debugfs suspend_stats is unavailable'
sudo test -r /sys/kernel/debug/wakeup_sources || fail 'debugfs wakeup_sources is unavailable'

exec > >(tee "$report") 2>&1

printf '%s\n' 'A14 minimal suspend/wake A/B diagnostic'
printf '%s\n' '====================================='
printf 'timestamp=%s\n' "$(date --iso-8601=ns)"
printf 'kernel=%s\n' "$(uname -r)"
printf 'boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id)"
printf 'settle_seconds=%s\n' "$settle_seconds"
printf '%s\n' 'pre_suspend_camera_enumeration=false'
printf '%s\n' 'pre_suspend_pipewire_query=false'
printf '%s\n' 'pre_suspend_alsa_open=false'
printf '%s\n' 'firmware_changes=false'
printf '%s\n' 'module_reload=false'
printf '%s\n' 'remoteproc_manual_control=false'
printf '%s\n' 'service_changes=false'
printf '%s\n' 'state_changes_performed=suspend-only'

success_before=$(suspend_success_count)
snapshot_wakeup_sources "$tmpdir/wakeup-before.txt"
snapshot_interrupts "$tmpdir/interrupts-before.txt"
print_snapshot BEFORE "$tmpdir/wakeup-before.txt" "$tmpdir/interrupts-before.txt"

printf '\n===== IRQ IDENTITIES BEFORE =====\n'
print_irq_identity

printf '\nSave other work. This test should remain asleep until you wake it manually.\n'
read -r -p 'Press Enter to suspend, or Ctrl-C to cancel: '

test_start=$(date --iso-8601=seconds)
suspend_request=$(date --iso-8601=ns)
printf 'suspend_request=%s\n' "$suspend_request"
sudo systemctl suspend
command_return=$(date --iso-8601=ns)
printf 'systemctl_command_return=%s\n' "$command_return"

completed=false
success_after_command=$success_before
i=0
while [ "$i" -lt "$wait_iterations" ]; do
    success_after_command=$(suspend_success_count)
    if [ "$success_after_command" -gt "$success_before" ]; then
        completed=true
        break
    fi
    i=$((i + 1))
    sleep 0.2
done

resume_observed=$(date --iso-8601=ns)
printf 'suspend_completion_observed=%s\n' "$resume_observed"
printf 'suspend_success_before=%s\n' "$success_before"
printf 'suspend_success_after=%s\n' "$success_after_command"
printf 'suspend_completed=%s\n' "$completed"

if [ "$completed" != true ]; then
    printf '%s\n' 'result=suspend-completion-not-observed'
    printf 'report=%s\n' "$report"
    exit 1
fi

printf 'post_resume_settle_seconds=%s\n' "$settle_seconds"
sleep "$settle_seconds"

snapshot_wakeup_sources "$tmpdir/wakeup-after.txt"
snapshot_interrupts "$tmpdir/interrupts-after.txt"
print_snapshot AFTER "$tmpdir/wakeup-after.txt" "$tmpdir/interrupts-after.txt"

printf '\n===== IRQ IDENTITIES AFTER =====\n'
print_irq_identity

printf '\n===== KERNEL EVENTS DURING TEST =====\n'
sudo journalctl -k -b --since "$test_start" --no-pager 2>/dev/null || true

printf '\n===== SYSTEM SLEEP EVENTS DURING TEST =====\n'
sudo journalctl -b --since "$test_start" --no-pager \
    -u systemd-suspend.service -u systemd-logind.service 2>/dev/null || true

printf '\n===== RESULT =====\n'
printf '%s\n' 'result=suspend-cycle-completed'
printf '%s\n' 'interpretation=manual-versus-spontaneous-wake-requires-user-observation'
printf 'report=%s\n' "$report"
