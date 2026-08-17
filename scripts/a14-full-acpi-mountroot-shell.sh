#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Install/remove one temporary full-ACPI initramfs shell entry.
# The test intentionally contains NO panic= argument because initramfs-tools
# treats any panic= value as a request to suppress its emergency shell and
# reboot/halt instead.
set -euo pipefail

ACTION="${1:-install}"
KREL="7.1.5-a14-acpi-full0"
KERNEL="/boot/vmlinuz-$KREL"
INITRD="/boot/initrd.img-$KREL"
SNIPPET="/etc/grub.d/41_a14_full_acpi_mountroot_shell"
ENTRY="ASUS Zenbook A14 — ACPI mountroot shell ($KREL)"

die(){ echo "ERROR: $*" >&2; exit 1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

remove_entry(){
    need_root
    rm -f "$SNIPPET"
    update-grub
    echo "A14_FULL_ACPI_MOUNTROOT_SHELL=REMOVED"
}

install_entry(){
    need_root
    for c in grub-probe grub-mkrelpath update-grub; do need "$c"; done
    [[ -r "$KERNEL" ]] || die "missing $KERNEL"
    [[ -r "$INITRD" ]] || die "missing $INITRD"

    uuid="$(grub-probe --target=fs_uuid "$KERNEL")"
    kp="$(grub-mkrelpath "$KERNEL")"
    ip="$(grub-mkrelpath "$INITRD")"

    # Reuse the known-good boot's ordinary platform arguments, but strip
    # description/debug/reboot controls that conflict with this test.
    args=()
    for arg in $(cat /proc/cmdline); do
        case "$arg" in
            BOOT_IMAGE=*|initrd=*|acpi=*|panic=*|oops=*|quiet|splash|break=*|debug|debug=*|loglevel=*|earlycon=*|console=*|ignore_loglevel|initcall_debug|keep_bootcon)
                ;;
            *) args+=("$arg") ;;
        esac
    done

    # Keep the existing efi=noruntime policy if the known-good boot uses it.
    # Crucially: NO panic= parameter here. Ubuntu initramfs-tools otherwise
    # suppresses the shell and forces a reboot/halt when mountroot fails.
    cmdline="${args[*]} acpi=force loglevel=8 ignore_loglevel printk.time=1 console=tty0 debug=vc break=mountroot"

    cat > "$SNIPPET" <<EOF
#!/bin/sh
exec tail -n +3 \$0
# Temporary ACPI-only root-storage diagnostic. NO devicetree and NO panic=.
menuentry '$ENTRY' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root $uuid
    linux $kp $cmdline
    initrd $ip
}
EOF
    chmod 0755 "$SNIPPET"

    ! grep -qE '^[[:space:]]*devicetree[[:space:]]' "$SNIPPET" || die "unexpected devicetree command"
    grep -q 'acpi=force' "$SNIPPET" || die "acpi=force missing"
    grep -q 'break=mountroot' "$SNIPPET" || die "break=mountroot missing"
    if grep -qE '(^|[[:space:]])panic=' "$SNIPPET"; then
        die "panic= unexpectedly present; this would suppress the initramfs shell"
    fi

    update-grub
    echo "A14_FULL_ACPI_MOUNTROOT_SHELL=READY"
    echo "entry=$ENTRY"
    echo "kernel=$KERNEL"
    echo "hardware_dtb_loaded=false"
    echo "panic_argument_present=false"
    echo "break=mountroot"
    echo
    echo "Boot this one temporary entry. It should stop at an (initramfs) shell BEFORE root mount."
}

case "$ACTION" in
    install) install_entry ;;
    remove) remove_entry ;;
    *) die "usage: $0 {install|remove}" ;;
esac
