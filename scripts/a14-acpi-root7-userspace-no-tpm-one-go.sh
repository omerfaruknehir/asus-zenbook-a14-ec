#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# ACPI ROOT7: normal systemd userspace boot using ROOT5 kernel, but skip TPM RM wait.
#
# Safety invariants:
#   - no kernel rebuild
#   - no modules build/install
#   - no initramfs build
#   - no DTB
#   - prepare always leaves GRUB next_entry empty
#   - arm only sets one-shot GRUB state; never reboots
#   - panic=0
set -euo pipefail

ACTION="${1:-prepare}"
KREL="7.1.5-a14-acpi-root5"
ENTRY="ASUS Zenbook A14 — ACPI ROOT7 userspace no-TPM-wait via ROOT5 ($KREL)"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
OWNER="${SUDO_USER:-}"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"
[[ -n "$OWNER" && "$OWNER" != root ]] || die "run with sudo from your normal login"
OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
[[ -d "$OWNER_HOME" ]] || die "cannot resolve owner home"

KERNEL="/boot/vmlinuz-$KREL"
BOOT_CONFIG="/boot/config-$KREL"
SNIPPET="/etc/grub.d/49_a14_acpi_root7_userspace_no_tpm"
ROOT5_REPORT="$OWNER_HOME/Downloads/a14-acpi-root5.txt"
ROOT6_NOTE="$OWNER_HOME/Downloads/a14-acpi-root6-userspace-note.txt"
ROOT7_NOTE="$OWNER_HOME/Downloads/a14-acpi-root7-userspace-no-tpm-note.txt"

for c in awk grep sed findmnt blkid grub-probe grub-mkrelpath update-grub grub-editenv grub-script-check sha256sum sync; do need "$c"; done

unarm(){
    grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true
    say "A14_ACPI_ROOT7_UNARMED=1"
    say "reboot_performed=false"
}

status(){
    say "running_kernel=$(uname -r)"
    say "kernel=$KERNEL"
    [[ -s "$KERNEL" ]] && say "kernel_sha256=$(sha256sum "$KERNEL" | awk '{print $1}')"
    [[ -r "$BOOT_CONFIG" ]] && grep '^CONFIG_LOCALVERSION=' "$BOOT_CONFIG" || true
    [[ -r "$SNIPPET" ]] && say "grub_entry=present" || say "grub_entry=absent"
    say "next_entry=$(grub-editenv /boot/grub/grubenv list 2>/dev/null | sed -n 's/^next_entry=//p' | head -n1)"
    say "reboot_performed=false"
}

arm(){
    need grub-reboot
    [[ -s "$KERNEL" ]] || die "ROOT5 kernel missing: $KERNEL; run ROOT5 prepare first"
    [[ -r "$SNIPPET" ]] || die "ROOT7 GRUB snippet missing: $SNIPPET; run prepare first"
    grub-script-check /boot/grub/grub.cfg >/dev/null
    grub-reboot "$ENTRY"
    next="$(grub-editenv /boot/grub/grubenv list | sed -n 's/^next_entry=//p' | head -n1)"
    [[ "$next" == "$ENTRY" ]] || die "failed to arm ROOT7: ${next:-missing}"
    say "A14_ACPI_ROOT7_ARMED=1"
    say "next_entry=$next"
    say "reboot_performed=false"
    say "Reboot manually only when YOU choose: sudo reboot"
}

prepare(){
    case "$(uname -r)" in
        7.1.5-a14-acpi-full0|7.1.5-a14-acpi-root0|7.1.5-a14-acpi-root1|7.1.5-a14-acpi-root2|7.1.5-a14-acpi-root3|7.1.5-a14-acpi-root4|$KREL)
            die "run prepare from the normal DT/rescue kernel" ;;
    esac

    [[ -s "$KERNEL" ]] || die "ROOT5 kernel missing: $KERNEL; run ROOT5 prepare first"
    [[ -r "$BOOT_CONFIG" ]] || die "ROOT5 config missing: $BOOT_CONFIG"
    grep -Fxq 'CONFIG_LOCALVERSION="-a14-acpi-root5"' "$BOOT_CONFIG" || die "ROOT5 kernel config localversion mismatch"
    if [[ -r "$ROOT5_REPORT" ]]; then
        grep -Fq 'A14_ACPI_ROOT5_GSBUS_AE_SUPPORT=CLEARED' "$ROOT5_REPORT" || die "ROOT5 report does not prove AE_SUPPORT cleared"
        grep -Fq 'A14_ACPI_ROOT5_PROVIDER4_FAKE_POWER_DATA=false' "$ROOT5_REPORT" || die "ROOT5 report does not prove no fake power data"
        grep -Fq 'A14_ACPI_ROOT5_KEYBOARD=PASS' "$ROOT5_REPORT" || die "ROOT5 report does not prove keyboard path"
    else
        say "warning=ROOT5 report not found; continuing because installed kernel exists"
    fi
    [[ -r "$ROOT6_NOTE" ]] && say "root6_note=present" || say "root6_note=absent"

    grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true

    root_src="$(findmnt -n -o SOURCE /)"
    root_fs="$(findmnt -n -o FSTYPE /)"
    [[ "$root_src" == /dev/nvme*n*p* ]] || die "root is not direct NVMe: $root_src"
    [[ "$root_fs" == ext4 ]] || die "root is not ext4: $root_fs"
    root_partuuid="$(blkid -s PARTUUID -o value "$root_src")"
    [[ -n "$root_partuuid" ]] || die "cannot resolve root PARTUUID"

    boot_uuid="$(grub-probe -t fs_uuid /boot)"
    kernel_path="$(grub-mkrelpath "$KERNEL")"
    [[ -n "$boot_uuid" && -n "$kernel_path" ]] || die "cannot resolve GRUB /boot identity"

    cat >"$SNIPPET" <<ROOT7_GRUB
#!/bin/sh
exec tail -n +3 \$0
menuentry '$ENTRY' {
    search --no-floppy --fs-uuid --set=root '$boot_uuid'
    linux '$kernel_path' root=PARTUUID=$root_partuuid rw rootfstype=ext4 rootwait acpi=force earlycon=efifb,ram console=tty0 loglevel=8 ignore_loglevel printk.time=1 panic=0 clk_ignore_unused pd_ignore_unused cma=128M efi=noruntime stubble.dtb_override=false systemd.unit=multi-user.target systemd.mask=dev-tpmrm0.device systemd.mask=tpm2.target
}
ROOT7_GRUB
    chmod 0755 "$SNIPPET"
    grub-script-check "$SNIPPET" >/dev/null
    update-grub
    grub-script-check /boot/grub/grub.cfg >/dev/null

    grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true
    next="$(grub-editenv /boot/grub/grubenv list 2>/dev/null | sed -n 's/^next_entry=//p' | head -n1)"
    [[ -z "$next" ]] || die "prepare unexpectedly left next_entry armed: $next"

    {
        say "A14_ACPI_ROOT7_NOTE=prepared"
        say "kernel=$KERNEL"
        say "kernel_sha256=$(sha256sum "$KERNEL" | awk '{print $1}')"
        say "entry=$ENTRY"
        say "mode=normal_systemd_multi_user_tpm_masked"
        say "init_override=false"
        say "initramfs_used=false"
        say "modules_built=false"
        say "hardware_dtb_loaded=false"
        say "tpm_masked=dev-tpmrm0.device,tpm2.target"
        say "panic_auto_reboot=false"
    } >"$ROOT7_NOTE"
    chown "$OWNER:$OWNER" "$ROOT7_NOTE" 2>/dev/null || true
    sync

    say "A14_ACPI_ROOT7_PREPARE=PASS"
    say "kernel=$KERNEL"
    say "kernel_sha256=$(sha256sum "$KERNEL" | awk '{print $1}')"
    say "mode=normal_systemd_multi_user_tpm_masked"
    say "uses_existing_root5_kernel=true"
    say "kernel_rebuilt=false"
    say "modules_built=false"
    say "modules_installed=false"
    say "initramfs_used=false"
    say "hardware_dtb_loaded=false"
    say "init_override=false"
    say "tpm_masked=dev-tpmrm0.device,tpm2.target"
    say "panic_auto_reboot=false"
    say "root_partuuid=$root_partuuid"
    say "grub_entry=$ENTRY"
    say "next_entry=UNARMED"
    say "reboot_performed=false"
    say "To arm: sudo bash scripts/a14-acpi-root7-userspace-no-tpm-one-go.sh arm"
}

case "$ACTION" in
    prepare) prepare ;;
    arm) arm ;;
    unarm) unarm ;;
    status) status ;;
    *) die "usage: $0 [prepare|arm|unarm|status]" ;;
esac
