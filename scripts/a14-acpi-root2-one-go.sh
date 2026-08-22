#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# ACPI v2.1 ROOT2: extend ROOT1 with controller-owned GPIO-event translation,
# native SCM0/QCOM04DD binding and the observed QCOMEDK2 IORT 0x8380 match.
#
# Safety properties:
#   - no DTB
#   - no initramfs
#   - Image-only incremental build (no modules/modules_install)
#   - direct ext4/NVMe root mount with diagnostic PID 1
#   - prepare ALWAYS leaves GRUB next_entry empty
#   - arm is a separate action
#   - NEVER reboots automatically
set -euo pipefail

ACTION="${1:-prepare}"
KREL="7.1.5-a14-acpi-root2"
LOCALVER="-a14-acpi-root2"
ENTRY="ASUS Zenbook A14 — ACPI ROOT2 GPIO-events+SCM+SMMU ($KREL)"
EVIDENCE_BRANCH="agent/a14-full-acpi"
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
INIT_HELPER="/usr/local/sbin/a14-acpi-root2-init"
SNIPPET="/etc/grub.d/44_a14_acpi_root2"
ROOTLOG="$OWNER_HOME/Downloads/a14-acpi-root2.txt"
ESPLOG_NAME="a14-acpi-root2.txt"
TMP="/run/a14-root2-transforms"
GPIO_XLATE="$ROOT/scripts/apply-a14-acpi-root2-gpio-events.py"

for c in git python3 make sha256sum awk grep sed findmnt blkid lsblk grub-probe grub-mkrelpath update-grub grub-editenv grub-script-check sync du df; do need "$c"; done

unarm(){
    grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true
    say "A14_ACPI_ROOT2_UNARMED=1"
    say "reboot_performed=false"
}

status(){
    say "running_kernel=$(uname -r)"
    say "kernel=$KERNEL"
    [[ -s "$KERNEL" ]] && say "kernel_sha256=$(sha256sum "$KERNEL" | awk '{print $1}')"
    [[ -r "$BOOT_CONFIG" ]] && grep '^CONFIG_LOCALVERSION=' "$BOOT_CONFIG" || true
    [[ -r "$OUT/include/config/kernel.release" ]] && say "generated_kernel_release=$(cat "$OUT/include/config/kernel.release")"
    [[ -x "$INIT_HELPER" ]] && say "init_helper=present" || say "init_helper=absent"
    [[ -r "$SNIPPET" ]] && say "grub_entry=present" || say "grub_entry=absent"
    say "next_entry=$(grub-editenv /boot/grub/grubenv list 2>/dev/null | sed -n 's/^next_entry=//p' | head -n1)"
    [[ -r "$ROOTLOG" ]] && say "report=$ROOTLOG" || true
    say "reboot_performed=false"
}

arm(){
    need grub-reboot
    [[ -s "$KERNEL" ]] || die "ROOT2 kernel is not installed: $KERNEL"
    [[ -x "$INIT_HELPER" ]] || die "ROOT2 PID1 helper missing/not executable: $INIT_HELPER"
    [[ -r "$SNIPPET" ]] || die "ROOT2 GRUB snippet is not installed: $SNIPPET"
    grub-script-check /boot/grub/grub.cfg >/dev/null
    grub-reboot "$ENTRY"
    next="$(grub-editenv /boot/grub/grubenv list | sed -n 's/^next_entry=//p' | head -n1)"
    [[ "$next" == "$ENTRY" ]] || die "failed to arm ROOT2 entry: ${next:-missing}"
    say "A14_ACPI_ROOT2_ARMED=1"
    say "next_entry=$next"
    say "reboot_performed=false"
    say "Reboot manually only when YOU choose: sudo reboot"
}

prepare(){
    case "$(uname -r)" in
        7.1.5-a14-acpi-full0|7.1.5-a14-acpi-root0|7.1.5-a14-acpi-root1|$KREL)
            die "run prepare from the normal DT/rescue kernel" ;;
    esac
    [[ -f "$SRC/Makefile" && -f "$CONFIG" && -s "$IMAGE" && -s "$VMLINUX" ]] || die "ROOT1/root0 build tree missing under $WORK"
    [[ -x "$GPIO_XLATE" || -r "$GPIO_XLATE" ]] || die "missing ROOT2 GPIO transform: $GPIO_XLATE"

    # Never inherit or leave a one-shot experimental boot selection.
    grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true

    root_src="$(findmnt -n -o SOURCE /)"
    root_fs="$(findmnt -n -o FSTYPE /)"
    [[ "$root_src" == /dev/nvme*n*p* ]] || die "root is not a direct NVMe partition: $root_src"
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
    smmuq="$SRC/drivers/iommu/arm/arm-smmu/arm-smmu-qcom.c"
    msm="$SRC/drivers/pinctrl/qcom/pinctrl-msm.c"
    x1="$SRC/drivers/pinctrl/qcom/pinctrl-x1e80100.c"

    # ROOT1 is the prerequisite, not a fresh source tree.
    grep -Fq 'A14_QCOM_WOA_ACPI_GPIO_XLATE' "$acpigpio" || die "ROOT1 WoA GPIO translator missing"
    grep -Fq 'A14_GIO0_SAFE_REGISTRATION_V1' "$msm" || die "ROOT1 GIO0 safe-registration fix missing"
    table="$(awk '/x1e80100_pinctrl_acpi_match\[\]/{f=1} f{print} f && /^};/{exit}' "$x1")"
    grep -Fq 'QCOM0C0C' <<<"$table" || die "ROOT1 GIO0 HID match missing"
    grep -Fq 'QCOMFFEB' <<<"$table" || die "ROOT1 GIO0 CID match missing"
    ! grep -Fq 'QCOM0C0D' <<<"$table" || die "IPC0 QCOM0C0D still incorrectly matches TLMM"

    say "A14_ACPI_ROOT2_STAGE=0 source-and-firmware-transforms"
    say "root_device=$root_src"
    say "root_partuuid=$root_partuuid"
    say "esp_candidates=${esp_candidates_string:-none}"
    say "build_before=$(du -sh "$OUT" 2>/dev/null | awk '{print $1}')"
    df -h "$OWNER_HOME" || true

    # GPIO event translation is maintained on this branch. SCM/SMMU reuse the
    # already-audited historical transforms, copied from one resolved evidence
    # commit without switching/resetting the user's working tree.
    rm -rf "$TMP"; mkdir -p "$TMP"
    sudo -u "$OWNER" git -C "$ROOT" fetch -q origin "$EVIDENCE_BRANCH"
    EVIDENCE_COMMIT="$(sudo -u "$OWNER" git -C "$ROOT" rev-parse FETCH_HEAD)"
    for f in apply-a14-full-acpi-scm-acpi.py apply-a14-full-acpi-smmu-qcom-8380.py; do
        sudo -u "$OWNER" git -C "$ROOT" show "$EVIDENCE_COMMIT:scripts/$f" >"$TMP/$f"
        chmod 0755 "$TMP/$f"
    done

    sudo -u "$OWNER" python3 "$GPIO_XLATE" "$SRC"
    sudo -u "$OWNER" python3 "$TMP/apply-a14-full-acpi-scm-acpi.py" "$SRC"
    sudo -u "$OWNER" python3 "$TMP/apply-a14-full-acpi-smmu-qcom-8380.py" "$SRC"

    grep -Fq 'A14_QCOM_WOA_ACPI_GPIO_EVENT_XLATE' "$acpigpio" || die "ROOT2 GPIO-event transform missing"
    grep -Fq 'event->gpio_pin = gpio_pin' "$acpigpio" || die "ROOT2 physical event pin storage missing"
    grep -Fq 'gpiochip_unlock_as_irq(chip, event->gpio_pin)' "$acpigpio" || die "ROOT2 event teardown still wrong"
    grep -Fq 'A14_QCOM_SCM_ACPI_QCOM04DD' "$scm" || die "ROOT2 SCM ACPI transform missing"
    grep -Fq '"QCOM04DD", 0' "$scm" || die "SCM0 QCOM04DD match missing"
    grep -Fq 'QCOMEDK2", 0x8380' "$smmuq" || die "QCOMEDK2 0x8380 SMMU match missing"

    C="$SRC/scripts/config"
    explicit_y=(
        ACPI EFI EFI_STUB PCI IOMMU_SUPPORT ARM_SMMU ARM_SMMU_V3
        BLK_DEV_NVME EXT4_FS DEVTMPFS DEVTMPFS_MOUNT TMPFS
        QCOM_SCM
        PINCTRL PINCTRL_MSM PINCTRL_X1E80100 GPIOLIB
        I2C I2C_QCOM_GENI HID HID_GENERIC I2C_HID I2C_HID_ACPI
        INPUT INPUT_EVDEV
        FAT_FS VFAT_FS NLS_CODEPAGE_437 NLS_ISO8859_1
    )
    for sym in "${explicit_y[@]}"; do sudo -u "$OWNER" "$C" --file "$CONFIG" --enable "$sym"; done
    sudo -u "$OWNER" "$C" --file "$CONFIG" --set-str LOCALVERSION "$LOCALVER"
    sudo -u "$OWNER" "$C" --file "$CONFIG" --disable LOCALVERSION_AUTO
    sudo -u "$OWNER" "$C" --file "$CONFIG" --disable DEBUG_INFO
    sudo -u "$OWNER" "$C" --file "$CONFIG" --enable DEBUG_INFO_NONE
    sudo -u "$OWNER" "$C" --file "$CONFIG" --disable DEBUG_INFO_BTF

    say "A14_ACPI_ROOT2_STAGE=1 regenerate-release-metadata"
    sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -C "$SRC" O="$OUT" olddefconfig
    grep -Fxq "CONFIG_LOCALVERSION=\"$LOCALVER\"" "$CONFIG" || die "CONFIG_LOCALVERSION did not become $LOCALVER"
    grep -q '^# CONFIG_LOCALVERSION_AUTO is not set$' "$CONFIG" || die "CONFIG_LOCALVERSION_AUTO unexpectedly enabled"
    for sym in ACPI PCI IOMMU_SUPPORT ARM_SMMU BLK_DEV_NVME EXT4_FS QCOM_SCM PINCTRL_X1E80100 I2C_QCOM_GENI HID I2C_HID_ACPI INPUT; do
        grep -q "^CONFIG_${sym}=y$" "$CONFIG" || die "required built-in CONFIG_${sym}=y was not retained"
    done

    rm -f "$OUT/include/config/kernel.release" \
          "$OUT/include/generated/utsrelease.h" \
          "$OUT/include/generated/compile.h"
    sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -C "$SRC" O="$OUT" prepare
    release="$(sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -s -C "$SRC" O="$OUT" kernelrelease)"
    say "kernelrelease_after_regeneration=$release"
    [[ "$release" == "$KREL" ]] || die "kernelrelease mismatch after regeneration: $release"

    say "A14_ACPI_ROOT2_STAGE=2 incremental-Image-only-build"
    say "modules_build=false"
    say "initramfs_build=false"
    rm -f \
      "$OUT/drivers/gpio/gpiolib-acpi-core.o" "$OUT/drivers/gpio/.gpiolib-acpi-core.o.cmd" \
      "$OUT/drivers/firmware/qcom/qcom_scm.o" "$OUT/drivers/firmware/qcom/.qcom_scm.o.cmd" \
      "$OUT/drivers/iommu/arm/arm-smmu/arm-smmu-qcom.o" "$OUT/drivers/iommu/arm/arm-smmu/.arm-smmu-qcom.o.cmd"
    sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" Image
    [[ -s "$IMAGE" && -s "$VMLINUX" ]] || die "ROOT2 Image/vmlinux missing"

    grep -aFq 'A14GIO0FIX: suppressing registration-time eager direction scan' "$VMLINUX" || die "compiled kernel lost ROOT1 GIO0 fix"
    grep -aFq 'QCOM WoA GPIO: virtual' "$VMLINUX" || die "compiled kernel lacks WoA GPIO translator"
    grep -aFq 'QCOM04DD' "$VMLINUX" || die "compiled kernel lacks SCM0 ACPI HID"
    grep -aFq 'A14 ACPI: SCM0 QCOM04DD, DT-only resources skipped' "$VMLINUX" || die "compiled kernel lacks SCM ACPI path"
    grep -aFq 'QCOM SMMU A14' "$VMLINUX" || die "compiled kernel lacks QCOMEDK2 0x8380 SMMU matcher"

    image_sha="$(sha256sum "$IMAGE" | awk '{print $1}')"
    install -m0644 "$IMAGE" "$KERNEL"
    install -m0644 "$CONFIG" "$BOOT_CONFIG"
    rm -f "/boot/initrd.img-$KREL"
    rm -rf "/lib/modules/$KREL"

    say "A14_ACPI_ROOT2_STAGE=3 install-diagnostic-PID1-and-GRUB"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -u'
        printf 'ROOTLOG=%q\n' "$ROOTLOG"
        printf 'ESP_CANDIDATES=%q\n' "$esp_candidates_string"
        printf 'ESPLOGNAME=%q\n' "$ESPLOG_NAME"
        printf 'OWNER_NAME=%q\n' "$OWNER"
    } >"$INIT_HELPER"

    cat >>"$INIT_HELPER" <<'ROOT2_RUNTIME'
PATH=/usr/sbin:/usr/bin:/sbin:/bin
ESPMNT=/run/a14-esp

printf '%s\n' 'A14_ACPI_ROOT2_INIT_ENTERED=1' >"$ROOTLOG"
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
        printf 'A14_ACPI_ROOT2_EFI_MOUNT=PASS device=%s\n' "$d" >>"$ESPLOG"
        sync -f "$ESPLOG" 2>/dev/null || sync
        break
    fi
done
emit(){
    local line="$*"
    printf '%s\n' "$line" >>"$ROOTLOG"
    sync -f "$ROOTLOG" 2>/dev/null || sync
    if [[ -n "$ESPLOG" ]]; then
        printf '%s\n' "$line" >>"$ESPLOG"
        sync -f "$ESPLOG" 2>/dev/null || sync
    fi
}
append_file(){
    local src="$1"
    [[ -r "$src" ]] || return 0
    cat "$src" >>"$ROOTLOG" 2>/dev/null || true
    sync -f "$ROOTLOG" 2>/dev/null || sync
    if [[ -n "$ESPLOG" ]]; then
        cat "$src" >>"$ESPLOG" 2>/dev/null || true
        sync -f "$ESPLOG" 2>/dev/null || sync
    fi
}
append_cmd(){
    local tmp=/run/a14-root2-cap.tmp
    "$@" >"$tmp" 2>&1 || true
    append_file "$tmp"
    rm -f "$tmp"
}

emit 'A14_ACPI_ROOT2_DIRECT_ROOT_MOUNT=PASS'
if [[ -n "$ESPLOG" ]]; then emit 'A14_ACPI_ROOT2_EFI_MIRROR=PASS'; else emit 'A14_ACPI_ROOT2_EFI_MIRROR=FAIL'; fi
emit "kernel=$(uname -a)"
emit "cmdline=$(cat /proc/cmdline 2>/dev/null || true)"
emit "root_mount=$(grep ' / ' /proc/mounts 2>/dev/null || true)"
sleep 5

dmesg >/run/a14-root2-dmesg.txt 2>&1 || true

emit '===== ROOT2 SUMMARY ====='
if grep -q 'A14 ACPI: SCM0 QCOM04DD, DT-only resources skipped' /run/a14-root2-dmesg.txt; then
    emit 'A14_ACPI_ROOT2_SCM0_BIND=PASS'
else
    emit 'A14_ACPI_ROOT2_SCM0_BIND=INCOMPLETE'
fi
if grep -q 'qcom_scm not ready' /run/a14-root2-dmesg.txt; then
    emit 'A14_ACPI_ROOT2_SMMU_SCM_DEPENDENCY=STILL_DEFERRED'
else
    emit 'A14_ACPI_ROOT2_SMMU_SCM_DEPENDENCY=CLEARED'
fi
if grep -Eq 'Failed to request GPIO for pin 0x0?340|Failed to request GPIO for pin 0x0?140' /run/a14-root2-dmesg.txt; then
    emit 'A14_ACPI_ROOT2_GPIO_EVENTS=FAIL'
elif grep -Eq 'QCOM WoA GPIO: virtual 0x(340|140) -> TLMM GPIO' /run/a14-root2-dmesg.txt; then
    emit 'A14_ACPI_ROOT2_GPIO_EVENTS=TRANSLATED'
else
    emit 'A14_ACPI_ROOT2_GPIO_EVENTS=NO_MATCH_IN_LOG'
fi
if grep -qE 'QTEC0001|0B05|ASUS.*Keyboard|Keyboard' /proc/bus/input/devices 2>/dev/null; then
    emit 'A14_ACPI_ROOT2_KEYBOARD_PATH=PASS'
else
    emit 'A14_ACPI_ROOT2_KEYBOARD_PATH=INCOMPLETE'
fi
if compgen -G '/sys/kernel/iommu_groups/*/devices/*' >/dev/null 2>&1; then
    emit 'A14_ACPI_ROOT2_IOMMU_GROUPS=PASS'
else
    emit 'A14_ACPI_ROOT2_IOMMU_GROUPS=INCOMPLETE'
fi

emit '===== SCM0 ACPI/PLATFORM ====='
append_cmd sh -c 'for d in /sys/bus/acpi/devices/QCOM04DD:* /sys/bus/platform/devices/QCOM04DD:*; do [ -e "$d" ] || continue; echo "-- $d"; cat "$d/path" 2>/dev/null; ls -l "$d/driver" "$d/physical_node" 2>&1; done; ls -l /sys/bus/platform/drivers/qcom_scm 2>&1'
emit '===== GIO0 / GPIO ====='
append_cmd sh -c 'for d in /sys/bus/platform/devices/QCOM0C0C:*; do [ -e "$d" ] || continue; echo "-- $d"; ls -l "$d/driver" 2>&1; done; ls -l /sys/bus/gpio/devices /sys/class/gpio 2>&1'
emit '===== IOMMU / SMMU ====='
append_cmd sh -c 'ls -l /sys/bus/platform/drivers/arm-smmu* 2>&1; for g in /sys/kernel/iommu_groups/*; do [ -e "$g" ] || continue; echo "group ${g##*/}"; ls -l "$g/devices" 2>/dev/null; done'
emit '===== PCI / NVME ====='
append_cmd sh -c 'lspci -nnk 2>/dev/null || true; cat /proc/partitions 2>/dev/null || true; ls -l /dev/nvme* 2>/dev/null || true'
emit '===== INPUT ====='
append_file /proc/bus/input/devices
emit '===== INTERRUPTS ====='
append_file /proc/interrupts
emit '===== HIGH SIGNAL DMESG ====='
append_cmd sh -c "grep -Ei 'A14GIO0|QCOM WoA GPIO|QCOM04DD|qcom_scm|QCOM SMMU|arm-smmu|iommu|QCOM0C0C|QCOM0C10|QTEC0001|PNP0C50|tlmm|gpio|geni|i2c|hid|keyboard|irq|acpi|fail|error|timeout' /run/a14-root2-dmesg.txt"
emit '===== FULL DMESG ====='
append_file /run/a14-root2-dmesg.txt
emit 'A14_ACPI_ROOT2_CAPTURE_COMPLETE=1'
chown "$OWNER_NAME:$OWNER_NAME" "$ROOTLOG" 2>/dev/null || true
sync
if [[ -n "$ESPLOG" ]]; then umount "$ESPMNT" 2>/dev/null || true; sync; fi
printf '%s\n' 'ROOT2 capture complete. Automatic reboot is disabled.' >/dev/console 2>/dev/null || true

if [[ -c /dev/tty0 && -x /bin/bash ]]; then
    exec /bin/bash -i </dev/tty0 >/dev/tty0 2>&1
fi
while :; do sleep 60; done
ROOT2_RUNTIME
    chmod 0755 "$INIT_HELPER"
    bash -n "$INIT_HELPER" || die "generated ROOT2 PID1 helper failed bash -n"
    rm -f "$ROOTLOG"

    # Preserve ROOT1 and all distro rescue entries; replace ROOT2 only.
    rm -f "$SNIPPET"
    boot_uuid="$(grub-probe --target=fs_uuid "$KERNEL")"
    kp="$(grub-mkrelpath "$KERNEL")"
    cmdline="root=PARTUUID=$root_partuuid rw rootfstype=ext4 rootwait init=$INIT_HELPER acpi=force earlycon=efifb,ram console=tty0 loglevel=8 ignore_loglevel printk.time=1 panic=30 clk_ignore_unused pd_ignore_unused cma=128M efi=noruntime stubble.dtb_override=false"

    cat >"$SNIPPET" <<EOF
#!/bin/sh
exec tail -n +3 \$0
# ACPI ROOT2. NO DTB. NO initramfs. Does NOT auto-reboot.
menuentry '$ENTRY' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root $boot_uuid
    set gfxpayload=keep
    linux $kp $cmdline
}
EOF
    chmod 0755 "$SNIPPET"
    update-grub
    grub-script-check /boot/grub/grub.cfg >/dev/null
    ! grep -Eq '^[[:space:]]*initrd[[:space:]]' "$SNIPPET" || die "ROOT2 unexpectedly uses initramfs"
    ! grep -Eq '^[[:space:]]*devicetree[[:space:]]' "$SNIPPET" || die "ROOT2 unexpectedly loads a DTB"
    linux_line="$(awk '/^[[:space:]]*linux[[:space:]]/{print; exit}' "$SNIPPET")"
    for req in "root=PARTUUID=$root_partuuid" 'rootfstype=ext4' 'rootwait' "init=$INIT_HELPER" 'acpi=force' 'clk_ignore_unused' 'pd_ignore_unused'; do
        grep -Fq "$req" <<<"$linux_line" || die "ROOT2 line lacks $req"
    done

    # Deliberately leave the next boot UNARMED.
    grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true
    next="$(grub-editenv /boot/grub/grubenv list 2>/dev/null | sed -n 's/^next_entry=//p' | head -n1)"
    [[ -z "$next" ]] || die "prepare unexpectedly left next_entry armed: $next"

    say "A14_ACPI_ROOT2_PREPARE=PASS"
    say "kernelrelease=$KREL"
    say "kernel_sha256=$image_sha"
    say "evidence_commit=$EVIDENCE_COMMIT"
    say "gpio_event_translation=firmware-derived"
    say "scm_acpi_hid=QCOM04DD"
    say "smmu_iort_oem_revision=0x8380"
    say "modules_built=false"
    say "modules_installed=false"
    say "initramfs_used=false"
    say "hardware_dtb_loaded=false"
    say "root_report=$ROOTLOG"
    say "efi_report_name=/$ESPLOG_NAME"
    say "grub_entry=$ENTRY"
    say "next_entry=UNARMED"
    say "reboot_performed=false"
    say "To arm: sudo bash scripts/a14-acpi-root2-one-go.sh arm"
    say "Then reboot manually only when YOU choose: sudo reboot"
}

case "$ACTION" in
    prepare) prepare ;;
    arm) arm ;;
    unarm) unarm ;;
    status) status ;;
    *) die "usage: $0 {prepare|arm|unarm|status}" ;;
esac
