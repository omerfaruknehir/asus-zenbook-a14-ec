#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Create a diagnostic ACPI-only GRUB entry that keeps the EFI boot console alive
# and stops on kernel panic instead of automatically rebooting.
set -euo pipefail

KREL="7.1.5-a14-acpi-full0"
KERNEL="/boot/vmlinuz-$KREL"
INITRD="/boot/initrd.img-$KREL"
CONFIG="/boot/config-$KREL"
SNIPPET="/etc/grub.d/42_a14_full_acpi_early_crash"
ENTRY_ID="a14-full-acpi-early-crash"
ENTRY="ASUS Zenbook A14 — ACPI-ONLY EARLY-CRASH DIAGNOSTIC ($KREL)"

die(){ echo "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"
for c in grub-probe grub-mkrelpath update-grub; do need "$c"; done
for f in "$KERNEL" "$INITRD" "$CONFIG"; do [[ -r "$f" ]] || die "missing $f"; done
grep -q '^CONFIG_EFI_EARLYCON=y$' "$CONFIG" || die "experimental kernel lacks EFI framebuffer earlycon"

uuid="$(grub-probe --target=fs_uuid "$KERNEL")"
kp="$(grub-mkrelpath "$KERNEL")"
ip="$(grub-mkrelpath "$INITRD")"

# Preserve only the machine-specific baseline. Strip all previous diagnostic,
# console, panic, boot-selection, and ACPI arguments so this entry is reproducible.
args=()
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        BOOT_IMAGE=*|initrd=*|acpi=*|panic=*|oops=*|quiet|splash|break=*|debug|debug=*|loglevel=*|earlycon=*|console=*|ignore_loglevel|initcall_debug|keep_bootcon|a14_acpi_halt=*|a14_acpi_reboot_delay_ms=*|a14_acpi_trace_delay_ms=*|a14_device_halt_after=*|initcall_blacklist=*|reserve_mem=*|ramoops.*|nokaslr|systemd.unit=*|plymouth.enable=*|rd.plymouth=*) ;;
        *) args+=("$arg") ;;
    esac
done

# keep_bootcon is intentional here: the previous failure became invisible exactly
# when efifb0 was unregistered. panic=0 leaves a panic on-screen for photography.
# initcall_debug gives the last entered/returned initcall around an early failure.
DIAG_ARGS="earlycon=efifb console=tty0 keep_bootcon loglevel=8 ignore_loglevel printk.time=1 initcall_debug panic=0 acpi=force"
cmdline="${args[*]} $DIAG_ARGS"

cat > "$SNIPPET" <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry '$ENTRY' --id '$ENTRY_ID' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root $uuid
    linux $kp $cmdline
    initrd $ip
}
EOF
chmod 0755 "$SNIPPET"

linux_line="$(awk '/^menuentry .*EARLY-CRASH DIAGNOSTIC/{seen=1} seen && /^[[:space:]]*linux[[:space:]]/{print; exit}' "$SNIPPET")"
[[ -n "$linux_line" ]] || die "failed to validate diagnostic entry"
for required in 'acpi=force' 'earlycon=efifb' 'keep_bootcon' 'initcall_debug' 'panic=0' 'console=tty0' 'ignore_loglevel'; do
    grep -qE "(^|[[:space:]])${required//=/=}" <<<"$linux_line" || die "diagnostic entry lacks $required"
done
! grep -qE '^[[:space:]]*devicetree[[:space:]]' "$SNIPPET" || die "unexpected devicetree command"
! grep -qE '(^|[[:space:]])quiet([[:space:]]|$)' <<<"$linux_line" || die "quiet unexpectedly present"
! grep -qE '(^|[[:space:]])splash([[:space:]]|$)' <<<"$linux_line" || die "splash unexpectedly present"
! grep -q 'a14_acpi_reboot_delay_ms=' <<<"$linux_line" || die "timed reboot unexpectedly present"
! grep -q 'a14_device_halt_after=' <<<"$linux_line" || die "device bisect unexpectedly present"

update-grub

echo "A14_FULL_ACPI_EARLY_CRASH_ENTRY=READY"
echo "entry=$ENTRY"
echo "hardware_dtb_loaded=false"
echo "acpi_force=true"
echo "keep_bootcon=true"
echo "initcall_debug=true"
echo "panic_reboot_delay=disabled"
echo "normal_entries_untouched=true"
