#!/usr/bin/env bash
# Read-only audit of suspend hooks and low-level sleep diagnostics on the A14.

set -u

report=${A14_SUSPEND_HOOK_AUDIT_REPORT:-"$HOME/Downloads/a14-suspend-hook-audit.txt"}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

print_file() {
    local path=$1 resolved

    printf '\n--- path=%s ---\n' "$path"
    if ! sudo test -e "$path" && ! sudo test -L "$path"; then
        printf '%s\n' 'exists=false'
        return
    fi

    resolved=$(sudo readlink -f -- "$path" 2>/dev/null || printf '%s' "$path")
    printf 'resolved=%s\n' "$resolved"
    sudo stat -Lc 'type=%F size=%s mode=%a owner=%U:%G mtime=%y' -- "$path" 2>&1 || true
    sudo sha256sum -- "$resolved" 2>&1 || true
    printf 'package_owner='
    dpkg-query -S "$resolved" 2>/dev/null || printf '%s\n' unowned
    printf '%s\n' 'content_begin'
    sudo sed -n '1,360p' -- "$resolved" 2>&1 || true
    printf '%s\n' 'content_end'
}

print_tree_files() {
    local root=$1 file

    printf '\n--- root=%s ---\n' "$root"
    if ! sudo test -d "$root"; then
        printf '%s\n' 'exists=false'
        return
    fi

    while IFS= read -r file; do
        printf '\nfile=%s\n' "$file"
        sudo stat -Lc 'type=%F size=%s mode=%a owner=%U:%G mtime=%y' -- "$file" 2>&1 || true
        sudo sed -n '1,160p' -- "$file" 2>&1 || true
    done < <(sudo find "$root" -maxdepth 1 -type f -print 2>/dev/null | sort)
}

for tool in cat date dirname dpkg-query find grep id journalctl lsmod mkdir \
        readlink sed sha256sum sort stat sudo systemctl tee tr uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail 'run as your normal user, not with sudo'

mkdir -p -- "$(dirname "$report")"
sudo -v || fail 'sudo authentication failed'

exec > >(tee "$report") 2>&1

printf '%s\n' 'A14 suspend-hook and low-level sleep audit'
printf '%s\n' '==========================================='
printf 'timestamp=%s\n' "$(date --iso-8601=ns)"
printf 'kernel=%s\n' "$(uname -r)"
printf 'boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id)"
printf 'cmdline=%s\n' "$(cat /proc/cmdline)"
printf '%s\n' 'state_changes_performed=false'
printf '%s\n' 'suspend_requested=false'
printf '%s\n' 'firmware_changes=false'
printf '%s\n' 'module_reload=false'
printf '%s\n' 'service_changes=false'

printf '\n===== POWER CONFIGURATION =====\n'
for path in /sys/power/state /sys/power/mem_sleep /sys/power/pm_async \
        /sys/power/pm_debug_messages /sys/module/printk/parameters/console_suspend; do
    printf '%s=' "$path"
    sudo cat "$path" 2>&1 || true
done

printf '\n===== INSTALLED SYSTEM-SLEEP DIRECTORY =====\n'
sudo find /usr/lib/systemd/system-sleep /etc/systemd/system-sleep \
    -maxdepth 1 -mindepth 1 -printf '%M %u:%g %s %p -> %l\n' 2>/dev/null | sort || true

printf '\n===== RELEVANT SYSTEM-SLEEP HOOKS =====\n'
for path in \
    /usr/lib/systemd/system-sleep/85-a14-x1e-suspend-hardware \
    /usr/lib/systemd/system-sleep/a14-kbd-leds \
    /usr/lib/systemd/system-sleep/aegis-hello; do
    print_file "$path"
done

printf '\n===== REFERENCED A14 / AEGIS UNITS =====\n'
systemctl list-unit-files --no-pager --no-legend 2>/dev/null | \
    grep -Ei 'a14|aegis|hello|suspend|resume' || true
for unit in a14-x1e-hardware-resume.service aegis-hello.service \
        a14-kbd-leds.service; do
    printf '\n--- unit=%s ---\n' "$unit"
    systemctl cat "$unit" --no-pager 2>&1 || true
    systemctl show "$unit" --no-pager \
        -p LoadState -p ActiveState -p SubState -p FragmentPath \
        -p DropInPaths -p ExecStart 2>&1 || true
done

printf '\n===== QCOM SLEEP-STATS SUPPORT =====\n'
lsmod | grep -E '^qcom_stats[[:space:]]' || printf '%s\n' 'qcom_stats_module_loaded=false'
if [ -r "/boot/config-$(uname -r)" ]; then
    grep -E '^CONFIG_QCOM_(STATS|RPM_MASTER_STATS)=' "/boot/config-$(uname -r)" || true
fi
print_tree_files /sys/kernel/debug/qcom_sleep_stats

printf '\n===== RTC STATE =====\n'
for rtc in /sys/class/rtc/rtc*; do
    [ -d "$rtc" ] || continue
    printf '\n--- rtc=%s ---\n' "$rtc"
    for key in name date time since_epoch wakealarm; do
        printf '%s=' "$key"
        sudo cat "$rtc/$key" 2>&1 || true
    done
done
sudo cat /proc/driver/rtc 2>&1 || true

printf '\n===== HID / I2C DEVICES FROM WAKE COUNTERS =====\n'
for dev in /sys/bus/i2c/devices/4-0015 /sys/bus/i2c/devices/5-0015 \
        /sys/bus/i2c/devices/7-0017; do
    printf '\n--- device=%s ---\n' "$dev"
    readlink -f "$dev" 2>&1 || true
    for key in name modalias power/wakeup power/runtime_status; do
        printf '%s=' "$key"
        sudo cat "$dev/$key" 2>&1 || true
    done
done

printf '\n===== RELEVANT IRQ IDENTITIES =====\n'
for irq in 24 25 26 27 28 29 30 31 146 221 222 223; do
    printf 'irq=%s' "$irq"
    for key in actions chip_name hwirq type wakeup; do
        printf ' %s=' "$key"
        sudo cat "/sys/kernel/irq/$irq/$key" 2>/dev/null | tr '\n' ',' | sed 's/,$//' || true
    done
    printf '\n'
done

printf '\n===== CURRENT WAKEUP SOURCES =====\n'
sudo cat /sys/kernel/debug/wakeup_sources 2>&1 || true

printf '\n===== SUSPEND LOGS THIS BOOT =====\n'
sudo journalctl -k -b --no-pager 2>/dev/null | \
    grep -Ei 'PM: suspend|PM: resume|suspend entry|suspend exit|wakeup|wake source|psci|IRQ(146|221|222|223)' || true

printf '\n===== RESULT =====\n'
printf '%s\n' 'result=read-only-suspend-hook-audit-complete'
printf 'report=%s\n' "$report"
