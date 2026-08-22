#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# ACPI v2.1 ROOT1: minimal no-initrd GIO0/TLMM + WoA GpioInt + I2C-HID test.
# IMPORTANT: this script NEVER reboots the machine automatically.
set -euo pipefail

ACTION="${1:-prepare}"
KREL="7.1.5-a14-acpi-root1"
LOCALVER="-a14-acpi-root1"
EVIDENCE_BRANCH="agent/a14-full-acpi-gio0-safe-fix"
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
CONFIG="$OUT/.config"
VMLINUX="$OUT/vmlinux"
KERNEL="/boot/vmlinuz-$KREL"
BOOT_CONFIG="/boot/config-$KREL"
INIT_HELPER="/usr/local/sbin/a14-acpi-root1-init"
SNIPPET="/etc/grub.d/43_a14_acpi_root1"
ENTRY="ASUS Zenbook A14 — ACPI ROOT1 TLMM+keyboard ($KREL)"
ROOTLOG="$OWNER_HOME/Downloads/a14-acpi-root1.txt"
ESPLOG_NAME="a14-acpi-root1.txt"
TMP="/run/a14-root1-transforms"

for c in git python3 make sha256sum awk grep sed findmnt blkid lsblk grub-probe grub-mkrelpath update-grub grub-editenv grub-script-check sync du df; do need "$c"; done

status(){
    say "running_kernel=$(uname -r)"
    say "kernel=$KERNEL"
    [[ -s "$KERNEL" ]] && say "kernel_sha256=$(sha256sum "$KERNEL" | awk '{print $1}')"
    [[ -r "$BOOT_CONFIG" ]] && grep '^CONFIG_LOCALVERSION=' "$BOOT_CONFIG" || true
    [[ -r "$OUT/include/config/kernel.release" ]] && say "generated_kernel_release=$(cat "$OUT/include/config/kernel.release")"
    [[ -r "$SNIPPET" ]] && say "grub_entry=present" || say "grub_entry=absent"
    say "next_entry=$(grub-editenv /boot/grub/grubenv list 2>/dev/null | sed -n 's/^next_entry=//p' | head -n1)"
    [[ -r "$ROOTLOG" ]] && say "report=$ROOTLOG" || true
}

unarm(){
    grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true
    say "A14_ACPI_ROOT1_UNARMED=1"
    say "reboot_performed=false"
}

arm(){
    [[ -s "$KERNEL" ]] || die "ROOT1 kernel is not installed: $KERNEL"
    [[ -r "$SNIPPET" ]] || die "ROOT1 GRUB snippet is not installed: $SNIPPET"
    grub-script-check /boot/grub/grub.cfg >/dev/null
    need grub-reboot
    grub-reboot "$ENTRY"
    next="$(grub-editenv /boot/grub/grubenv list | sed -n 's/^next_entry=//p' | head -n1)"
    [[ "$next" == "$ENTRY" ]] || die "failed to arm ROOT1 entry: ${next:-missing}"
    say "A14_ACPI_ROOT1_ARMED=1"
    say "next_entry=$next"
    say "reboot_performed=false"
    say "When YOU are ready, reboot manually with: sudo reboot"
}

prepare(){
    [[ "$(uname -r)" != 7.1.5-a14-acpi-full0 && "$(uname -r)" != 7.1.5-a14-acpi-root0 && "$(uname -r)" != "$KREL" ]] || die "run prepare from the normal DT/rescue kernel"
    [[ -f "$SRC/Makefile" && -f "$CONFIG" && -s "$IMAGE" ]] || die "compact ROOT0 build tree missing under $WORK"

    # Safety: preparation never leaves a one-shot experimental boot armed.
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

    say "A14_ACPI_ROOT1_STAGE=0 source-state"
    say "root_device=$root_src"
    say "root_partuuid=$root_partuuid"
    say "esp_candidates=${esp_candidates_string:-none}"
    say "build_before=$(du -sh "$OUT" 2>/dev/null | awk '{print $1}')"
    df -h "$OWNER_HOME" || true

    x1="$SRC/drivers/pinctrl/qcom/pinctrl-x1e80100.c"
    msm="$SRC/drivers/pinctrl/qcom/pinctrl-msm.c"
    acpigpio="$SRC/drivers/gpio/gpiolib-acpi-core.c"

    # The user's first ROOT1 attempt already applied these transforms before
    # failing at kernelrelease. Re-running the old V1 transform after SAFE was
    # layered can fail on changed anchors, so detect the final state and skip.
    if grep -Fq 'A14_GIO0_PROBE_TRACE_V1' "$msm" && \
       grep -Fq 'A14_GIO0_PROBE_TRACE_V2' "$msm" && \
       grep -Fq 'A14_GIO0_SAFE_REGISTRATION_V1' "$msm" && \
       grep -Fq 'A14_QCOM_WOA_ACPI_GPIO_XLATE' "$acpigpio"; then
        say "gio0_transform_state=already-complete"
        EVIDENCE_COMMIT="existing-source-state"
    else
        say "gio0_transform_state=applying"
        rm -rf "$TMP"; mkdir -p "$TMP"
        sudo -u "$OWNER" git -C "$ROOT" fetch -q origin "$EVIDENCE_BRANCH"
        EVIDENCE_COMMIT="$(sudo -u "$OWNER" git -C "$ROOT" rev-parse FETCH_HEAD)"
        for f in \
            apply-a14-74c9-gio0-probe.py \
            apply-a14-74c9-gio0-probe-v2.py \
            apply-a14-full-acpi-woa-gpio-xlate.py \
            apply-a14-74c9-gio0-safe-registration.py; do
            sudo -u "$OWNER" git -C "$ROOT" show "$EVIDENCE_COMMIT:scripts/$f" >"$TMP/$f"
            chmod 0755 "$TMP/$f"
        done
        sudo -u "$OWNER" python3 "$TMP/apply-a14-74c9-gio0-probe.py" "$SRC"
        sudo -u "$OWNER" python3 "$TMP/apply-a14-74c9-gio0-probe-v2.py" "$SRC"
        sudo -u "$OWNER" python3 "$TMP/apply-a14-full-acpi-woa-gpio-xlate.py" "$SRC"
        sudo -u "$OWNER" python3 "$TMP/apply-a14-74c9-gio0-safe-registration.py" "$SRC"
    fi

    table="$(awk '/x1e80100_pinctrl_acpi_match\[\]/{f=1} f{print} f && /^};/{exit}' "$x1")"
    grep -Fq 'QCOM0C0C' <<<"$table" || die "GIO0 HID QCOM0C0C missing from TLMM match"
    grep -Fq 'QCOMFFEB' <<<"$table" || die "GIO0 CID QCOMFFEB missing from TLMM match"
    ! grep -Fq 'QCOM0C0D' <<<"$table" || die "IPC0 QCOM0C0D still incorrectly matches TLMM"
    grep -Fq 'pctrl->chip.get_direction = NULL' "$msm" || die "registration scan suppression missing"
    grep -Fq 'pctrl->chip.get_direction = a14_saved_get_direction' "$msm" || die "runtime direction restore missing"
    grep -Fq 'qcom_woa_pdc_dsm_guid' "$acpigpio" || die "PDC DSM translator missing"

    C="$SRC/scripts/config"
    explicit_y=(
        ACPI PCI IOMMU_SUPPORT ARM_SMMU ARM_SMMU_V3 BLK_DEV_NVME EXT4_FS
        DEVTMPFS DEVTMPFS_MOUNT TMPFS
        PINCTRL PINCTRL_MSM PINCTRL_X1E80100
        GPIOLIB I2C I2C_QCOM_GENI
        HID HID_GENERIC I2C_HID I2C_HID_ACPI
        INPUT INPUT_EVDEV
        FAT_FS VFAT_FS NLS_CODEPAGE_437 NLS_ISO8859_1
    )
    for sym in "${explicit_y[@]}"; do sudo -u "$OWNER" "$C" --file "$CONFIG" --enable "$sym"; done
    sudo -u "$OWNER" "$C" --file "$CONFIG" --set-str LOCALVERSION "$LOCALVER"
    sudo -u "$OWNER" "$C" --file "$CONFIG" --disable LOCALVERSION_AUTO
    sudo -u "$OWNER" "$C" --file "$CONFIG" --disable DEBUG_INFO
    sudo -u "$OWNER" "$C" --file "$CONFIG" --enable DEBUG_INFO_NONE
    sudo -u "$OWNER" "$C" --file "$CONFIG" --disable DEBUG_INFO_BTF

    say "A14_ACPI_ROOT1_STAGE=1 regenerate-release-metadata"
    sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -C "$SRC" O="$OUT" olddefconfig
    grep -Fxq "CONFIG_LOCALVERSION=\"$LOCALVER\"" "$CONFIG" || {
        grep '^CONFIG_LOCALVERSION' "$CONFIG" || true
        die "CONFIG_LOCALVERSION was not set to $LOCALVER"
    }
    grep -q '^# CONFIG_LOCALVERSION_AUTO is not set$' "$CONFIG" || die "CONFIG_LOCALVERSION_AUTO is not disabled"
    for sym in ACPI PCI BLK_DEV_NVME EXT4_FS PINCTRL_X1E80100 I2C_QCOM_GENI HID I2C_HID_ACPI INPUT; do
        grep -q "^CONFIG_${sym}=y$" "$CONFIG" || die "required built-in CONFIG_${sym}=y was not retained"
    done

    # Reusing ROOT0's O= tree also reuses generated kernel.release/UTS files.
    # Invalidate those explicitly before checking the new release.
    rm -f "$OUT/include/config/kernel.release" \
          "$OUT/include/generated/utsrelease.h" \
          "$OUT/include/generated/compile.h"
    sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -C "$SRC" O="$OUT" prepare
    release="$(sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -s -C "$SRC" O="$OUT" kernelrelease)"
    say "config_localversion=$(grep '^CONFIG_LOCALVERSION=' "$CONFIG")"
    say "kernelrelease_after_regeneration=$release"
    [[ "$release" == "$KREL" ]] || {
        [[ -r "$OUT/include/config/kernel.release" ]] && say "generated_release_file=$(cat "$OUT/include/config/kernel.release")"
        find "$SRC" "$OUT" -maxdepth 1 -type f -name 'localversion*' -print -exec cat {} \; 2>/dev/null || true
        die "kernelrelease mismatch after regeneration: $release"
    }

    say "A14_ACPI_ROOT1_STAGE=2 incremental-Image-only-build"
    say "modules_build=false"
    say "initramfs_build=false"
    rm -f \
      "$OUT/drivers/pinctrl/qcom/pinctrl-x1e80100.o" "$OUT/drivers/pinctrl/qcom/.pinctrl-x1e80100.o.cmd" \
      "$OUT/drivers/pinctrl/qcom/pinctrl-msm.o" "$OUT/drivers/pinctrl/qcom/.pinctrl-msm.o.cmd" \
      "$OUT/drivers/gpio/gpiolib-acpi-core.o" "$OUT/drivers/gpio/.gpiolib-acpi-core.o.cmd"
    sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" Image
    [[ -s "$IMAGE" && -s "$VMLINUX" ]] || die "ROOT1 Image/vmlinux missing"
    image_sha="$(sha256sum "$IMAGE" | awk '{print $1}')"
    grep -aFq 'A14GIO0FIX: suppressing registration-time eager direction scan' "$VMLINUX" || die "compiled kernel lacks GIO0 safe-registration fix"
    grep -aFq 'QCOM WoA GPIO: virtual' "$VMLINUX" || die "compiled kernel lacks WoA GPIO translator"

    install -m0644 "$IMAGE" "$KERNEL"
    install -m0644 "$CONFIG" "$BOOT_CONFIG"
    rm -f "/boot/initrd.img-$KREL"
    rm -rf "/lib/modules/$KREL"

    say "A14_ACPI_ROOT1_STAGE=3 install-capture-PID1"
    say "build_after=$(du -sh "$OUT" | awk '{print $1}')"
    df -h "$OWNER_HOME" || true

    cat >"$INIT_HELPER" <<EOF2
#!/usr/bin/env bash
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin
ROOTLOG='$ROOTLOG'
ESP_CANDIDATES='$esp_candidates_string'
ESPLOGNAME='$ESPLOG_NAME'
ESPMNT=/run/a14-esp

printf '%s\n' 'A14_ACPI_ROOT1_INIT_ENTERED=1' >"\$ROOTLOG"
sync -f "\$ROOTLOG" 2>/dev/null || sync
mkdir -p /proc /sys /dev /run
mountpoint -q /proc 2>/dev/null || mount -t proc proc /proc 2>/dev/null || true
mountpoint -q /sys 2>/dev/null || mount -t sysfs sysfs /sys 2>/dev/null || true
mountpoint -q /dev 2>/dev/null || mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mountpoint -q /run 2>/dev/null || mount -t tmpfs tmpfs /run 2>/dev/null || true
mkdir -p "\$ESPMNT"
ESPLOG=''
for d in \$ESP_CANDIDATES; do
    if mount -t vfat -o rw,sync "\$d" "\$ESPMNT" 2>/dev/null; then
        ESPLOG="\$ESPMNT/\$ESPLOGNAME"
        : >"\$ESPLOG"
        printf 'A14_ACPI_ROOT1_EFI_MOUNT=PASS device=%s\n' "\$d" >>"\$ESPLOG"
        sync -f "\$ESPLOG" 2>/dev/null || sync
        break
    fi
done
emit(){ local line="\$*"; printf '%s\n' "\$line" >>"\$ROOTLOG"; sync -f "\$ROOTLOG" 2>/dev/null || sync; if [[ -n "\$ESPLOG" ]]; then printf '%s\n' "\$line" >>"\$ESPLOG"; sync -f "\$ESPLOG" 2>/dev/null || sync; fi; }
append_file(){ local src="\$1"; [[ -r "\$src" ]] || return 0; cat "\$src" >>"\$ROOTLOG" 2>/dev/null || true; sync -f "\$ROOTLOG" 2>/dev/null || sync; if [[ -n "\$ESPLOG" ]]; then cat "\$src" >>"\$ESPLOG" 2>/dev/null || true; sync -f "\$ESPLOG" 2>/dev/null || sync; fi; }
append_cmd(){ local tmp=/run/a14-cap.tmp; "\$@" >"\$tmp" 2>&1 || true; append_file "\$tmp"; rm -f "\$tmp"; }

emit 'A14_ACPI_ROOT1_DIRECT_ROOT_MOUNT=PASS'
if [[ -n "\$ESPLOG" ]]; then emit 'A14_ACPI_ROOT1_EFI_MIRROR=PASS'; else emit 'A14_ACPI_ROOT1_EFI_MIRROR=FAIL'; fi
emit "kernel=\$(uname -a)"
emit "cmdline=\$(cat /proc/cmdline 2>/dev/null || true)"
emit "root_mount=\$(grep ' / ' /proc/mounts 2>/dev/null || true)"
sleep 3
emit '===== GIO0 TLMM DRIVER ====='
append_cmd sh -c 'for d in /sys/bus/platform/devices/QCOM0C0C:*; do echo "$d"; ls -l "$d/driver" "$d/driver_override" 2>&1; done'
emit '===== GPIO BUS ====='
append_cmd sh -c 'ls -l /sys/bus/gpio/devices /sys/class/gpio 2>&1; for d in /sys/bus/gpio/devices/*; do echo "-- $d"; readlink -f "$d/device" 2>/dev/null; done'
emit '===== KEY ACPI DEVICES ====='
append_cmd sh -c 'for p in QCOM0C0C QCOM0C10 QTEC0001 PNP0C50; do for d in /sys/bus/acpi/devices/$p*; do [ -e "$d" ] || continue; echo "-- $d"; cat "$d/path" 2>/dev/null; ls -l "$d/physical_node" "$d/driver" 2>&1; done; done'
emit '===== I2C DEVICES ====='
append_cmd sh -c 'ls -l /sys/bus/i2c/devices 2>&1; for d in /sys/bus/i2c/devices/*; do [ -e "$d" ] || continue; echo "-- $d"; cat "$d/name" 2>/dev/null; ls -l "$d/driver" 2>&1; done'
emit '===== INPUT DEVICES ====='
append_file /proc/bus/input/devices
emit '===== INTERRUPTS ====='
append_file /proc/interrupts
emit '===== ROOT/NVME ====='
append_file /proc/partitions
emit '===== HIGH SIGNAL DMESG ====='
append_cmd sh -c "dmesg | grep -Ei 'A14GIO0|QCOM WoA GPIO|QCOM0C0C|QCOM0C10|QTEC0001|PNP0C50|tlmm|pinctrl|gpio|geni|i2c|hid|keyboard|irq|acpi|fail|error|timeout'"
emit '===== FULL DMESG ====='
append_cmd dmesg
if grep -qE 'QTEC0001|0B05|ASUS.*Keyboard|Keyboard' /proc/bus/input/devices 2>/dev/null; then emit 'A14_ACPI_ROOT1_KEYBOARD_PATH=PASS'; else emit 'A14_ACPI_ROOT1_KEYBOARD_PATH=INCOMPLETE'; fi
emit 'A14_ACPI_ROOT1_CAPTURE_COMPLETE=1'
chown '$OWNER:$OWNER' "\$ROOTLOG" 2>/dev/null || true
sync
if [[ -n "\$ESPLOG" ]]; then umount "\$ESPMNT" 2>/dev/null || true; sync; fi
printf '%s\n' 'ROOT1 capture complete. Automatic reboot is disabled. Reboot manually when desired.' >/dev/console 2>/dev/null || true
exec /bin/bash -i </dev/tty0 >/dev/tty0 2>&1
while :; do sleep 60; done
EOF2
    chmod 0755 "$INIT_HELPER"

    # Keep normal distro DT entries. Replace only our experimental snippets.
    grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true
    rm -f /etc/grub.d/41_a14_acpi_v2 /etc/grub.d/42_a14_acpi_v2_root_debug \
          /etc/grub.d/41_a14_full_acpi_checkpoint /etc/grub.d/43_a14_acpi_root0 "$SNIPPET"
    rm -f "$ROOTLOG"

    boot_uuid="$(grub-probe --target=fs_uuid "$KERNEL")"
    kp="$(grub-mkrelpath "$KERNEL")"
    cmdline="root=PARTUUID=$root_partuuid rw rootfstype=ext4 rootwait init=$INIT_HELPER acpi=force earlycon=efifb,ram console=tty0 loglevel=8 ignore_loglevel printk.time=1 panic=30 clk_ignore_unused pd_ignore_unused cma=128M efi=noruntime stubble.dtb_override=false"
    cat >"$SNIPPET" <<EOF2
#!/bin/sh
exec tail -n +3 \$0
# ACPI v2.1 ROOT1: GIO0/TLMM + WoA GpioInt + I2C-HID. NO DTB. NO initramfs.
menuentry '$ENTRY' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root $boot_uuid
    set gfxpayload=keep
    linux $kp $cmdline
}
EOF2
    chmod 0755 "$SNIPPET"
    update-grub
    grub-script-check /boot/grub/grub.cfg >/dev/null
    ! grep -Eq '^[[:space:]]*initrd[[:space:]]' "$SNIPPET" || die "ROOT1 unexpectedly uses initramfs"
    ! grep -Eq '^[[:space:]]*devicetree[[:space:]]' "$SNIPPET" || die "ROOT1 unexpectedly loads a DTB"

    # Deliberately leave next_entry empty. User must explicitly run `arm`.
    grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true

    say "A14_ACPI_ROOT1_TLMM_INPUT=PREPARED"
    say "kernelrelease=$KREL"
    say "image_sha256=$image_sha"
    say "evidence_commit=$EVIDENCE_COMMIT"
    say "tlmm_acpi_ids=QCOM0C0C,QCOMFFEB"
    say "ipc0_qcom0c0d_tlmm_match=false"
    say "fatal_gpio44_eager_scan=suppressed-registration-only"
    say "runtime_get_direction=restored"
    say "keyboard_translation=0x0180->GSI_0x253->TLMM_67"
    say "modules_built=false"
    say "initramfs_used=false"
    say "root_report=$ROOTLOG"
    say "efi_report_name=/$ESPLOG_NAME"
    say "next_entry=UNARMED"
    say "reboot_performed=false"
    say "To arm ONE test boot later: sudo bash scripts/a14-acpi-root1-tlmm-input-one-go.sh arm"
    say "Then reboot manually only when you choose: sudo reboot"
}

case "$ACTION" in
    prepare) prepare ;;
    arm) arm ;;
    unarm) unarm ;;
    status) status ;;
    *) die "usage: $0 {prepare|arm|unarm|status}" ;;
esac
