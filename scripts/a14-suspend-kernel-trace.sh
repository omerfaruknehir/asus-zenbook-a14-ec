#!/usr/bin/env bash
# Trace the first kernel activity around the A14's immediate deep-suspend wake.
# All known custom A14 system-sleep hooks are temporarily masked so the trace
# describes the kernel/platform path rather than the local recovery helpers.

set -u

report=${A14_SUSPEND_TRACE_REPORT:-"$HOME/Downloads/a14-suspend-kernel-trace.txt"}
buffer_kb=${A14_SUSPEND_TRACE_BUFFER_KB:-4096}
wait_iterations=${A14_SUSPEND_TRACE_WAIT_ITERATIONS:-300}
hardware_hook=/usr/lib/systemd/system-sleep/85-a14-x1e-suspend-hardware
aegis_hook=/usr/lib/systemd/system-sleep/aegis-hello
keyboard_hook=/usr/lib/systemd/system-sleep/a14-kbd-leds
hardware_sha=01967e3601edf7dbecf193841084f736ee20767121d20abe0a9f17f13ec695d4
aegis_sha=19231d1dbc7d7d9402c95afe999c1360dfac970d1a0c6241c52e197b47de388b
keyboard_sha=d60782eac68afcbd202ccc7996f095eaca9d00f66d05f57e201cfc76d4f79797
pm_debug_path=/sys/power/pm_debug_messages
trace_root=
trace_dir=
trace_dumped=false
pm_debug_original=
masked_hooks=
aegis_was_active=false
keyboard_was_active=false

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

write_control() {
    local value=$1
    local path=$2

    printf '%s\n' "$value" | sudo tee "$path" >/dev/null
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

stop_trace() {
    if [ -n "$trace_dir" ] && sudo test -f "$trace_dir/tracing_on"; then
        write_control 0 "$trace_dir/tracing_on" || true
    fi
}

dump_trace() {
    if [ "$trace_dumped" = false ] && [ -n "$trace_dir" ] && \
            sudo test -f "$trace_dir/trace"; then
        printf '\n===== FTRACE SUSPEND / WAKE TIMELINE =====\n'
        sudo cat "$trace_dir/trace" 2>&1 || true
        trace_dumped=true
    fi
}

restore_state() {
    local hook

    stop_trace

    if [ -n "$pm_debug_original" ] && sudo test -w "$pm_debug_path"; then
        write_control "$pm_debug_original" "$pm_debug_path" || true
        printf 'pm_debug_messages_restored=%s\n' "$pm_debug_original"
        pm_debug_original=
    fi

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

remove_trace_instance() {
    if [ -n "$trace_dir" ] && sudo test -d "$trace_dir"; then
        sudo rmdir -- "$trace_dir" || \
            printf 'WARNING: could not remove trace instance: %s\n' "$trace_dir" >&2
    fi
    trace_dir=
}

cleanup() {
    stop_trace
    dump_trace
    restore_state
    remove_trace_instance
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

for tool in awk cat date dirname grep id journalctl mkdir mount mountpoint \
        rmdir sha256sum sleep stat sudo systemctl tee umount uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail 'run as your normal user, not with sudo'
case $buffer_kb in
    ''|*[!0-9]*) fail 'A14_SUSPEND_TRACE_BUFFER_KB must be a positive integer' ;;
    0) fail 'A14_SUSPEND_TRACE_BUFFER_KB must be greater than zero' ;;
esac

mkdir -p -- "$(dirname "$report")"
sudo -v || fail 'sudo authentication failed; no state changed'
sudo test -r /sys/kernel/debug/suspend_stats || fail 'debugfs suspend_stats is unavailable'
sudo test ! -e /run/a14-kbd-sleeping || \
    fail '/run/a14-kbd-sleeping already exists; reboot or clear the stale keyboard sleep state first'

for candidate in /sys/kernel/tracing /sys/kernel/debug/tracing; do
    if sudo test -d "$candidate/instances" && sudo test -f "$candidate/tracing_on"; then
        trace_root=$candidate
        break
    fi
done
[ -n "$trace_root" ] || fail 'tracefs with instance support is unavailable'

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

printf '%s\n' 'A14 deep-suspend kernel wake trace'
printf '%s\n' '=================================='
printf 'timestamp=%s\n' "$(date --iso-8601=ns)"
printf 'kernel=%s\n' "$(uname -r)"
printf 'boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id)"
printf 'trace_root=%s\n' "$trace_root"
printf 'requested_buffer_kb_per_cpu=%s\n' "$buffer_kb"
printf '%s\n' 'hook_files_edited=false'
printf '%s\n' 'temporary_bind_mount_source=/dev/null'
printf '%s\n' 'firmware_changes=false'
printf '%s\n' 'module_reload=false'
printf '%s\n' 'remoteproc_manual_control=false'
printf '%s\n' 'service_disable=false'

trace_dir="$trace_root/instances/a14_suspend_wake_$$"
sudo mkdir -- "$trace_dir" || fail 'failed to create an isolated tracefs instance'
write_control 0 "$trace_dir/tracing_on" || fail 'failed to stop the new trace instance'
write_control 0 "$trace_dir/events/enable" || fail 'failed to reset trace events'
write_control nop "$trace_dir/current_tracer" || fail 'failed to select the nop tracer'
write_control "$buffer_kb" "$trace_dir/buffer_size_kb" || fail 'failed to size trace buffer'
printf 'actual_buffer_kb_per_cpu=%s\n' "$(sudo cat "$trace_dir/buffer_size_kb")"

if sudo grep -qw global "$trace_dir/trace_clock"; then
    write_control global "$trace_dir/trace_clock" || fail 'failed to select global trace clock'
fi
printf 'trace_clock=%s\n' "$(sudo cat "$trace_dir/trace_clock")"

printf '\n===== TRACE EVENTS =====\n'
for event in \
        power/suspend_resume \
        power/machine_suspend \
        power/wakeup_source_activate \
        power/wakeup_source_deactivate \
        power/device_pm_callback_start \
        power/device_pm_callback_end \
        irq/irq_handler_entry \
        irq/irq_handler_exit \
        gpio/gpio_value \
        timer/hrtimer_expire_entry \
        timer/alarmtimer_fired; do
    event_enable="$trace_dir/events/$event/enable"
    if sudo test -f "$event_enable"; then
        write_control 1 "$event_enable" || fail "failed to enable trace event: $event"
        printf 'enabled=%s\n' "$event"
    else
        printf 'unavailable=%s\n' "$event"
    fi
done
sudo test "$(sudo cat "$trace_dir/events/irq/irq_handler_entry/enable")" = 1 || \
    fail 'IRQ handler entry tracing is unavailable'

if sudo systemctl is-active --quiet aegis-hello.service; then
    aegis_was_active=true
    sudo systemctl stop aegis-hello.service || fail 'failed to stop Aegis Hello before trace'
fi
if sudo systemctl is-active --quiet a14-kbd-userspace.service; then
    keyboard_was_active=true
    sudo systemctl stop a14-kbd-userspace.service || \
        fail 'failed to stop the A14 keyboard userspace service before trace'
fi
printf 'aegis_was_active=%s\n' "$aegis_was_active"
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

printf '\n===== INTERRUPTS BEFORE SUSPEND =====\n'
sudo cat /proc/interrupts
printf '\n===== WAKEUP SOURCES BEFORE SUSPEND =====\n'
sudo cat /sys/kernel/debug/wakeup_sources 2>&1 || true

success_before=$(suspend_success_count)
test_start=$(date --iso-8601=seconds)
if sudo test -r "$pm_debug_path" && sudo test -w "$pm_debug_path"; then
    pm_debug_original=$(sudo cat "$pm_debug_path")
    write_control 1 "$pm_debug_path" || fail 'failed to enable PM debug messages'
fi
printf 'pm_debug_messages_original=%s\n' "${pm_debug_original:-unavailable}"

write_control '' "$trace_dir/trace" || fail 'failed to clear trace buffer'
write_control 1 "$trace_dir/tracing_on" || fail 'failed to start tracing'
printf 'trace_started=%s\n' "$(date --iso-8601=ns)"

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
stop_trace
printf 'trace_stopped=%s\n' "$(date --iso-8601=ns)"
printf 'suspend_success_before=%s\n' "$success_before"
printf 'suspend_success_after=%s\n' "$success_after"
printf 'suspend_completed=%s\n' "$completed"

if [ -n "$pm_debug_original" ]; then
    write_control "$pm_debug_original" "$pm_debug_path" || true
    printf 'pm_debug_messages_restored=%s\n' "$pm_debug_original"
    pm_debug_original=
fi

printf '\n===== INTERRUPTS AFTER RESUME =====\n'
sudo cat /proc/interrupts
printf '\n===== WAKEUP SOURCES AFTER RESUME =====\n'
sudo cat /sys/kernel/debug/wakeup_sources 2>&1 || true

restore_state
dump_trace
remove_trace_instance

printf '\n===== KERNEL EVENTS DURING TEST =====\n'
sudo journalctl -k -b --since "$test_start" --no-pager 2>/dev/null || true

printf '\n===== SLEEP-SERVICE EVENTS DURING TEST =====\n'
sudo journalctl -b --since "$test_start" --no-pager \
    -u systemd-suspend.service 2>/dev/null || true

printf '\n===== RESULT =====\n'
if [ "$completed" = true ]; then
    printf '%s\n' 'result=suspend-kernel-trace-captured'
else
    printf '%s\n' 'result=suspend-completion-not-observed'
fi
printf 'report=%s\n' "$report"
