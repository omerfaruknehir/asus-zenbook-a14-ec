#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# ACPI ROOT4: preserve missing ABD provider failures in the GenericSerialBus
# status byte instead of aborting AML, and capture the resulting provider graph.
#
# ROOT4 deliberately builds on the already-proven ROOT3 diagnostic installation.
# Safety invariants:
#   - Image-only incremental build; NEVER make modules/modules_install
#   - no initramfs, no DTB
#   - prepare always leaves GRUB next_entry UNARMED
#   - arm never reboots
#   - diagnostic PID1 never auto-reboots
set -euo pipefail

ACTION="${1:-prepare}"
KREL="7.1.5-a14-acpi-root4"
LOCALVER="-a14-acpi-root4"
ENTRY="ASUS Zenbook A14 — ACPI ROOT4 ABD status-trace ($KREL)"
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
INIT_HELPER="/usr/local/sbin/a14-acpi-root4-init"
ROOT3_INIT="/usr/local/sbin/a14-acpi-root3-init"
SNIPPET="/etc/grub.d/46_a14_acpi_root4"
ROOTLOG="$OWNER_HOME/Downloads/a14-acpi-root4.txt"
ESPLOG_NAME="a14-acpi-root4.txt"
TRANSFORM="$ROOT/scripts/apply-a14-acpi-root4-abd-status-trace.py"

for c in python3 make sha256sum awk grep sed findmnt blkid lsblk grub-probe grub-mkrelpath update-grub grub-editenv grub-script-check sync du df; do need "$c"; done

unarm(){
    grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true
    say "A14_ACPI_ROOT4_UNARMED=1"
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
    [[ -s "$KERNEL" ]] || die "ROOT4 kernel missing: $KERNEL"
    [[ -x "$INIT_HELPER" ]] || die "ROOT4 PID1 helper missing: $INIT_HELPER"
    [[ -r "$SNIPPET" ]] || die "ROOT4 GRUB snippet missing: $SNIPPET"
    grub-script-check /boot/grub/grub.cfg >/dev/null
    grub-reboot "$ENTRY"
    next="$(grub-editenv /boot/grub/grubenv list | sed -n 's/^next_entry=//p' | head -n1)"
    [[ "$next" == "$ENTRY" ]] || die "failed to arm ROOT4: ${next:-missing}"
    say "A14_ACPI_ROOT4_ARMED=1"
    say "next_entry=$next"
    say "reboot_performed=false"
    say "Reboot manually only when YOU choose: sudo reboot"
}

prepare(){
    case "$(uname -r)" in
        7.1.5-a14-acpi-full0|7.1.5-a14-acpi-root0|7.1.5-a14-acpi-root1|7.1.5-a14-acpi-root2|7.1.5-a14-acpi-root3|$KREL)
            die "run prepare from the normal DT/rescue kernel" ;;
    esac

    [[ -f "$SRC/Makefile" && -f "$CONFIG" && -s "$IMAGE" && -s "$VMLINUX" ]] || die "compact ROOT3 build tree missing under $WORK"
    [[ -r "$TRANSFORM" ]] || die "missing ROOT4 ABD transform: $TRANSFORM"
    [[ -x "$ROOT3_INIT" ]] || die "ROOT3 PID1 helper is missing; ROOT4 intentionally reuses the proven ROOT3 collector"
    bash -n "$ROOT3_INIT" || die "installed ROOT3 PID1 helper is not syntactically valid"

    # Never inherit a stale experimental one-shot selection.
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
    smmuq="$SRC/drivers/iommu/arm/arm-smmu/arm-smmu-qcom.c"
    msm="$SRC/drivers/pinctrl/qcom/pinctrl-msm.c"
    x1="$SRC/drivers/pinctrl/qcom/pinctrl-x1e80100.c"
    grep -Fq 'A14_QCOM_WOA_ACPI_GPIO_EVENT_XLATE' "$acpigpio" || die "ROOT2 GPIO-event translation missing"
    grep -Fq 'A14_QCOM_SCM_ACPI_QCOM04DD' "$scm" || die "ROOT2 SCM support missing"
    grep -Fq 'QCOMEDK2", 0x8380' "$smmuq" || die "ROOT2 SMMU match missing"
    grep -Fq 'A14_GIO0_SAFE_REGISTRATION_V1' "$msm" || die "ROOT1 GIO0 fix missing"
    grep -Fq 'QCOM0C0C' "$x1" || die "ROOT1 TLMM ACPI match missing"

    say "A14_ACPI_ROOT4_STAGE=0 ABD-status-transform"
    say "root_device=$root_src"
    say "root_partuuid=$root_partuuid"
    say "esp_candidates=${esp_candidates_string:-none}"
    say "build_before=$(du -sh "$OUT" 2>/dev/null | awk '{print $1}')"
    df -h "$OWNER_HOME" || true

    sudo -u "$OWNER" python3 "$TRANSFORM" "$SRC"
    abd="$SRC/drivers/acpi/arm64/qcom_abd.c"
    grep -Fq 'A14_QCOM_ABD_GSBUS_TRACE_V2' "$abd" || die "ROOT4 ABD marker missing"
    grep -Fq 'status = AE_OK' "$abd" || die "ROOT4 AE_OK handler return missing"
    ! grep -Fq 'status = AE_SUPPORT' "$abd" || die "ROOT3 AE_SUPPORT abort path still present"
    grep -Fq 'A14 ABD payload:' "$abd" || die "ROOT4 payload trace missing"
    grep -Fq 'gsb->status = 0xff' "$abd" || die "ROOT4 explicit transaction failure status missing"

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

    say "A14_ACPI_ROOT4_STAGE=1 regenerate-release-metadata"
    sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -C "$SRC" O="$OUT" olddefconfig
    grep -Fxq "CONFIG_LOCALVERSION=\"$LOCALVER\"" "$CONFIG" || die "CONFIG_LOCALVERSION mismatch"
    rm -f "$OUT/include/config/kernel.release" "$OUT/include/generated/utsrelease.h" "$OUT/include/generated/compile.h"
    sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -C "$SRC" O="$OUT" prepare
    release="$(sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -s -C "$SRC" O="$OUT" kernelrelease)"
    say "kernelrelease_after_regeneration=$release"
    [[ "$release" == "$KREL" ]] || die "kernelrelease mismatch: $release"

    say "A14_ACPI_ROOT4_STAGE=2 incremental-Image-only-build"
    say "modules_build=false"
    say "initramfs_build=false"
    rm -f "$OUT/drivers/acpi/arm64/qcom_abd.o" "$OUT/drivers/acpi/arm64/.qcom_abd.o.cmd"
    sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" Image
    [[ -s "$IMAGE" && -s "$VMLINUX" ]] || die "ROOT4 Image/vmlinux missing"
    grep -aFq 'A14 ABD: QCOM0427 GenericSerialBus handler installed (status-trace)' "$VMLINUX" || die "compiled kernel lacks ROOT4 ABD banner"
    grep -aFq 'provider success is never fabricated' "$VMLINUX" || die "compiled kernel lacks ROOT4 safety marker"
    grep -aFq 'A14 ABD payload:' "$VMLINUX" || die "compiled kernel lacks payload tracing"

    image_sha="$(sha256sum "$IMAGE" | awk '{print $1}')"
    install -m0644 "$IMAGE" "$KERNEL"
    install -m0644 "$CONFIG" "$BOOT_CONFIG"
    rm -f "/boot/initrd.img-$KREL"
    rm -rf "/lib/modules/$KREL"

    say "A14_ACPI_ROOT4_STAGE=3 clone-proven-PID1-and-GRUB"
    cp -a "$ROOT3_INIT" "$INIT_HELPER"
    sed -i \
        -e 's/a14-acpi-root3/a14-acpi-root4/g' \
        -e 's/a14-root3/a14-root4/g' \
        -e 's/A14_ACPI_ROOT3/A14_ACPI_ROOT4/g' \
        -e 's/ROOT3/ROOT4/g' \
        -e 's/sleep 5$/sleep 8/' \
        -e 's/ABD is trace-only in ROOT4/ABD is status-trace-only in ROOT4/' \
        "$INIT_HELPER"

    # Add ROOT4-specific checks after the inherited summary, before namespace dumps.
    python3 - "$INIT_HELPER" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
anchor = "emit 'A14_ACPI_ROOT4_BACKENDS=UNIMPLEMENTED_BY_DESIGN'\n"
if anchor not in s:
    raise SystemExit('missing ROOT4 summary insertion anchor')
extra = r'''if grep -q 'AE_SUPPORT, Returned by Handler for \[GenericSerialBus\]' "$DM"; then
    emit 'A14_ACPI_ROOT4_ABD_INTERPRETER_ABORT=STILL_PRESENT'
else
    emit 'A14_ACPI_ROOT4_ABD_INTERPRETER_ABORT=CLEARED'
fi
if grep -q 'A14 ABD payload:' "$DM"; then emit 'A14_ACPI_ROOT4_PAYLOAD_DUMP=PASS'; else emit 'A14_ACPI_ROOT4_PAYLOAD_DUMP=NONE_SEEN'; fi
abd_requests=$(grep -c 'A14 ABD: request=' "$DM" 2>/dev/null || true)
emit "A14_ACPI_ROOT4_REQUEST_COUNT=${abd_requests:-0}"
provider_ids=$(grep 'A14 ABD: request=' "$DM" 2>/dev/null | sed -n 's/.*provider=\(0x[0-9A-Fa-f]*\).*/\1/p' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
emit "A14_ACPI_ROOT4_PROVIDER_IDS=${provider_ids:-none}"
'''
s = s.replace(anchor, anchor + extra, 1)
p.write_text(s)
PY

    chmod 0755 "$INIT_HELPER"
    bash -n "$INIT_HELPER" || die "generated ROOT4 PID1 failed bash -n"
    rm -f "$ROOTLOG"

    boot_uuid="$(grub-probe --target=fs_uuid "$KERNEL")"
    kp="$(grub-mkrelpath "$KERNEL")"
    cmdline="root=PARTUUID=$root_partuuid rw rootfstype=ext4 rootwait init=$INIT_HELPER acpi=force earlycon=efifb,ram console=tty0 loglevel=8 ignore_loglevel printk.time=1 panic=30 clk_ignore_unused pd_ignore_unused cma=128M efi=noruntime stubble.dtb_override=false"
    cat >"$SNIPPET" <<EOF
#!/bin/sh
exec tail -n +3 \$0
# ROOT4: factory ACPI, ABD status-trace. NO DTB. NO initramfs.
menuentry '$ENTRY' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root $boot_uuid
    set gfxpayload=keep
    linux $kp $cmdline
}
EOF
    chmod 0755 "$SNIPPET"
    update-grub
    grub-script-check /boot/grub/grub.cfg >/dev/null
    ! grep -Eq '^[[:space:]]*initrd[[:space:]]' "$SNIPPET" || die "ROOT4 unexpectedly uses initramfs"
    ! grep -Eq '^[[:space:]]*devicetree[[:space:]]' "$SNIPPET" || die "ROOT4 unexpectedly loads DTB"

    grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true
    next="$(grub-editenv /boot/grub/grubenv list 2>/dev/null | sed -n 's/^next_entry=//p' | head -n1)"
    [[ -z "$next" ]] || die "prepare unexpectedly left next_entry armed: $next"

    say "A14_ACPI_ROOT4_PREPARE=PASS"
    say "kernelrelease=$KREL"
    say "kernel_sha256=$image_sha"
    say "abd_acpi_hid=QCOM0427"
    say "abd_address_space=GenericSerialBus"
    say "abd_mode=status-trace-AE_OK-with-status-0xff"
    say "provider_success_fabricated=false"
    say "payload_dump_max_bytes=96"
    say "modules_built=false"
    say "modules_installed=false"
    say "initramfs_used=false"
    say "hardware_dtb_loaded=false"
    say "root_report=$ROOTLOG"
    say "efi_report_name=/$ESPLOG_NAME"
    say "grub_entry=$ENTRY"
    say "next_entry=UNARMED"
    say "reboot_performed=false"
    say "To arm: sudo bash scripts/a14-acpi-root4-abd-status-one-go.sh arm"
    say "Then reboot manually only when YOU choose: sudo reboot"
}

case "$ACTION" in
    prepare) prepare ;;
    arm) arm ;;
    unarm) unarm ;;
    status) status ;;
    *) die "usage: $0 {prepare|arm|unarm|status}" ;;
esac
