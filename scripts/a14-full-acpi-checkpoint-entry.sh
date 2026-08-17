#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Maintain one temporary visible full-ACPI diagnostic entry.
#
# The selected checkpoint emits breadcrumbs on EFI framebuffer earlycon,
# waits a bounded interval, then emergency-restarts. Non-selected breadcrumbs
# can pause briefly so the last stage before a hardware reset is readable.
set -euo pipefail

STAGE="${1:-}"
KREL="7.1.5-a14-acpi-full0"
KERNEL="/boot/vmlinuz-$KREL"
INITRD="/boot/initrd.img-$KREL"
CONFIG="/boot/config-$KREL"
SNIPPET="/etc/grub.d/41_a14_full_acpi_checkpoint"
OLD_MOUNTROOT="/etc/grub.d/41_a14_full_acpi_mountroot_shell"
DIAG_ID="a14-acpi-checkpoint-visible"
REBOOT_DELAY_MS="${A14_ACPI_REBOOT_DELAY_MS:-5000}"
TRACE_DELAY_MS="${A14_ACPI_TRACE_DELAY_MS:-2000}"
VISIBLE_ARGS="earlycon=efifb,ram keep_bootcon console=tty0 loglevel=8 ignore_loglevel printk.time=1"

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
    smmu-init-enter
    smmu-driver-registered
    smmu-impl-registered
    smmu-reset-enter
    smmu-reset-after-gfsr
    smmu-reset-after-streams
    smmu-reset-after-contexts
    smmu-reset-after-tlbi
    smmu-reset-after-scr0-read
    smmu-reset-before-impl
    smmu-reset-after-impl
    smmu-reset-before-sync
    smmu-reset-after-sync
    smmu-reset-before-scr0-write
    smmu-reset-after-scr0-write
)

smmu_probe_points=(
    enter
    after-fwdata
    after-ioremap
    after-impl
    before-cfg
    after-cfg
    before-rmr
    after-rmr
    before-reset
    after-reset
    after-smr-test
)

die(){ echo "ERROR: $*" >&2; exit 1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

valid_stage(){
    local x point
    for x in "${stages[@]}"; do [[ "$STAGE" == "$x" ]] && return 0; done
    if [[ "$STAGE" =~ ^smmu-probe([1-9][0-9]*)-(.+)$ ]]; then
        for point in "${smmu_probe_points[@]}"; do
            [[ "${BASH_REMATCH[2]}" == "$point" ]] && return 0
        done
    fi
    return 1
}

print_stages(){
    printf '  %s\n' "${stages[@]}"
    echo '  smmu-probeN-{enter,after-fwdata,after-ioremap,after-impl,before-cfg,after-cfg,before-rmr,after-rmr,before-reset,after-reset,after-smr-test}'
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
        print_stages >&2
        die "unknown checkpoint stage: $STAGE"
    }
    [[ "$REBOOT_DELAY_MS" =~ ^[0-9]+$ ]] || die "A14_ACPI_REBOOT_DELAY_MS must be an integer number of milliseconds"
    [[ "$TRACE_DELAY_MS" =~ ^[0-9]+$ ]] || die "A14_ACPI_TRACE_DELAY_MS must be an integer number of milliseconds"
    (( REBOOT_DELAY_MS <= 60000 )) || die "A14_ACPI_REBOOT_DELAY_MS must be <= 60000"
    (( TRACE_DELAY_MS <= 10000 )) || die "A14_ACPI_TRACE_DELAY_MS must be <= 10000"

    for c in grub-probe grub-mkrelpath update-grub; do need "$c"; done
    [[ -r "$KERNEL" ]] || die "missing $KERNEL"
    [[ -r "$INITRD" ]] || die "missing $INITRD"
    [[ -r "$CONFIG" ]] || die "missing $CONFIG"
    grep -q '^CONFIG_EFI_EARLYCON=y$' "$CONFIG" || die "experimental kernel lacks EFI framebuffer earlycon"

    uuid="$(grub-probe --target=fs_uuid "$KERNEL")"
    kp="$(grub-mkrelpath "$KERNEL")"
    ip="$(grub-mkrelpath "$INITRD")"

    args=()
    for arg in $(cat /proc/cmdline); do
        case "$arg" in
            BOOT_IMAGE=*|initrd=*|acpi=*|panic=*|oops=*|quiet|splash|break=*|debug|debug=*|loglevel=*|earlycon=*|console=*|ignore_loglevel|initcall_debug|keep_bootcon|a14_acpi_halt=*|a14_acpi_reboot_delay_ms=*|a14_acpi_trace_delay_ms=*|a14_device_halt_after=*|initcall_blacklist=*|reserve_mem=*|ramoops.*|nokaslr|systemd.unit=*)
                ;;
            *) args+=("$arg") ;;
        esac
    done

    diag_cmdline="${args[*]} $VISIBLE_ARGS acpi=force a14_acpi_halt=$STAGE a14_acpi_reboot_delay_ms=$REBOOT_DELAY_MS a14_acpi_trace_delay_ms=$TRACE_DELAY_MS"
    diag_entry="ASUS Zenbook A14 — ACPI VISIBLE CHECKPOINT: $STAGE ($KREL)"

    rm -f "$OLD_MOUNTROOT"
    cat > "$SNIPPET" <<EOF
#!/bin/sh
exec tail -n +3 \$0
# Temporary A14 full-ACPI visible diagnostic. No collector and no next_entry.
menuentry '$diag_entry' --id '$DIAG_ID' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root $uuid
    linux $kp $diag_cmdline
    initrd $ip
}
EOF
    chmod 0755 "$SNIPPET"

    linux_line="$(awk '/^menuentry .*VISIBLE CHECKPOINT/{seen=1} seen && /^[[:space:]]*linux[[:space:]]/{print; exit}' "$SNIPPET")"
    [[ -n "$linux_line" ]] || die "failed to validate generated diagnostic entry"
    grep -q 'acpi=force' <<<"$linux_line" || die "diagnostic lacks acpi=force"
    grep -q "a14_acpi_halt=$STAGE" <<<"$linux_line" || die "diagnostic checkpoint argument missing"
    grep -q "a14_acpi_reboot_delay_ms=$REBOOT_DELAY_MS" <<<"$linux_line" || die "timed reboot argument missing"
    grep -q "a14_acpi_trace_delay_ms=$TRACE_DELAY_MS" <<<"$linux_line" || die "trace readability delay argument missing"
    grep -q 'earlycon=efifb,ram' <<<"$linux_line" || die "EFI framebuffer earlycon missing"
    grep -q 'keep_bootcon' <<<"$linux_line" || die "keep_bootcon missing"
    ! grep -qE '^[[:space:]]*devicetree[[:space:]]' "$SNIPPET" || die "diagnostic unexpectedly loads a devicetree"
    ! grep -qE '^[[:space:]]*(set[[:space:]]+next_entry=|save_env[[:space:]]+next_entry([[:space:]]|$))' "$SNIPPET" || die "diagnostic unexpectedly arms a next boot"
    ! grep -q 'reserve_mem=' <<<"$linux_line" || die "stale persistent-RAM reservation present"
    ! grep -q 'ramoops\.' <<<"$linux_line" || die "stale ramoops arguments present"
    ! grep -qE '(^|[[:space:]])panic=' <<<"$linux_line" || die "panic argument unexpectedly present"
    ! grep -qE '(^|[[:space:]])initcall_blacklist=' <<<"$linux_line" || die "stale initcall blacklist unexpectedly present"

    update-grub
    echo "A14_FULL_ACPI_VISIBLE_CHECKPOINT_ENTRY=READY"
    echo "stage=$STAGE"
    echo "entry=$diag_entry"
    echo "checkpoint_reboot_delay_ms=$REBOOT_DELAY_MS"
    echo "trace_delay_ms=$TRACE_DELAY_MS"
    echo "trace_delay_scope=non-selected-checkpoints"
    echo "checkpoint_exit=emergency_restart"
    echo "post_reboot=normal-grub-default"
    echo "hardware_dtb_loaded=false"
    echo "efifb_earlycon=enabled"
    echo "persistent_logging=disabled"
    echo "collector=disabled"
    echo "next_entry=disabled"
    echo "normal_kernel_untouched=true"
    echo "custom_checkpoint_entries=1"
}

case "$STAGE" in
    remove) remove_entry ;;
    "")
        echo "usage: $0 {stage|remove}" >&2
        print_stages >&2
        exit 2
        ;;
    *) install_entry ;;
esac
