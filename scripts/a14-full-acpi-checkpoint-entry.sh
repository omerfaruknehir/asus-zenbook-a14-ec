#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Maintain exactly one temporary full-ACPI checkpoint GRUB entry.
set -euo pipefail

STAGE="${1:-}"
KREL="7.1.5-a14-acpi-full0"
KERNEL="/boot/vmlinuz-$KREL"
INITRD="/boot/initrd.img-$KREL"
SNIPPET="/etc/grub.d/41_a14_full_acpi_checkpoint"
OLD_MOUNTROOT="/etc/grub.d/41_a14_full_acpi_mountroot_shell"

stages=(
    acpi-early-enter
    acpi-early-after-subsystem
    acpi-subsystem-enter
    acpi-subsystem-after-enable
    pci-acpi-enter
    pci-acpi-after
    acpi-init-enter
    acpi-bus-done
    acpi-scan-before
    acpi-scan-after
    acpi-init-done
    initcall-subsys-after
    initcall-fs-after
    initcall-device-after
    initcall-late-after
)

die(){ echo "ERROR: $*" >&2; exit 1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

valid_stage(){
    local x
    for x in "${stages[@]}"; do [[ "$STAGE" == "$x" ]] && return 0; done
    return 1
}

remove_entry(){
    need_root
    rm -f "$SNIPPET" "$OLD_MOUNTROOT"
    update-grub
    echo "A14_FULL_ACPI_CHECKPOINT_ENTRY=REMOVED"
}

install_entry(){
    need_root
    valid_stage || {
        echo "Valid stages:" >&2
        printf '  %s\n' "${stages[@]}" >&2
        die "unknown checkpoint stage: $STAGE"
    }
    for c in grub-probe grub-mkrelpath update-grub; do need "$c"; done
    [[ -r "$KERNEL" ]] || die "missing $KERNEL"
    [[ -r "$INITRD" ]] || die "missing $INITRD"

    uuid="$(grub-probe --target=fs_uuid "$KERNEL")"
    kp="$(grub-mkrelpath "$KERNEL")"
    ip="$(grub-mkrelpath "$INITRD")"

    args=()
    for arg in $(cat /proc/cmdline); do
        case "$arg" in
            BOOT_IMAGE=*|initrd=*|acpi=*|panic=*|oops=*|quiet|splash|break=*|debug|debug=*|loglevel=*|earlycon=*|console=*|ignore_loglevel|initcall_debug|keep_bootcon|a14_acpi_halt=*)
                ;;
            *) args+=("$arg") ;;
        esac
    done

    cmdline="${args[*]} acpi=force loglevel=8 ignore_loglevel printk.time=1 console=tty0 a14_acpi_halt=$STAGE"
    entry="ASUS Zenbook A14 — ACPI CHECKPOINT: $STAGE ($KREL)"

    rm -f "$OLD_MOUNTROOT"
    cat > "$SNIPPET" <<EOF
#!/bin/sh
exec tail -n +3 \$0
# Temporary ACPI-only early-kernel checkpoint. Intentionally no devicetree.
menuentry '$entry' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root $uuid
    linux $kp $cmdline
    initrd $ip
}
EOF
    chmod 0755 "$SNIPPET"

    ! grep -qE '^[[:space:]]*devicetree[[:space:]]' "$SNIPPET" || die "unexpected devicetree command"
    linux_line="$(grep -E '^[[:space:]]*linux[[:space:]]' "$SNIPPET")"
    grep -q 'acpi=force' <<<"$linux_line" || die "acpi=force missing"
    grep -q "a14_acpi_halt=$STAGE" <<<"$linux_line" || die "checkpoint argument missing"
    if grep -qE '(^|[[:space:]])panic=' <<<"$linux_line"; then
        die "panic argument unexpectedly present"
    fi

    update-grub
    echo "A14_FULL_ACPI_CHECKPOINT_ENTRY=READY"
    echo "stage=$STAGE"
    echo "entry=$entry"
    echo "hardware_dtb_loaded=false"
    echo "normal_kernel_untouched=true"
    echo "custom_checkpoint_entries=1"
}

case "$STAGE" in
    remove) remove_entry ;;
    "")
        echo "usage: $0 {stage|remove}" >&2
        printf '  %s\n' "${stages[@]}" >&2
        exit 2
        ;;
    *) install_entry ;;
esac
