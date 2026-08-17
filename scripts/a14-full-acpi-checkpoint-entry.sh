#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Maintain one temporary full-ACPI diagnostic plus one same-Image DT collector.
set -euo pipefail

STAGE="${1:-}"
KREL="7.1.5-a14-acpi-full0"
KERNEL="/boot/vmlinuz-$KREL"
INITRD="/boot/initrd.img-$KREL"
DTDIR="/boot/a14-full-acpi-control"
DTB="$DTDIR/known-good-live.dtb"
CONFIG="/boot/config-$KREL"
SNIPPET="/etc/grub.d/41_a14_full_acpi_checkpoint"
OLD_MOUNTROOT="/etc/grub.d/41_a14_full_acpi_mountroot_shell"
DIAG_ID="a14-acpi-checkpoint-log"
COLLECT_ID="a14-pstore-collector"
REBOOT_DELAY_MS="${A14_ACPI_REBOOT_DELAY_MS:-5000}"

# Keep the ramoops layout identical between the failing ACPI boot and the
# same-Image DT collector boot. nokaslr makes reserve_mem's memblock allocation
# deterministic enough to recover ramoops data across the soft reset.
RAMOOPS_RESERVE="reserve_mem=2M:1M:a14log"
RAMOOPS_ARGS="ramoops.mem_name=a14log ramoops.console_size=1048576 ramoops.record_size=262144 ramoops.ftrace_size=0 ramoops.pmsg_size=0"

# The diagnostic needs a boot console that survives until the SMMU checkpoint.
# The collector must NOT keep EFIFB as a boot console: doing so can conflict with
# the normal DT framebuffer/DRM handoff. Use a conventional tty0 console and a
# text-only userspace target for the recovery side instead.
DIAG_VISIBLE_ARGS="earlycon=efifb,ram keep_bootcon console=tty0 loglevel=8 ignore_loglevel printk.time=1"
COLLECT_VISIBLE_ARGS="console=tty0 loglevel=7 printk.time=1 systemd.unit=multi-user.target"

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

ensure_control_dtb(){
    if [[ -r "$DTB" ]]; then
        return
    fi

    # Safe recovery when the known-good capture was not retained: only capture
    # from a currently running DT boot, never fabricate a hardware tree.
    [[ -r /sys/firmware/fdt && -d /proc/device-tree ]] || \
        die "missing $DTB; boot known-good DT Linux once so it can be captured"
    mkdir -p "$DTDIR"
    cp --reflink=auto --sparse=always /sys/firmware/fdt "$DTB"
    chmod 0644 "$DTB"
    sync "$DTB"
}

install_entry(){
    need_root
    valid_stage || {
        echo "Valid stages:" >&2
        print_stages >&2
        die "unknown checkpoint stage: $STAGE"
    }
    [[ "$REBOOT_DELAY_MS" =~ ^[0-9]+$ ]] || die "A14_ACPI_REBOOT_DELAY_MS must be an integer number of milliseconds"
    (( REBOOT_DELAY_MS <= 60000 )) || die "A14_ACPI_REBOOT_DELAY_MS must be <= 60000"

    for c in grub-probe grub-mkrelpath update-grub sha256sum; do need "$c"; done
    [[ -r "$KERNEL" ]] || die "missing $KERNEL"
    [[ -r "$INITRD" ]] || die "missing $INITRD"
    [[ -r "$CONFIG" ]] || die "missing $CONFIG"
    grep -q '^CONFIG_PSTORE_RAM=y$' "$CONFIG" || die "experimental kernel lacks built-in ramoops"
    grep -q '^CONFIG_PSTORE_CONSOLE=y$' "$CONFIG" || die "experimental kernel lacks pstore console logging"
    grep -q '^CONFIG_EFI_EARLYCON=y$' "$CONFIG" || die "experimental kernel lacks EFI framebuffer earlycon"
    ensure_control_dtb

    uuid="$(grub-probe --target=fs_uuid "$KERNEL")"
    kp="$(grub-mkrelpath "$KERNEL")"
    ip="$(grub-mkrelpath "$INITRD")"
    dp="$(grub-mkrelpath "$DTB")"

    args=()
    for arg in $(cat /proc/cmdline); do
        case "$arg" in
            BOOT_IMAGE=*|initrd=*|acpi=*|panic=*|oops=*|quiet|splash|break=*|debug|debug=*|loglevel=*|earlycon=*|console=*|ignore_loglevel|initcall_debug|keep_bootcon|a14_acpi_halt=*|a14_acpi_reboot_delay_ms=*|a14_device_halt_after=*|initcall_blacklist=*|reserve_mem=*|ramoops.*|nokaslr|systemd.unit=*)
                ;;
            *) args+=("$arg") ;;
        esac
    done

    common="${args[*]} nokaslr $RAMOOPS_RESERVE $RAMOOPS_ARGS"
    diag_cmdline="$common $DIAG_VISIBLE_ARGS acpi=force a14_acpi_halt=$STAGE a14_acpi_reboot_delay_ms=$REBOOT_DELAY_MS"
    collect_cmdline="$common $COLLECT_VISIBLE_ARGS acpi=off"
    diag_entry="ASUS Zenbook A14 — ACPI CHECKPOINT+LOG: $STAGE ($KREL)"
    collect_entry="ASUS Zenbook A14 — PSTORE COLLECTOR — SAME KERNEL + KNOWN-GOOD DT ($KREL)"

    rm -f "$OLD_MOUNTROOT"
    cat > "$SNIPPET" <<EOF
#!/bin/sh
exec tail -n +3 \$0
# Temporary A14 full-ACPI diagnostic pair.
# 1) ACPI-only diagnostic: visible EFI framebuffer earlycon + persistent ramoops.
#    Before Linux starts, arm the collector as GRUB's one-shot next_entry. Thus
#    either our timed emergency restart or an earlier firmware reset goes to
#    the collector rather than ordinary Ubuntu.
menuentry '$diag_entry' --id '$DIAG_ID' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root $uuid
    set next_entry='$COLLECT_ID'
    save_env next_entry
    linux $kp $diag_cmdline
    initrd $ip
}

# 2) Same experimental Image/initrd, but known-good live DT and ACPI disabled.
# Deliberately do not use earlycon=efifb or keep_bootcon here: the collector
# should follow the normal DT console/DRM handoff and stop at multi-user.target.
# next_entry is one-shot, so after this collector boot normal GRUB behavior resumes.
menuentry '$collect_entry' --id '$COLLECT_ID' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root $uuid
    linux $kp $collect_cmdline
    devicetree $dp
    initrd $ip
}
EOF
    chmod 0755 "$SNIPPET"

    diag_linux="$(awk '/^menuentry .*CHECKPOINT\+LOG/{seen=1} seen && /^[[:space:]]*linux[[:space:]]/{print; exit}' "$SNIPPET")"
    collect_linux="$(awk '/^menuentry .*PSTORE COLLECTOR/{seen=1} seen && /^[[:space:]]*linux[[:space:]]/{print; exit}' "$SNIPPET")"
    [[ -n "$diag_linux" && -n "$collect_linux" ]] || die "failed to validate generated diagnostic pair"
    grep -q 'acpi=force' <<<"$diag_linux" || die "diagnostic lacks acpi=force"
    grep -q "a14_acpi_halt=$STAGE" <<<"$diag_linux" || die "diagnostic checkpoint argument missing"
    grep -q "a14_acpi_reboot_delay_ms=$REBOOT_DELAY_MS" <<<"$diag_linux" || die "timed reboot argument missing"
    grep -q 'earlycon=efifb,ram' <<<"$diag_linux" || die "diagnostic EFI framebuffer earlycon missing"
    grep -q 'keep_bootcon' <<<"$diag_linux" || die "diagnostic keep_bootcon missing"
    ! grep -qE '^[[:space:]]*devicetree[[:space:]]' <<<"$(sed -n "/CHECKPOINT+LOG/,/PSTORE COLLECTOR/p" "$SNIPPET")" || die "diagnostic unexpectedly loads a devicetree"

    grep -q 'acpi=off' <<<"$collect_linux" || die "collector lacks acpi=off"
    grep -q 'systemd.unit=multi-user.target' <<<"$collect_linux" || die "collector is not text-only"
    ! grep -q 'earlycon=' <<<"$collect_linux" || die "collector unexpectedly keeps an early console"
    ! grep -q 'keep_bootcon' <<<"$collect_linux" || die "collector unexpectedly keeps boot console alive"
    grep -qE '^[[:space:]]*devicetree[[:space:]]' "$SNIPPET" || die "collector lacks devicetree"

    grep -q -- "--id '$DIAG_ID'" "$SNIPPET" || die "diagnostic GRUB id missing"
    grep -q -- "--id '$COLLECT_ID'" "$SNIPPET" || die "collector GRUB id missing"
    grep -q "set next_entry='$COLLECT_ID'" "$SNIPPET" || die "collector one-shot next_entry is not armed"
    grep -q 'save_env next_entry' "$SNIPPET" || die "GRUB next_entry is not persisted"

    for line in "$diag_linux" "$collect_linux"; do
        grep -q "$RAMOOPS_RESERVE" <<<"$line" || die "reserve_mem logging region missing"
        grep -q 'ramoops.mem_name=a14log' <<<"$line" || die "ramoops mem_name missing"
        grep -q 'nokaslr' <<<"$line" || die "diagnostic RAM layout is not deterministic"
        if grep -qE '(^|[[:space:]])panic=' <<<"$line"; then
            die "panic argument unexpectedly present"
        fi
        if grep -qE '(^|[[:space:]])initcall_blacklist=' <<<"$line"; then
            die "stale initcall blacklist unexpectedly present"
        fi
    done

    update-grub
    echo "A14_FULL_ACPI_CHECKPOINT_ENTRY=READY"
    echo "stage=$STAGE"
    echo "diagnostic_entry=$diag_entry"
    echo "collector_entry=$collect_entry"
    echo "diagnostic_grub_id=$DIAG_ID"
    echo "collector_grub_id=$COLLECT_ID"
    echo "checkpoint_reboot_delay_ms=$REBOOT_DELAY_MS"
    echo "checkpoint_exit=emergency_restart"
    echo "collector_next_boot=armed-by-diagnostic-grub-entry"
    echo "diagnostic_hardware_dtb_loaded=false"
    echo "collector_hardware_dtb_loaded=true"
    echo "collector_dtb=$DTB"
    echo "collector_dtb_sha256=$(sha256sum "$DTB" | awk '{print $1}')"
    echo "diagnostic_efifb_earlycon=enabled"
    echo "collector_efifb_earlycon=disabled"
    echo "collector_keep_bootcon=disabled"
    echo "collector_userspace_target=multi-user.target"
    echo "persistent_console=ramoops"
    echo "reserve_mem=2M:1M:a14log"
    echo "nokaslr=diagnostic-pair-only"
    echo "normal_kernel_untouched=true"
    echo "custom_checkpoint_entries=2"
    echo
    echo "Boot the ACPI CHECKPOINT+LOG entry once. If it resets, let GRUB continue: the PSTORE COLLECTOR is armed as the one-shot next boot."
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
