#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Create and arm a one-shot ACPI-only initramfs root-debug boot for UX3407RA.
# This deliberately preserves the current normal boot's machine-specific kernel
# arguments, matching the historical ACPI entry that previously reached root.
set -euo pipefail

KREL="7.1.5-a14-acpi-full0"
KERNEL="/boot/vmlinuz-$KREL"
INITRD="/boot/initrd.img-$KREL"
SNIPPET="/etc/grub.d/42_a14_acpi_v2_root_debug"
ENTRY="ASUS Zenbook A14 — ACPI v2 ROOT DEBUG ($KREL)"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"
for c in grub-probe grub-mkrelpath update-grub grub-reboot awk grep; do need "$c"; done
[[ -s "$KERNEL" ]] || die "missing target kernel: $KERNEL"
[[ -s "$INITRD" ]] || die "missing target initrd: $INITRD"
[[ -r /proc/cmdline ]] || die "cannot read current kernel command line"
[[ "$(uname -r)" != "$KREL" ]] || die "prepare this entry from the normal DT/rescue boot"

uuid="$(grub-probe --target=fs_uuid "$KERNEL")"
kp="$(grub-mkrelpath "$KERNEL")"
ip="$(grub-mkrelpath "$INITRD")"

# Preserve the known-good machine baseline exactly as the historical 74c9bd5
# unrestricted entry did, while dropping boot/UI/ACPI/debug parameters that we
# explicitly replace below. In particular, root= and platform-specific Qualcomm
# arguments are intentionally retained.
args=()
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        BOOT_IMAGE=*|initrd=*|acpi=*|panic=*|oops=*|quiet|splash|break=*|debug|debug=*|loglevel=*|earlycon=*|console=*|ignore_loglevel|initcall_debug|keep_bootcon|a14_acpi_halt=*|a14_acpi_reboot_delay_ms=*|a14_acpi_trace_delay_ms=*|a14_device_halt_after=*|initcall_blacklist=*|reserve_mem=*|ramoops.*|nokaslr|systemd.unit=*|roottimeout=*|rootdelay=*)
            ;;
        *) args+=("$arg") ;;
    esac
done

baseline="${args[*]}"
cmdline="$baseline acpi=force earlycon=efifb,ram console=tty0 loglevel=8 ignore_loglevel printk.time=1 systemd.unit=multi-user.target break=mount debug=vc roottimeout=120"

cat >"$SNIPPET" <<EOF2
#!/bin/sh
exec tail -n +3 \$0
# ACPI-only root diagnostics. Intentionally no devicetree command.
menuentry '$ENTRY' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root $uuid
    set gfxpayload=keep
    linux $kp $cmdline
    initrd $ip
}
EOF2
chmod 0755 "$SNIPPET"

linux_line="$(awk '/^menuentry .*ROOT DEBUG/{seen=1} seen && /^[[:space:]]*linux[[:space:]]/{print; exit}' "$SNIPPET")"
[[ -n "$linux_line" ]] || die "generated debug linux line missing"
grep -Fq 'acpi=force' <<<"$linux_line" || die "ACPI force missing"
grep -Fq 'break=mount' <<<"$linux_line" || die "initramfs mount break missing"
grep -Fq 'debug=vc' <<<"$linux_line" || die "initramfs console debug missing"
grep -Fq 'roottimeout=120' <<<"$linux_line" || die "extended root timeout missing"
! grep -Eq '^[[:space:]]*devicetree[[:space:]]' "$SNIPPET" || die "debug entry unexpectedly loads a DTB"

update-grub
grub-reboot "$ENTRY"

say "A14_ACPI_V2_ROOT_DEBUG=ARMED"
say "entry=$ENTRY"
say "kernel=$KERNEL"
say "initrd=$INITRD"
say "grub_fs_uuid=$uuid"
say "preserved_baseline_cmdline=$baseline"
say "final_cmdline=$cmdline"
say "hardware_dtb_loaded=false"
say "initramfs_break=mount"
say "initramfs_debug_console=true"
say "root_timeout_seconds=120"
say "automatic_reboot=false"
say "At the initramfs shell, do NOT write to disks. Run the diagnostic commands supplied in the chat."
