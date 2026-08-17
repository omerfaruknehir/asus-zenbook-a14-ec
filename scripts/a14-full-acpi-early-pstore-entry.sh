#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Create one ACPI diagnostic entry plus an automatic early ramoops collector.
set -euo pipefail

STAGE="${1:-}"
KREL="7.1.5-a14-acpi-full0"
KERNEL="/boot/vmlinuz-$KREL"
INITRD="/boot/initrd.img-$KREL"
DTB="/boot/a14-full-acpi-control/known-good-live.dtb"
CONFIG="/boot/config-$KREL"
SNIPPET="/etc/grub.d/41_a14_full_acpi_checkpoint"
DIAG_ID="a14-acpi-checkpoint-log"
COLLECT_ID="a14-pstore-collector"
REBOOT_DELAY_MS="${A14_ACPI_REBOOT_DELAY_MS:-5000}"
COLLECT_DELAY_MS="${A14_PSTORE_COLLECT_DELAY_MS:-12000}"
RAMOOPS_RESERVE="reserve_mem=2M:1M:a14log"
RAMOOPS_ARGS="ramoops.mem_name=a14log ramoops.console_size=1048576 ramoops.record_size=262144 ramoops.ftrace_size=0 ramoops.pmsg_size=0"
VISIBLE_ARGS="earlycon=efifb,ram keep_bootcon console=tty0 loglevel=8 ignore_loglevel printk.time=1"

stages=(
    acpi-early-enter acpi-early-after-subsystem acpi-subsystem-enter
    acpi-subsystem-after-enable pci-acpi-enter pci-acpi-after acpi-init-enter
    acpi-bus-done acpi-scan-before acpi-scan-after acpi-init-done
    initcall-subsys-after initcall-fs-after initcall-device-after initcall-late-after
    smmu-init-enter smmu-driver-registered smmu-impl-registered
)
smmu_probe_points=(enter after-fwdata after-ioremap after-impl before-cfg after-cfg before-rmr after-rmr before-reset after-reset after-smr-test)

die(){ echo "ERROR: $*" >&2; exit 1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
valid_stage(){
    local x point
    for x in "${stages[@]}"; do [[ "$STAGE" == "$x" ]] && return 0; done
    if [[ "$STAGE" =~ ^smmu-probe([1-9][0-9]*)-(.+)$ ]]; then
        for point in "${smmu_probe_points[@]}"; do [[ "${BASH_REMATCH[2]}" == "$point" ]] && return 0; done
    fi
    return 1
}

need_root
valid_stage || die "unknown checkpoint stage: $STAGE"
[[ "$REBOOT_DELAY_MS" =~ ^[0-9]+$ && "$COLLECT_DELAY_MS" =~ ^[0-9]+$ ]] || die "delays must be integer milliseconds"
(( REBOOT_DELAY_MS <= 60000 && COLLECT_DELAY_MS <= 60000 )) || die "delays must be <= 60000 ms"
for c in grub-probe grub-mkrelpath update-grub sha256sum; do need "$c"; done
[[ -r "$KERNEL" && -r "$INITRD" && -r "$DTB" && -r "$CONFIG" ]] || die "required experimental kernel/initrd/known-good DT/config missing"
grep -q '^CONFIG_PSTORE_RAM=y$' "$CONFIG" || die "kernel lacks built-in ramoops"
grep -q '^CONFIG_PSTORE_CONSOLE=y$' "$CONFIG" || die "kernel lacks pstore console"
grep -q '^CONFIG_EFI_EARLYCON=y$' "$CONFIG" || die "kernel lacks EFI earlycon"

uuid="$(grub-probe --target=fs_uuid "$KERNEL")"
kp="$(grub-mkrelpath "$KERNEL")"
ip="$(grub-mkrelpath "$INITRD")"
dp="$(grub-mkrelpath "$DTB")"
args=()
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        BOOT_IMAGE=*|initrd=*|acpi=*|panic=*|oops=*|quiet|splash|break=*|debug|debug=*|loglevel=*|earlycon=*|console=*|ignore_loglevel|initcall_debug|keep_bootcon|a14_acpi_halt=*|a14_acpi_reboot_delay_ms=*|a14_device_halt_after=*|initcall_blacklist=*|reserve_mem=*|ramoops.*|nokaslr|systemd.unit=*) ;;
        *) args+=("$arg") ;;
    esac
done

common="${args[*]} nokaslr $RAMOOPS_RESERVE $RAMOOPS_ARGS $VISIBLE_ARGS"
diag_cmdline="$common acpi=force a14_acpi_halt=$STAGE a14_acpi_reboot_delay_ms=$REBOOT_DELAY_MS"
collect_cmdline="$common acpi=off ramoops.a14_collector=1 ramoops.a14_collector_delay_ms=$COLLECT_DELAY_MS"
diag_entry="ASUS Zenbook A14 — ACPI CHECKPOINT+LOG: $STAGE ($KREL)"
collect_entry="ASUS Zenbook A14 — EARLY PSTORE ECHO COLLECTOR ($KREL)"

cat > "$SNIPPET" <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry '$diag_entry' --id '$DIAG_ID' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root $uuid
    set next_entry='$COLLECT_ID'
    save_env next_entry
    linux $kp $diag_cmdline
    initrd $ip
}

# Same Image and RAM layout, known-good DT, but collector mode exits from
# ramoops postcore probe before later device-initcall/provider failures.
menuentry '$collect_entry' --id '$COLLECT_ID' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root $uuid
    linux $kp $collect_cmdline
    devicetree $dp
    initrd $ip
}
EOF
chmod 0755 "$SNIPPET"

# Validate the generated pair before touching grub.cfg.
grep -q "a14_acpi_halt=$STAGE" "$SNIPPET" || die "diagnostic checkpoint missing"
grep -q "a14_acpi_reboot_delay_ms=$REBOOT_DELAY_MS" "$SNIPPET" || die "diagnostic timed reboot missing"
grep -q 'ramoops.a14_collector=1' "$SNIPPET" || die "early collector mode missing"
grep -q "ramoops.a14_collector_delay_ms=$COLLECT_DELAY_MS" "$SNIPPET" || die "collector delay missing"
grep -q "set next_entry='$COLLECT_ID'" "$SNIPPET" || die "one-shot collector next_entry missing"
grep -q 'save_env next_entry' "$SNIPPET" || die "next_entry not persisted"
grep -q 'acpi=off' "$SNIPPET" || die "collector lacks acpi=off"
grep -qE '^[[:space:]]*devicetree[[:space:]]' "$SNIPPET" || die "collector lacks known-good DT"

update-grub

echo "A14_FULL_ACPI_EARLY_PSTORE_ENTRY=READY"
echo "stage=$STAGE"
echo "diagnostic_entry=$diag_entry"
echo "collector_entry=$collect_entry"
echo "checkpoint_reboot_delay_ms=$REBOOT_DELAY_MS"
echo "collector_echo_delay_ms=$COLLECT_DELAY_MS"
echo "collector_phase=ramoops-postcore-probe"
echo "collector_attempts_rootfs=false"
echo "collector_next_boot=armed-by-diagnostic-grub-entry"
echo "collector_after_echo=emergency_restart-to-normal-grub"
echo "known_good_dtb_sha256=$(sha256sum "$DTB" | awk '{print $1}')"
echo "normal_kernel_untouched=true"
