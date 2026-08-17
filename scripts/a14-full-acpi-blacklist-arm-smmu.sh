#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# One-shot ACPI-only confirmation test for the isolated device initcall #540.
# Blacklist only arm_smmu_init, then stop in initramfs before root mount.
set -euo pipefail

ACTION="${1:-install}"
KREL="7.1.5-a14-acpi-full0"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
WORK="${A14_FULL_ACPI_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
CONFIG="$WORK/build/.config"
KERNEL="/boot/vmlinuz-$KREL"
INITRD="/boot/initrd.img-$KREL"
SNIPPET="/etc/grub.d/41_a14_full_acpi_checkpoint"
OLD_MOUNTROOT="/etc/grub.d/41_a14_full_acpi_mountroot_shell"
ENTRY="ASUS Zenbook A14 — ACPI blacklist arm_smmu_init + mountroot shell ($KREL)"

die(){ echo "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"; }

remove_entry(){
    need_root
    rm -f "$SNIPPET" "$OLD_MOUNTROOT"
    update-grub
    echo "A14_FULL_ACPI_ARM_SMMU_BLACKLIST=REMOVED"
}

install_entry(){
    need_root
    for c in grub-probe grub-mkrelpath update-grub; do need "$c"; done
    [[ -r "$KERNEL" ]] || die "missing $KERNEL"
    [[ -r "$INITRD" ]] || die "missing $INITRD"
    [[ -r "$CONFIG" ]] || die "missing build config: $CONFIG"
    grep -q '^CONFIG_KALLSYMS=y$' "$CONFIG" || die "CONFIG_KALLSYMS is required for initcall_blacklist"

    uuid="$(grub-probe --target=fs_uuid "$KERNEL")"
    kp="$(grub-mkrelpath "$KERNEL")"
    ip="$(grub-mkrelpath "$INITRD")"

    args=()
    for arg in $(cat /proc/cmdline); do
        case "$arg" in
            BOOT_IMAGE=*|initrd=*|acpi=*|panic=*|oops=*|quiet|splash|break=*|debug|debug=*|loglevel=*|earlycon=*|console=*|ignore_loglevel|initcall_debug|keep_bootcon|a14_acpi_halt=*|a14_device_halt_after=*|initcall_blacklist=*)
                ;;
            *) args+=("$arg") ;;
        esac
    done

    # No panic= argument: Ubuntu initramfs-tools would otherwise suppress the
    # mountroot emergency shell. Keep efi=noruntime if present in the known-good
    # boot, and change only ACPI authority plus this single initcall blacklist.
    cmdline="${args[*]} acpi=force initcall_blacklist=arm_smmu_init initcall_debug loglevel=8 ignore_loglevel printk.time=1 console=tty0 debug=vc break=mountroot"

    rm -f "$OLD_MOUNTROOT"
    cat > "$SNIPPET" <<EOF
#!/bin/sh
exec tail -n +3 \$0
# ACPI-only confirmation of isolated device initcall #540. No devicetree.
menuentry '$ENTRY' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root $uuid
    linux $kp $cmdline
    initrd $ip
}
EOF
    chmod 0755 "$SNIPPET"

    ! grep -qE '^[[:space:]]*devicetree[[:space:]]' "$SNIPPET" || die "unexpected devicetree command"
    linux_line="$(grep -E '^[[:space:]]*linux[[:space:]]' "$SNIPPET")"
    grep -q 'acpi=force' <<<"$linux_line" || die "acpi=force missing"
    grep -q 'initcall_blacklist=arm_smmu_init' <<<"$linux_line" || die "arm_smmu_init blacklist missing"
    grep -q 'break=mountroot' <<<"$linux_line" || die "break=mountroot missing"
    if grep -qE '(^|[[:space:]])panic=' <<<"$linux_line"; then
        die "panic argument unexpectedly present"
    fi

    update-grub
    echo "A14_FULL_ACPI_ARM_SMMU_BLACKLIST=READY"
    echo "isolated_ordinal=540"
    echo "blacklisted_initcall=arm_smmu_init"
    echo "entry=$ENTRY"
    echo "hardware_dtb_loaded=false"
    echo "panic_argument_present=false"
    echo "break=mountroot"
    echo "expected_if_confirmed=reach (initramfs) instead of rebooting at device initcall #540"
}

case "$ACTION" in
    install) install_entry ;;
    remove) remove_entry ;;
    *) die "usage: $0 {install|remove}" ;;
esac
