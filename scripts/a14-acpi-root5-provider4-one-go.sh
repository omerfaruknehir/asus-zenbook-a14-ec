#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# ACPI ROOT5: provider-4 protocol-level status-failure shim on ROOT4.
#
# Safety invariants:
#   - Image-only incremental build; no modules/modules_install
#   - no initramfs, no DTB
#   - provider 4 write is accepted only to expose the following read path
#   - provider 4 read returns GSBUS STAT=0xff, no fake battery/power data
#   - prepare always leaves GRUB next_entry empty
#   - arm only sets one-shot GRUB state; never reboots
#   - diagnostic PID1 never reboots; panic=0
set -euo pipefail

ACTION="${1:-prepare}"
KREL="7.1.5-a14-acpi-root5"
LOCALVER="-a14-acpi-root5"
ENTRY="ASUS Zenbook A14 — ACPI ROOT5 ABD-P4 status shim ($KREL)"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
OWNER="${SUDO_USER:-}"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"
[[ -n "$OWNER" && "$OWNER" != root ]] || die "run with sudo from your normal login"
OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
[[ -d "$OWNER_HOME" ]] || die "cannot resolve owner home"

WORK="${A14_74C9_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="$WORK/linux-7.1.5"
OUT="$WORK/root0-build"
IMAGE="$OUT/arch/arm64/boot/Image"
VMLINUX="$OUT/vmlinux"
CONFIG="$OUT/.config"
KERNEL="/boot/vmlinuz-$KREL"
BOOT_CONFIG="/boot/config-$KREL"
INIT_HELPER="/usr/local/sbin/a14-acpi-root5-init"
SNIPPET="/etc/grub.d/47_a14_acpi_root5"
ROOTLOG="$OWNER_HOME/Downloads/a14-acpi-root5.txt"
ESPLOG_NAME="a14-acpi-root5.txt"
TRANSFORM="$ROOT/scripts/apply-a14-acpi-root5-provider4-status.py"

for c in python3 make sha256sum awk grep sed findmnt blkid lsblk grub-probe grub-mkrelpath update-grub grub-editenv grub-script-check sync du df; do need "$c"; done

unarm(){
    grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true
    say "A14_ACPI_ROOT5_UNARMED=1"
    say "reboot_performed=false"
}

status(){
    say "running_kernel=$(uname -r)"
    say "kernel=$KERNEL"
    [[ -s "$KERNEL" ]] && say "kernel_sha256=$(sha256sum "$KERNEL" | awk '{print $1}')"
    [[ -x "$INIT_HELPER" ]] && say "init_helper=present" || say "init_helper=absent"
    [[ -r "$SNIPPET" ]] && say "grub_entry=present" || say "grub_entry=absent"
    say "next_entry=$(grub-editenv /boot/grub/grubenv list 2>/dev/null | sed -n 's/^next_entry=//p' | head -n1)"
    [[ -r "$ROOTLOG" ]] && say "report=$ROOTLOG" || true
    say "reboot_performed=false"
}

arm(){
    need grub-reboot
    [[ -s "$KERNEL" ]] || die "ROOT5 kernel missing: $KERNEL"
    [[ -x "$INIT_HELPER" ]] || die "ROOT5 PID1 helper missing: $INIT_HELPER"
    [[ -r "$SNIPPET" ]] || die "ROOT5 GRUB snippet missing: $SNIPPET"
    grub-script-check /boot/grub/grub.cfg >/dev/null
    grub-reboot "$ENTRY"
    next="$(grub-editenv /boot/grub/grubenv list | sed -n 's/^next_entry=//p' | head -n1)"
    [[ "$next" == "$ENTRY" ]] || die "failed to arm ROOT5: ${next:-missing}"
    say "A14_ACPI_ROOT5_ARMED=1"
    say "next_entry=$next"
    say "reboot_performed=false"
    say "Reboot manually only when YOU choose: sudo reboot"
}

prepare(){
    case "$(uname -r)" in
        7.1.5-a14-acpi-full0|7.1.5-a14-acpi-root0|7.1.5-a14-acpi-root1|7.1.5-a14-acpi-root2|7.1.5-a14-acpi-root3|7.1.5-a14-acpi-root4|$KREL)
            die "run prepare from the normal DT/rescue kernel" ;;
    esac

    [[ -f "$SRC/Makefile" && -f "$CONFIG" && -s "$IMAGE" && -s "$VMLINUX" ]] || die "compact ROOT4 build tree missing under $WORK"
    [[ -r "$TRANSFORM" ]] || die "missing ROOT5 transformer: $TRANSFORM"

    grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true

    root_src="$(findmnt -n -o SOURCE /)"
    root_fs="$(findmnt -n -o FSTYPE /)"
    [[ "$root_src" == /dev/nvme*n*p* ]] || die "root is not direct NVMe: $root_src"
    [[ "$root_fs" == ext4 ]] || die "root is not ext4: $root_fs"
    root_partuuid="$(blkid -s PARTUUID -o value "$root_src")"
    [[ -n "$root_partuuid" ]] || die "cannot resolve root PARTUUID"
    root_parent="/dev/$(lsblk -no PKNAME "$root_src" | head -n1)"
    [[ -b "$root_parent" ]] || die "cannot resolve root NVMe parent"

    ESP_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
    esp_candidates=()
    while read -r dev parttype; do
        [[ -n "$dev" ]] || continue
        [[ "${parttype,,}" == "$ESP_GUID" ]] || continue
        esp_candidates+=("$dev")
    done < <(lsblk -rpn -o NAME,PARTTYPE "$root_parent" 2>/dev/null || true)
    esp_candidates_string="${esp_candidates[*]:-}"

    abd="$SRC/drivers/acpi/arm64/qcom_abd.c"
    sosi="$SRC/drivers/acpi/arm64/qcom_sosi_probe.c"
    grep -Fq 'A14_QCOM_ABD_PROVIDER4_TRACE_V2' "$abd" || die "ROOT4 provider-4 trace baseline missing"
    grep -Fq 'A14_QCOM_SOSI_READONLY_PROBE_V2' "$sosi" || die "ROOT4 SOSI V2 baseline missing"
    grep -Fq 'A14_QCOM_WOA_ACPI_GPIO_EVENT_XLATE' "$SRC/drivers/gpio/gpiolib-acpi-core.c" || die "ROOT2 GPIO event fix missing"
    grep -Fq 'A14_QCOM_SCM_ACPI_QCOM04DD' "$SRC/drivers/firmware/qcom/qcom_scm.c" || die "ROOT2 SCM fix missing"

    say "A14_ACPI_ROOT5_STAGE=0 apply-provider4-status-shim"
    say "root_device=$root_src"
    say "root_partuuid=$root_partuuid"
    say "esp_candidates=${esp_candidates_string:-none}"
    say "build_before=$(du -sh "$OUT" 2>/dev/null | awk '{print $1}')"
    df -h "$OWNER_HOME" || true

    sudo -u "$OWNER" python3 "$TRANSFORM" "$SRC"
    grep -Fq 'A14_QCOM_ABD_PROVIDER4_STATUS_SHIM_V3' "$abd" || die "ROOT5 provider-4 status shim missing"
    grep -Fq 'write-accepted' "$abd" || die "provider-4 write accept trace missing"
    grep -Fq 'read-status-failure' "$abd" || die "provider-4 read failure trace missing"
    grep -Fq 'provider4_fake_power_data=false' <<<"$(sudo -u "$OWNER" python3 "$TRANSFORM" "$SRC")" || true

    C="$SRC/scripts/config"
    explicit_y=(
        ACPI EFI EFI_STUB PCI IOMMU_SUPPORT ARM_SMMU ARM_SMMU_V3
        BLK_DEV_NVME EXT4_FS DEVTMPFS DEVTMPFS_MOUNT TMPFS
        QCOM_SCM PINCTRL PINCTRL_MSM PINCTRL_X1E80100 GPIOLIB
        I2C I2C_QCOM_GENI HID HID_GENERIC I2C_HID I2C_HID_ACPI
        INPUT INPUT_EVDEV FAT_FS VFAT_FS NLS_CODEPAGE_437 NLS_ISO8859_1
    )
    for sym in "${explicit_y[@]}"; do sudo -u "$OWNER" "$C" --file "$CONFIG" --enable "$sym"; done
    sudo -u "$OWNER" "$C" --file "$CONFIG" --set-str LOCALVERSION "$LOCALVER"
    sudo -u "$OWNER" "$C" --file "$CONFIG" --disable LOCALVERSION_AUTO
    sudo -u "$OWNER" "$C" --file "$CONFIG" --disable DEBUG_INFO
    sudo -u "$OWNER" "$C" --file "$CONFIG" --enable DEBUG_INFO_NONE
    sudo -u "$OWNER" "$C" --file "$CONFIG" --disable DEBUG_INFO_BTF

    say "A14_ACPI_ROOT5_STAGE=1 regenerate-release-metadata"
    sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -C "$SRC" O="$OUT" olddefconfig
    grep -Fxq "CONFIG_LOCALVERSION=\"$LOCALVER\"" "$CONFIG" || die "CONFIG_LOCALVERSION mismatch"
    grep -q '^# CONFIG_LOCALVERSION_AUTO is not set$' "$CONFIG" || die "CONFIG_LOCALVERSION_AUTO unexpectedly enabled"
    rm -f "$OUT/include/config/kernel.release" "$OUT/include/generated/utsrelease.h" "$OUT/include/generated/compile.h"
    sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -C "$SRC" O="$OUT" prepare
    release="$(sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -s -C "$SRC" O="$OUT" kernelrelease)"
    say "kernelrelease_after_regeneration=$release"
    [[ "$release" == "$KREL" ]] || die "kernelrelease mismatch: $release"

    say "A14_ACPI_ROOT5_STAGE=2 incremental-Image-only-build"
    say "modules_build=false"
    say "initramfs_build=false"
    rm -f "$OUT/drivers/acpi/arm64/qcom_abd.o" "$OUT/drivers/acpi/arm64/.qcom_abd.o.cmd"
    sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" Image
    [[ -s "$IMAGE" && -s "$VMLINUX" ]] || die "ROOT5 Image/vmlinux missing"
    grep -aFq 'A14 ABD P4: write-accepted' "$VMLINUX" || die "compiled kernel lacks write-accepted trace"
    grep -aFq 'A14 ABD P4: read-status-failure' "$VMLINUX" || die "compiled kernel lacks read-status-failure trace"
    grep -aFq 'A14 SOSI: ACPI \_SB.SOSI=' "$VMLINUX" || die "compiled kernel lost SOSI probe"

    image_sha="$(sha256sum "$IMAGE" | awk '{print $1}')"
    install -m0644 "$IMAGE" "$KERNEL"
    install -m0644 "$CONFIG" "$BOOT_CONFIG"
    rm -f "/boot/initrd.img-$KREL"
    rm -rf "/lib/modules/$KREL"

    say "A14_ACPI_ROOT5_STAGE=3 install-diagnostic-PID1-and-GRUB"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -u'
        printf 'ROOTLOG=%q\n' "$ROOTLOG"
        printf 'ESP_CANDIDATES=%q\n' "$esp_candidates_string"
        printf 'ESPLOGNAME=%q\n' "$ESPLOG_NAME"
    } >"$INIT_HELPER"

    cat >>"$INIT_HELPER" <<'ROOT5_RUNTIME'
PATH=/usr/sbin:/usr/bin:/sbin:/bin
ESPMNT=/run/a14-esp
printf '%s\n' 'A14_ACPI_ROOT5_INIT_ENTERED=1' >"$ROOTLOG"
sync -f "$ROOTLOG" 2>/dev/null || sync
mkdir -p /proc /sys /dev /run
mountpoint -q /proc 2>/dev/null || mount -t proc proc /proc 2>/dev/null || true
mountpoint -q /sys 2>/dev/null || mount -t sysfs sysfs /sys 2>/dev/null || true
mountpoint -q /dev 2>/dev/null || mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mountpoint -q /run 2>/dev/null || mount -t tmpfs tmpfs /run 2>/dev/null || true
mkdir -p "$ESPMNT"
ESPLOG=''
for d in $ESP_CANDIDATES; do
    if mount -t vfat -o rw,sync "$d" "$ESPMNT" 2>/dev/null; then
        ESPLOG="$ESPMNT/$ESPLOGNAME"
        : >"$ESPLOG"
        printf 'A14_ACPI_ROOT5_EFI_MOUNT=PASS device=%s\n' "$d" >>"$ESPLOG"
        sync -f "$ESPLOG" 2>/dev/null || sync
        break
    fi
done
emit(){
    printf '%s\n' "$*" >>"$ROOTLOG"
    sync -f "$ROOTLOG" 2>/dev/null || sync
    if [[ -n "$ESPLOG" ]]; then printf '%s\n' "$*" >>"$ESPLOG"; sync -f "$ESPLOG" 2>/dev/null || sync; fi
}
append_file(){
    [[ -r "$1" ]] || return 0
    cat "$1" >>"$ROOTLOG" 2>/dev/null || true
    if [[ -n "$ESPLOG" ]]; then cat "$1" >>"$ESPLOG" 2>/dev/null || true; fi
    sync
}

emit 'A14_ACPI_ROOT5_DIRECT_ROOT_MOUNT=PASS'
if [[ -n "$ESPLOG" ]]; then emit 'A14_ACPI_ROOT5_EFI_MIRROR=PASS'; else emit 'A14_ACPI_ROOT5_EFI_MIRROR=FAIL'; fi
emit "kernel=$(uname -a)"
emit "cmdline=$(cat /proc/cmdline 2>/dev/null || true)"
sleep 6
dmesg >/run/a14-root5-dmesg.txt 2>&1 || true

emit '===== ROOT5 SUMMARY ====='
grep -q 'A14 ABD P4: write-accepted' /run/a14-root5-dmesg.txt && emit 'A14_ACPI_ROOT5_PROVIDER4_WRITE=PASS' || emit 'A14_ACPI_ROOT5_PROVIDER4_WRITE=NO_REQUEST_SEEN'
grep -q 'A14 ABD P4: read-status-failure' /run/a14-root5-dmesg.txt && emit 'A14_ACPI_ROOT5_PROVIDER4_READ=PASS' || emit 'A14_ACPI_ROOT5_PROVIDER4_READ=NO_REQUEST_SEEN'
grep -q 'AE_SUPPORT, Returned by Handler for \[GenericSerialBus\]' /run/a14-root5-dmesg.txt && emit 'A14_ACPI_ROOT5_GSBUS_AE_SUPPORT=STILL_PRESENT' || emit 'A14_ACPI_ROOT5_GSBUS_AE_SUPPORT=CLEARED'
grep -q 'A14 SOSI: ACPI \\_SB.SOSI=' /run/a14-root5-dmesg.txt && emit 'A14_ACPI_ROOT5_SOSI=PASS' || emit 'A14_ACPI_ROOT5_SOSI=INCOMPLETE'
grep -q 'qcom_scm: convention: smc arm 64' /run/a14-root5-dmesg.txt && emit 'A14_ACPI_ROOT5_SCM0=PASS' || emit 'A14_ACPI_ROOT5_SCM0=INCOMPLETE'
grep -q 'arm-smmu.1.auto:.*preserved 0 boot mappings' /run/a14-root5-dmesg.txt && emit 'A14_ACPI_ROOT5_SMMU=PASS' || emit 'A14_ACPI_ROOT5_SMMU=INCOMPLETE'
grep -q 'I2C HID v1.00 Keyboard \[QTEC0001:00 0B05:0220\]' /run/a14-root5-dmesg.txt && emit 'A14_ACPI_ROOT5_KEYBOARD=PASS' || emit 'A14_ACPI_ROOT5_KEYBOARD=INCOMPLETE'
emit 'A14_ACPI_ROOT5_PROVIDER4_FAKE_POWER_DATA=false'
emit 'A14_ACPI_ROOT5_PROVIDER4_BACKEND=PROTOCOL_FAILURE_STATUS_ONLY'

emit '===== HIGH SIGNAL ====='
grep -E 'A14 ABD P4|A14 ABD:|A14 SOSI:|GenericSerialBus|PMGK|OEMN|AE_SUPPORT|qcom_scm|arm-smmu|QTEC0001|Keyboard' /run/a14-root5-dmesg.txt >>"$ROOTLOG" 2>/dev/null || true
if [[ -n "$ESPLOG" ]]; then grep -E 'A14 ABD P4|A14 ABD:|A14 SOSI:|GenericSerialBus|PMGK|OEMN|AE_SUPPORT|qcom_scm|arm-smmu|QTEC0001|Keyboard' /run/a14-root5-dmesg.txt >>"$ESPLOG" 2>/dev/null || true; fi
sync
emit '===== /proc/iomem ====='
append_file /proc/iomem
emit '===== INPUT ====='
append_file /proc/bus/input/devices
emit '===== FULL DMESG ====='
append_file /run/a14-root5-dmesg.txt
emit 'A14_ACPI_ROOT5_CAPTURE_COMPLETE=1'
sync
printf '\nROOT5 capture complete. Automatic reboot is disabled.\n' >/dev/tty0 2>/dev/null || true
printf 'Use the internal keyboard and reboot manually when desired.\n' >/dev/tty0 2>/dev/null || true
exec /bin/bash -i </dev/tty0 >/dev/tty0 2>&1
ROOT5_RUNTIME
    chmod 0755 "$INIT_HELPER"
    bash -n "$INIT_HELPER" || die "generated ROOT5 PID1 helper has shell syntax errors"

    boot_uuid="$(grub-probe -t fs_uuid /boot)"
    kernel_path="$(grub-mkrelpath "$KERNEL")"
    [[ -n "$boot_uuid" && -n "$kernel_path" ]] || die "cannot resolve GRUB /boot identity"

    cat >"$SNIPPET" <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry '$ENTRY' {
    search --no-floppy --fs-uuid --set=root '$boot_uuid'
    linux '$kernel_path' root=PARTUUID=$root_partuuid rw rootfstype=ext4 rootwait init=$INIT_HELPER acpi=force earlycon=efifb,ram console=tty0 loglevel=8 ignore_loglevel printk.time=1 panic=0 clk_ignore_unused pd_ignore_unused cma=128M efi=noruntime stubble.dtb_override=false
}
EOF
    chmod 0755 "$SNIPPET"
    update-grub
    grub-script-check /boot/grub/grub.cfg >/dev/null || die "generated grub.cfg failed syntax check"
    grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true
    next="$(grub-editenv /boot/grub/grubenv list 2>/dev/null | sed -n 's/^next_entry=//p' | head -n1)"
    [[ -z "$next" ]] || die "prepare unexpectedly left next_entry armed: $next"

    say "A14_ACPI_ROOT5_PREPARE=PASS"
    say "kernelrelease=$KREL"
    say "kernel_sha256=$image_sha"
    say "provider4_write=accepted_and_recorded"
    say "provider4_read=protocol_failure_status_0xff"
    say "provider4_fake_power_data=false"
    say "provider4_acpica_AE_SUPPORT=false_for_provider4"
    say "modules_built=false"
    say "modules_installed=false"
    say "initramfs_used=false"
    say "hardware_dtb_loaded=false"
    say "panic_auto_reboot=false"
    say "root_report=$ROOTLOG"
    say "efi_report_name=/$ESPLOG_NAME"
    say "grub_entry=$ENTRY"
    say "next_entry=UNARMED"
    say "reboot_performed=false"
    say "To arm: sudo bash scripts/a14-acpi-root5-provider4-one-go.sh arm"
}

case "$ACTION" in
    prepare) prepare ;;
    arm) arm ;;
    unarm) unarm ;;
    status) status ;;
    *) die "usage: $0 [prepare|arm|unarm|status]" ;;
esac
