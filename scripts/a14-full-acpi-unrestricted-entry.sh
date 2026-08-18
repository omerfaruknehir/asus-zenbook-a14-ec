#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Create one unrestricted ACPI-only GRUB entry for the experimental A14 kernel.
#
# This intentionally supplies no devicetree and no A14 checkpoint/bisect halt.
# EFI framebuffer earlycon remains enabled for visibility until the normal
# console takes over; keep_bootcon is deliberately omitted to avoid duplicate
# printk output after console handoff.
set -euo pipefail

KREL="7.1.5-a14-acpi-full0"
KERNEL="/boot/vmlinuz-$KREL"
INITRD="/boot/initrd.img-$KREL"
CONFIG="/boot/config-$KREL"
SNIPPET="/etc/grub.d/41_a14_full_acpi_checkpoint"
OLD_MOUNTROOT="/etc/grub.d/41_a14_full_acpi_mountroot_shell"
ENTRY_ID="a14-full-acpi-unrestricted"
VISIBLE_ARGS="earlycon=efifb,ram console=tty0 loglevel=8 ignore_loglevel printk.time=1"

die(){ echo "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"
for c in grub-probe grub-mkrelpath update-grub; do need "$c"; done
[[ -r "$KERNEL" ]] || die "missing $KERNEL"
[[ -r "$INITRD" ]] || die "missing $INITRD"
[[ -r "$CONFIG" ]] || die "missing $CONFIG"
grep -q '^CONFIG_EFI_EARLYCON=y$' "$CONFIG" || die "experimental kernel lacks EFI framebuffer earlycon"

uuid="$(grub-probe --target=fs_uuid "$KERNEL")"
kp="$(grub-mkrelpath "$KERNEL")"
ip="$(grub-mkrelpath "$INITRD")"

# Preserve the normal machine-specific baseline cmdline (efi=noruntime,
# clk/pd/cma/stubble/crashkernel, etc.) while removing all diagnostic/test
# parameters inherited from the currently running kernel.
args=()
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        BOOT_IMAGE=*|initrd=*|acpi=*|panic=*|oops=*|quiet|splash|break=*|debug|debug=*|loglevel=*|earlycon=*|console=*|ignore_loglevel|initcall_debug|keep_bootcon|a14_acpi_halt=*|a14_acpi_reboot_delay_ms=*|a14_acpi_trace_delay_ms=*|a14_device_halt_after=*|initcall_blacklist=*|reserve_mem=*|ramoops.*|nokaslr|systemd.unit=*)
            ;;
        *) args+=("$arg") ;;
    esac
done

cmdline="${args[*]} $VISIBLE_ARGS acpi=force"
entry="ASUS Zenbook A14 — ACPI-ONLY UNRESTRICTED ($KREL)"

rm -f "$OLD_MOUNTROOT"
cat > "$SNIPPET" <<EOF
#!/bin/sh
exec tail -n +3 \$0
# Unrestricted A14 ACPI-only boot. Intentionally no devicetree and no checkpoint.
menuentry '$entry' --id '$ENTRY_ID' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root $uuid
    linux $kp $cmdline
    initrd $ip
}
EOF
chmod 0755 "$SNIPPET"

linux_line="$(awk '/^menuentry .*ACPI-ONLY UNRESTRICTED/{seen=1} seen && /^[[:space:]]*linux[[:space:]]/{print; exit}' "$SNIPPET")"
[[ -n "$linux_line" ]] || die "failed to validate generated unrestricted entry"
grep -q 'acpi=force' <<<"$linux_line" || die "unrestricted entry lacks acpi=force"
grep -q 'earlycon=efifb,ram' <<<"$linux_line" || die "EFI framebuffer earlycon missing"
! grep -qE '(^|[[:space:]])keep_bootcon([[:space:]]|$)' <<<"$linux_line" || die "keep_bootcon unexpectedly present"
! grep -qE '^[[:space:]]*devicetree[[:space:]]' "$SNIPPET" || die "unexpected devicetree command"
! grep -q 'a14_acpi_halt=' <<<"$linux_line" || die "checkpoint halt unexpectedly present"
! grep -q 'a14_device_halt_after=' <<<"$linux_line" || die "device-bisect halt unexpectedly present"
! grep -q 'a14_acpi_reboot_delay_ms=' <<<"$linux_line" || die "timed reboot unexpectedly present"
! grep -q 'a14_acpi_trace_delay_ms=' <<<"$linux_line" || die "trace delay unexpectedly present"
! grep -q 'reserve_mem=' <<<"$linux_line" || die "stale persistent-RAM reservation present"
! grep -q 'ramoops\.' <<<"$linux_line" || die "stale ramoops arguments present"
! grep -qE '(^|[[:space:]])panic=' <<<"$linux_line" || die "panic argument unexpectedly present"
! grep -qE '(^|[[:space:]])initcall_blacklist=' <<<"$linux_line" || die "stale initcall blacklist unexpectedly present"
! grep -qE '^[[:space:]]*(set[[:space:]]+next_entry=|save_env[[:space:]]+next_entry([[:space:]]|$))' "$SNIPPET" || die "entry unexpectedly arms a next boot"

update-grub

echo "A14_FULL_ACPI_UNRESTRICTED_ENTRY=READY"
echo "entry=$entry"
echo "hardware_dtb_loaded=false"
echo "acpi_force=true"
echo "checkpoint=disabled"
echo "device_bisect=disabled"
echo "timed_reboot=disabled"
echo "persistent_logging=disabled"
echo "collector=disabled"
echo "next_entry=disabled"
echo "efifb_earlycon=enabled"
echo "keep_bootcon=disabled"
echo "normal_kernel_untouched=true"
echo "custom_checkpoint_entries=1"
