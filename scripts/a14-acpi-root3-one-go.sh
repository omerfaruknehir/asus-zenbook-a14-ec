#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# ACPI ROOT3: add trace-only Qualcomm ABD/QCOM0427 GenericSerialBus handler
# on top of the proven ROOT2 base.
#
# Safety:
#   - Image-only incremental build
#   - no modules/modules_install
#   - no initramfs/Dracut
#   - no DTB
#   - prepare always leaves next_entry empty
#   - arm is explicit and never reboots
#   - test PID1 never auto-reboots
set -euo pipefail

ACTION="${1:-prepare}"
KREL="7.1.5-a14-acpi-root3"
LOCALVER="-a14-acpi-root3"
ENTRY="ASUS Zenbook A14 — ACPI ROOT3 ABD trace ($KREL)"
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
INIT_HELPER="/usr/local/sbin/a14-acpi-root3-init"
SNIPPET="/etc/grub.d/45_a14_acpi_root3"
ROOTLOG="$OWNER_HOME/Downloads/a14-acpi-root3.txt"
ESPLOG_NAME="a14-acpi-root3.txt"
ABD_XFORM="$ROOT/scripts/apply-a14-acpi-root3-abd.py"

for c in python3 make sha256sum awk grep sed findmnt blkid lsblk grub-probe grub-mkrelpath update-grub grub-editenv grub-script-check sync du df; do need "$c"; done

unarm(){
    grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true
    say "A14_ACPI_ROOT3_UNARMED=1"
    say "reboot_performed=false"
}

status(){
    say "running_kernel=$(uname -r)"
    say "kernel=$KERNEL"
    [[ -s "$KERNEL" ]] && say "kernel_sha256=$(sha256sum "$KERNEL" | awk '{print $1}')"
    [[ -r "$BOOT_CONFIG" ]] && grep '^CONFIG_LOCALVERSION=' "$BOOT_CONFIG" || true
    [[ -x "$INIT_HELPER" ]] && say "init_helper=present" || say "init_helper=absent"
    [[ -r "$SNIPPET" ]] && say "grub_entry=present" || say "grub_entry=absent"
    say "next_entry=$(grub-editenv /boot/grub/grubenv list 2>/dev/null | sed -n 's/^next_entry=//p' | head -n1)"
    [[ -r "$ROOTLOG" ]] && say "report=$ROOTLOG" || true
    say "reboot_performed=false"
}

arm(){
    need grub-reboot
    [[ -s "$KERNEL" ]] || die "ROOT3 kernel is not installed: $KERNEL"
    [[ -x "$INIT_HELPER" ]] || die "ROOT3 PID1 helper missing/not executable: $INIT_HELPER"
    [[ -r "$SNIPPET" ]] || die "ROOT3 GRUB snippet missing: $SNIPPET"
    grub-script-check /boot/grub/grub.cfg >/dev/null
    grub-reboot "$ENTRY"
    next="$(grub-editenv /boot/grub/grubenv list | sed -n 's/^next_entry=//p' | head -n1)"
    [[ "$next" == "$ENTRY" ]] || die "failed to arm ROOT3 entry: ${next:-missing}"
    say "A14_ACPI_ROOT3_ARMED=1"
    say "next_entry=$next"
    say "reboot_performed=false"
    say "Reboot manually only when YOU choose: sudo reboot"
}

prepare(){
    case "$(uname -r)" in
        7.1.5-a14-acpi-full0|7.1.5-a14-acpi-root0|7.1.5-a14-acpi-root1|7.1.5-a14-acpi-root2|$KREL)
            die "run prepare from the normal DT/rescue kernel" ;;
    esac

    [[ -f "$SRC/Makefile" && -f "$CONFIG" && -s "$IMAGE" && -s "$VMLINUX" ]] || die "ROOT2/root0 build tree missing under $WORK"
    [[ -r "$ABD_XFORM" ]] || die "missing ROOT3 ABD transform: $ABD_XFORM"

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

    acpigpio="$SRC/drivers/gpio/gpiolib-acpi-core.c"
    scm="$SRC/drivers/firmware/qcom/qcom_scm.c"
    smmu="$SRC/drivers/iommu/arm/arm-smmu/arm-smmu-qcom.c"
    x1="$SRC/drivers/pinctrl/qcom/pinctrl-x1e80100.c"
    msm="$SRC/drivers/pinctrl/qcom/pinctrl-msm.c"
    grep -Fq 'A14_QCOM_WOA_ACPI_GPIO_EVENT_XLATE' "$acpigpio" || die "ROOT2 GPIO event fix missing"
    grep -Fq 'A14_QCOM_SCM_ACPI_QCOM04DD' "$scm" || die "ROOT2 SCM fix missing"
    grep -Fq 'QCOMEDK2", 0x8380' "$smmu" || die "ROOT2 SMMU match missing"
    grep -Fq 'A14_GIO0_SAFE_REGISTRATION_V1' "$msm" || die "ROOT1 TLMM fix missing"
    grep -Fq 'QCOM0C0C' "$x1" || die "ROOT1 GIO0 match missing"

    say "A14_ACPI_ROOT3_STAGE=0 apply-QCOM0427-ABD-handler"
    say "root_device=$root_src"
    say "root_partuuid=$root_partuuid"
    say "esp_candidates=${esp_candidates_string:-none}"
    say "build_before=$(du -sh "$OUT" 2>/dev/null | awk '{print $1}')"
    df -h "$OWNER_HOME" || true

    sudo -u "$OWNER" python3 "$ABD_XFORM" "$SRC"
    abd="$SRC/drivers/acpi/arm64/qcom_abd.c"
    amk="$SRC/drivers/acpi/arm64/Makefile"
    grep -Fq 'A14_QCOM_ABD_GSBUS_TRACE_V1' "$abd" || die "ROOT3 ABD driver marker missing"
    grep -Fq 'acpi_get_devices("QCOM0427"' "$abd" || die "QCOM0427 enumeration missing"
    grep -Fq 'ACPI_ADR_SPACE_GSBUS' "$abd" || die "GSBUS handler missing"
    grep -Fq 'status = AE_SUPPORT' "$abd" || die "trace-only safety return missing"
    grep -Fq 'qcom_abd.o' "$amk" || die "qcom_abd.o Makefile entry missing"

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

    say "A14_ACPI_ROOT3_STAGE=1 regenerate-release-metadata"
    sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -C "$SRC" O="$OUT" olddefconfig
    grep -Fxq "CONFIG_LOCALVERSION=\"$LOCALVER\"" "$CONFIG" || die "CONFIG_LOCALVERSION did not become $LOCALVER"
    grep -q '^# CONFIG_LOCALVERSION_AUTO is not set$' "$CONFIG" || die "CONFIG_LOCALVERSION_AUTO unexpectedly enabled"

    rm -f "$OUT/include/config/kernel.release" "$OUT/include/generated/utsrelease.h" "$OUT/include/generated/compile.h"
    sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -C "$SRC" O="$OUT" prepare
    release="$(sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -s -C "$SRC" O="$OUT" kernelrelease)"
    say "kernelrelease_after_regeneration=$release"
    [[ "$release" == "$KREL" ]] || die "kernelrelease mismatch: $release"

    say "A14_ACPI_ROOT3_STAGE=2 incremental-Image-only-build"
    say "modules_build=false"
    say "initramfs_build=false"
    rm -f "$OUT/drivers/acpi/arm64/qcom_abd.o" "$OUT/drivers/acpi/arm64/.qcom_abd.o.cmd"
    sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" Image
    [[ -s "$IMAGE" && -s "$VMLINUX" ]] || die "ROOT3 Image/vmlinux missing"

    grep -aFq 'A14 ABD: QCOM0427 GenericSerialBus handler installed (trace-only)' "$VMLINUX" || die "compiled kernel lacks ABD handler"
    grep -aFq 'A14 ABD: request=' "$VMLINUX" || die "compiled kernel lacks ABD request tracing"
    grep -aFq 'A14 ACPI: SCM0 QCOM04DD, DT-only resources skipped' "$VMLINUX" || die "compiled kernel lost ROOT2 SCM"
    grep -aFq 'QCOM WoA GPIO: virtual' "$VMLINUX" || die "compiled kernel lost GPIO translator"
    grep -aFq 'A14GIO0FIX: suppressing registration-time eager direction scan' "$VMLINUX" || die "compiled kernel lost ROOT1 TLMM fix"

    image_sha="$(sha256sum "$IMAGE" | awk '{print $1}')"
    install -m0644 "$IMAGE" "$KERNEL"
    install -m0644 "$CONFIG" "$BOOT_CONFIG"
    rm -f "/boot/initrd.img-$KREL"
    rm -rf "/lib/modules/$KREL"

    say "A14_ACPI_ROOT3_STAGE=3 install-diagnostic-PID1-and-GRUB"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -u'
        printf 'ROOTLOG=%q\n' "$ROOTLOG"
        printf 'ESP_CANDIDATES=%q\n' "$esp_candidates_string"
        printf 'ESPLOGNAME=%q\n' "$ESPLOG_NAME"
        printf 'OWNER_NAME=%q\n' "$OWNER"
    } >"$INIT_HELPER"

    cat >>"$INIT_HELPER" <<'ROOT3_RUNTIME'
PATH=/usr/sbin:/usr/bin:/sbin:/bin
ESPMNT=/run/a14-esp
printf '%s\n' 'A14_ACPI_ROOT3_INIT_ENTERED=1' >"$ROOTLOG"
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
        printf 'A14_ACPI_ROOT3_EFI_MOUNT=PASS device=%s\n' "$d" >>"$ESPLOG"
        sync -f "$ESPLOG" 2>/dev/null || sync
        break
    fi
done
emit(){
    local line="$*"
    printf '%s\n' "$line" >>"$ROOTLOG"
    sync -f "$ROOTLOG" 2>/dev/null || sync
    if [[ -n "$ESPLOG" ]]; then printf '%s\n' "$line" >>"$ESPLOG"; sync -f "$ESPLOG" 2>/dev/null || sync; fi
}
append_file(){
    local src="$1"; [[ -r "$src" ]] || return 0
    cat "$src" >>"$ROOTLOG" 2>/dev/null || true
    if [[ -n "$ESPLOG" ]]; then cat "$src" >>"$ESPLOG" 2>/dev/null || true; fi
    sync
}
append_cmd(){ local tmp=/run/a14-root3-cap.tmp; "$@" >"$tmp" 2>&1 || true; append_file "$tmp"; rm -f "$tmp"; }

emit 'A14_ACPI_ROOT3_DIRECT_ROOT_MOUNT=PASS'
if [[ -n "$ESPLOG" ]]; then emit 'A14_ACPI_ROOT3_EFI_MIRROR=PASS'; else emit 'A14_ACPI_ROOT3_EFI_MIRROR=FAIL'; fi
emit "kernel=$(uname -a)"
emit "cmdline=$(cat /proc/cmdline 2>/dev/null || true)"
sleep 6
dmesg >/run/a14-root3-dmesg.txt 2>&1 || true

emit '===== ROOT3 SUMMARY ====='
if grep -q 'A14 ABD: QCOM0427 GenericSerialBus handler installed (trace-only)' /run/a14-root3-dmesg.txt; then
    emit 'A14_ACPI_ROOT3_ABD_HANDLER=PASS'
else
    emit 'A14_ACPI_ROOT3_ABD_HANDLER=INCOMPLETE'
fi
if grep -q 'A14 ABD: request=' /run/a14-root3-dmesg.txt; then
    emit 'A14_ACPI_ROOT3_ABD_REQUEST_TRACE=PASS'
else
    emit 'A14_ACPI_ROOT3_ABD_REQUEST_TRACE=NO_REQUEST_SEEN'
fi
if grep -q 'No handler for Region \[ROP1\]' /run/a14-root3-dmesg.txt; then
    emit 'A14_ACPI_ROOT3_ROP1_HANDLER_ORDER=EARLY_MISS_PRESENT'
else
    emit 'A14_ACPI_ROOT3_ROP1_NO_HANDLER=CLEARED'
fi
emit 'A14_ACPI_ROOT3_ABD_BACKEND=TRACE_ONLY_AE_SUPPORT'
if grep -q 'A14 ACPI: SCM0 QCOM04DD, DT-only resources skipped' /run/a14-root3-dmesg.txt; then emit 'A14_ACPI_ROOT3_SCM0=PASS'; else emit 'A14_ACPI_ROOT3_SCM0=INCOMPLETE'; fi
if grep -q 'arm-smmu.0.auto: probing hardware configuration' /run/a14-root3-dmesg.txt && grep -q 'arm-smmu.1.auto: probing hardware configuration' /run/a14-root3-dmesg.txt; then emit 'A14_ACPI_ROOT3_SMMU=PASS'; else emit 'A14_ACPI_ROOT3_SMMU=INCOMPLETE'; fi
if grep -qE 'QTEC0001|0B05:0220.*Keyboard' /proc/bus/input/devices 2>/dev/null; then emit 'A14_ACPI_ROOT3_KEYBOARD=PASS'; else emit 'A14_ACPI_ROOT3_KEYBOARD=INCOMPLETE'; fi

emit '===== ABD QCOM0427 ====='
append_cmd sh -c 'for d in /sys/bus/acpi/devices/QCOM0427:* /sys/bus/platform/devices/QCOM0427:*; do [ -e "$d" ] || continue; echo "-- $d"; cat "$d/path" 2>/dev/null; ls -l "$d/driver" "$d/physical_node" 2>&1; done'
emit '===== ABD REQUESTS ====='
append_cmd sh -c "grep -E 'A14 ABD:|ROP1|GenericSerialBus|PRTC|PMGK|QCOM0427' /run/a14-root3-dmesg.txt"
emit '===== ROOT2 REGRESSION SIGNALS ====='
append_cmd sh -c "grep -Ei 'QCOM WoA GPIO|QCOM04DD|qcom_scm|arm-smmu|QTEC0001|Keyboard|x1e80100-tlmm' /run/a14-root3-dmesg.txt"
emit '===== INPUT ====='
append_file /proc/bus/input/devices
emit '===== HIGH SIGNAL DMESG ====='
append_cmd sh -c "grep -Ei 'A14 ABD|QCOM0427|ROP1|GenericSerialBus|PRTC|PMGK|QCOM WoA GPIO|QCOM04DD|qcom_scm|arm-smmu|QTEC0001|keyboard|fail|error|timeout' /run/a14-root3-dmesg.txt"
emit '===== FULL DMESG ====='
append_file /run/a14-root3-dmesg.txt
emit 'A14_ACPI_ROOT3_CAPTURE_COMPLETE=1'
chown "$OWNER_NAME:$OWNER_NAME" "$ROOTLOG" 2>/dev/null || true
sync
if [[ -n "$ESPLOG" ]]; then umount "$ESPMNT" 2>/dev/null || true; sync; fi
printf '%s\n' 'ROOT3 capture complete. Automatic reboot is disabled.' >/dev/console 2>/dev/null || true
if [[ -c /dev/tty0 && -x /bin/bash ]]; then exec /bin/bash -i </dev/tty0 >/dev/tty0 2>&1; fi
while :; do sleep 60; done
ROOT3_RUNTIME
    chmod 0755 "$INIT_HELPER"
    bash -n "$INIT_HELPER" || die "generated ROOT3 PID1 helper failed bash -n"
    rm -f "$ROOTLOG"

    boot_uuid="$(grub-probe --target=fs_uuid "$KERNEL")"
    kp="$(grub-mkrelpath "$KERNEL")"
    cmdline="root=PARTUUID=$root_partuuid rw rootfstype=ext4 rootwait init=$INIT_HELPER acpi=force earlycon=efifb,ram console=tty0 loglevel=8 ignore_loglevel printk.time=1 panic=30 clk_ignore_unused pd_ignore_unused cma=128M efi=noruntime stubble.dtb_override=false"
    cat >"$SNIPPET" <<EOF
#!/bin/sh
exec tail -n +3 \$0
# ACPI ROOT3 ABD trace. NO DTB. NO initramfs. No automatic reboot.
menuentry '$ENTRY' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root $boot_uuid
    set gfxpayload=keep
    linux $kp $cmdline
}
EOF
    chmod 0755 "$SNIPPET"
    update-grub
    grub-script-check /boot/grub/grub.cfg >/dev/null
    ! grep -Eq '^[[:space:]]*initrd[[:space:]]' "$SNIPPET" || die "ROOT3 unexpectedly uses initramfs"
    ! grep -Eq '^[[:space:]]*devicetree[[:space:]]' "$SNIPPET" || die "ROOT3 unexpectedly loads DTB"

    grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true
    next="$(grub-editenv /boot/grub/grubenv list 2>/dev/null | sed -n 's/^next_entry=//p' | head -n1)"
    [[ -z "$next" ]] || die "prepare unexpectedly armed next_entry: $next"

    say "A14_ACPI_ROOT3_PREPARE=PASS"
    say "kernelrelease=$KREL"
    say "kernel_sha256=$image_sha"
    say "abd_acpi_hid=QCOM0427"
    say "abd_address_space=GenericSerialBus"
    say "abd_backend=trace-only-AE_SUPPORT"
    say "fabricated_provider_data=false"
    say "modules_built=false"
    say "modules_installed=false"
    say "initramfs_used=false"
    say "hardware_dtb_loaded=false"
    say "root_report=$ROOTLOG"
    say "efi_report_name=/$ESPLOG_NAME"
    say "grub_entry=$ENTRY"
    say "next_entry=UNARMED"
    say "reboot_performed=false"
    say "To arm: sudo bash scripts/a14-acpi-root3-one-go.sh arm"
    say "Then reboot manually only when YOU choose: sudo reboot"
}

case "$ACTION" in
    prepare) prepare ;;
    arm) arm ;;
    unarm) unarm ;;
    status) status ;;
    *) die "usage: $0 {prepare|arm|unarm|status}" ;;
esac
