#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

KREL="7.1.5-a14-acpi-full0"
ENTRY="ASUS Zenbook A14 — ACPI-ONLY GPIO A/B LOW-NOISE ($KREL)"
SNIPPET="/etc/grub.d/43_a14_full_acpi_gpio_ab"
KERNEL="/boot/vmlinuz-$KREL"
INITRD="/boot/initrd.img-$KREL"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "ERROR: run with sudo/root" >&2; exit 1; }
[[ -s "$KERNEL" ]] || { echo "ERROR: missing $KERNEL" >&2; exit 1; }
[[ -s "$INITRD" ]] || { echo "ERROR: missing $INITRD" >&2; exit 1; }
command -v grub-probe >/dev/null
command -v grub-mkrelpath >/dev/null
command -v update-grub >/dev/null

uuid="$(grub-probe --target=fs_uuid "$KERNEL")"
kp="$(grub-mkrelpath "$KERNEL")"
ip="$(grub-mkrelpath "$INITRD")"

# Keep the framebuffer boot console alive and prevent ordinary panic() from
# auto-rebooting, but deliberately avoid initcall_debug and per-object tracing.
# Strip inherited acpi/panic/logging/devicetree diagnostic arguments first.
args=()
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        BOOT_IMAGE=*|initrd=*|acpi=*|panic=*|loglevel=*|ignore_loglevel|keep_bootcon|initcall_debug|earlycon=*|console=*|devicetree=*|a14_*=*) ;;
        *) args+=("$arg") ;;
    esac
done
cmdline="${args[*]} acpi=force earlycon=efifb keep_bootcon console=tty0 loglevel=8 ignore_loglevel panic=0"

cat >"$SNIPPET" <<EOF
#!/bin/sh
exec tail -n +3 \$0
# Low-noise ACPI-only GPIO A/B diagnostic. Intentionally NO devicetree command.
menuentry '$ENTRY' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root $uuid
    linux $kp $cmdline
    initrd $ip
}
EOF
chmod 0755 "$SNIPPET"

! grep -qE '^[[:space:]]*devicetree[[:space:]]' "$SNIPPET" || { echo "ERROR: unexpected devicetree command" >&2; exit 1; }
grep -q 'acpi=force' "$SNIPPET" || { echo "ERROR: acpi=force missing" >&2; exit 1; }
! grep -q 'initcall_debug' "$SNIPPET" || { echo "ERROR: initcall_debug unexpectedly present" >&2; exit 1; }
grep -q 'keep_bootcon' "$SNIPPET" || { echo "ERROR: keep_bootcon missing" >&2; exit 1; }
grep -q 'panic=0' "$SNIPPET" || { echo "ERROR: panic=0 missing" >&2; exit 1; }

update-grub

echo "A14_FULL_ACPI_GPIO_AB_ENTRY=READY"
echo "entry=$ENTRY"
echo "hardware_dtb_loaded=false"
echo "acpi_force=true"
echo "keep_bootcon=true"
echo "initcall_debug=false"
echo "panic_reboot_delay=disabled"
echo "normal_entries_untouched=true"
