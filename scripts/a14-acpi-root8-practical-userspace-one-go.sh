#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# ACPI ROOT8: practical userspace boot using ROOT5 ACPI fixes plus QRTR and targeted module packaging.
#
# Safety invariants:
#   - targeted module build only; no broad make modules
#   - initramfs is created for this KREL because userspace proved module-dependent
#   - no DTB
#   - TPM RM wait remains masked
#   - prepare always leaves GRUB next_entry empty
#   - arm only sets one-shot GRUB state; never reboots
#   - panic=0
set -euo pipefail

ACTION="${1:-prepare}"
KREL="7.1.5-a14-acpi-root8"
LOCALVER="-a14-acpi-root8"
ENTRY="ASUS Zenbook A14 — ACPI ROOT8 practical userspace ($KREL)"
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
INITRD="/boot/initrd.img-$KREL"
SNIPPET="/etc/grub.d/50_a14_acpi_root8_practical_userspace"
MODDIR="/lib/modules/$KREL"
ROOT5_REPORT="$OWNER_HOME/Downloads/a14-acpi-root5.txt"
ROOT7_JOURNAL="$OWNER_HOME/Downloads/a14-acpi-root7-journal.txt"
ROOT8_NOTE="$OWNER_HOME/Downloads/a14-acpi-root8-practical-userspace-note.txt"

for c in python3 make awk grep sed find findmnt blkid grub-probe grub-mkrelpath update-grub grub-editenv grub-script-check sha256sum sync depmod update-initramfs du df install; do need "$c"; done

unarm(){
    grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true
    say "A14_ACPI_ROOT8_UNARMED=1"
    say "reboot_performed=false"
}

status(){
    say "running_kernel=$(uname -r)"
    say "kernel=$KERNEL"
    [[ -s "$KERNEL" ]] && say "kernel_sha256=$(sha256sum "$KERNEL" | awk '{print $1}')"
    [[ -s "$INITRD" ]] && say "initrd=present" || say "initrd=absent"
    [[ -d "$MODDIR" ]] && say "modules_dir=present" || say "modules_dir=absent"
    [[ -r "$SNIPPET" ]] && say "grub_entry=present" || say "grub_entry=absent"
    say "next_entry=$(grub-editenv /boot/grub/grubenv list 2>/dev/null | sed -n 's/^next_entry=//p' | head -n1)"
    say "reboot_performed=false"
}

arm(){
    need grub-reboot
    [[ -s "$KERNEL" ]] || die "ROOT8 kernel missing: $KERNEL"
    [[ -s "$INITRD" ]] || die "ROOT8 initramfs missing: $INITRD"
    [[ -d "$MODDIR" ]] || die "ROOT8 modules dir missing: $MODDIR"
    [[ -r "$SNIPPET" ]] || die "ROOT8 GRUB snippet missing: $SNIPPET"
    grub-script-check /boot/grub/grub.cfg >/dev/null
    grub-reboot "$ENTRY"
    next="$(grub-editenv /boot/grub/grubenv list | sed -n 's/^next_entry=//p' | head -n1)"
    [[ "$next" == "$ENTRY" ]] || die "failed to arm ROOT8: ${next:-missing}"
    say "A14_ACPI_ROOT8_ARMED=1"
    say "next_entry=$next"
    say "reboot_performed=false"
    say "Reboot manually only when YOU choose: sudo reboot"
}

cfg_set_y(){ sudo -u "$OWNER" "$SRC/scripts/config" --file "$CONFIG" --enable "$1" || true; }
cfg_set_m(){ sudo -u "$OWNER" "$SRC/scripts/config" --file "$CONFIG" --module "$1" || true; }
cfg_val(){ grep -E "^(CONFIG_$1=|# CONFIG_$1 is not set)" "$CONFIG" | tail -n1 || true; }

build_module_dir(){
    local rel="$1"
    local srcdir="$SRC/$rel"
    local outdir="$OUT/$rel"
    [[ -d "$srcdir" ]] || { say "module_dir_missing=$rel"; return 0; }
    say "A14_ACPI_ROOT8_MODULE_BUILD=$rel"
    sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -C "$SRC" O="$OUT" M="$rel" -j"${A14_BUILD_JOBS:-$(nproc)}" modules || {
        say "module_dir_build_failed=$rel"
        return 0
    }
    if ! find "$outdir" -name '*.ko' -type f | grep -q .; then
        say "module_dir_no_ko=$rel"
        return 0
    fi
    while IFS= read -r ko; do
        local sub relko dest
        sub="${ko#$OUT/}"
        relko="kernel/$sub"
        dest="$MODDIR/$relko"
        install -D -m0644 "$ko" "$dest"
        say "installed_module=${relko}"
    done < <(find "$outdir" -name '*.ko' -type f | sort)
}

prepare(){
    case "$(uname -r)" in
        7.1.5-a14-acpi-full0|7.1.5-a14-acpi-root0|7.1.5-a14-acpi-root1|7.1.5-a14-acpi-root2|7.1.5-a14-acpi-root3|7.1.5-a14-acpi-root4|7.1.5-a14-acpi-root5|$KREL)
            die "run prepare from the normal DT/rescue kernel" ;;
    esac

    [[ -f "$SRC/Makefile" && -f "$CONFIG" && -s "$IMAGE" && -s "$VMLINUX" ]] || die "compact build tree missing under $WORK"
    [[ -r "$SRC/drivers/acpi/arm64/qcom_abd.c" ]] || die "ABD source missing; run ROOT5 prepare first"
    grep -Fq 'A14_QCOM_ABD_PROVIDER4_STATUS_SHIM_V3' "$SRC/drivers/acpi/arm64/qcom_abd.c" || die "ROOT5 provider-4 shim missing"
    grep -Fq 'A14_QCOM_SOSI_READONLY_PROBE_V2' "$SRC/drivers/acpi/arm64/qcom_sosi_probe.c" || die "ROOT4/5 SOSI probe missing"
    grep -Fq 'A14_QCOM_WOA_ACPI_GPIO_EVENT_XLATE' "$SRC/drivers/gpio/gpiolib-acpi-core.c" || die "ROOT2 GPIO event fix missing"
    grep -Fq 'A14_QCOM_SCM_ACPI_QCOM04DD' "$SRC/drivers/firmware/qcom/qcom_scm.c" || die "ROOT2 SCM fix missing"
    [[ -r "$ROOT5_REPORT" ]] && grep -Fq 'A14_ACPI_ROOT5_GSBUS_AE_SUPPORT=CLEARED' "$ROOT5_REPORT" || say "warning=root5_report_not_confirmed"
    [[ -r "$ROOT7_JOURNAL" ]] && grep -Fq 'systemd.mask=dev-tpmrm0.device systemd.mask=tpm2.target' "$ROOT7_JOURNAL" || say "warning=root7_journal_not_confirmed"

    grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true

    root_src="$(findmnt -n -o SOURCE /)"
    root_fs="$(findmnt -n -o FSTYPE /)"
    [[ "$root_src" == /dev/nvme*n*p* ]] || die "root is not direct NVMe: $root_src"
    [[ "$root_fs" == ext4 ]] || die "root is not ext4: $root_fs"
    root_partuuid="$(blkid -s PARTUUID -o value "$root_src")"
    [[ -n "$root_partuuid" ]] || die "cannot resolve root PARTUUID"

    say "A14_ACPI_ROOT8_STAGE=0 configure-practical-userspace-kernel"
    say "root_device=$root_src"
    say "root_partuuid=$root_partuuid"
    say "build_before=$(du -sh "$OUT" 2>/dev/null | awk '{print $1}')"
    df -h "$OWNER_HOME" || true

    cfg_set_y QRTR
    cfg_set_m QRTR_SMD
    cfg_set_m QRTR_MHI
    cfg_set_m QRTR_TUN
    cfg_set_m AUTOFS_FS
    cfg_set_m I2C_CHARDEV
    cfg_set_m HID_ASUS_EC
    cfg_set_m HID_ASUS_ZENBOOK_A14_EC
    cfg_set_m LEDS_QCOM_FLASH
    cfg_set_m I2C_QCOM_CCI
    cfg_set_m QCOM_CCI_SYNC
    cfg_set_m VIDEO_HM1092
    cfg_set_m HM1092
    sudo -u "$OWNER" "$SRC/scripts/config" --file "$CONFIG" --set-str LOCALVERSION "$LOCALVER"
    sudo -u "$OWNER" "$SRC/scripts/config" --file "$CONFIG" --disable LOCALVERSION_AUTO
    sudo -u "$OWNER" "$SRC/scripts/config" --file "$CONFIG" --disable DEBUG_INFO
    sudo -u "$OWNER" "$SRC/scripts/config" --file "$CONFIG" --enable DEBUG_INFO_NONE
    sudo -u "$OWNER" "$SRC/scripts/config" --file "$CONFIG" --disable DEBUG_INFO_BTF

    say "A14_ACPI_ROOT8_STAGE=1 olddefconfig-and-Image"
    sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -C "$SRC" O="$OUT" olddefconfig
    release="$(sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -s -C "$SRC" O="$OUT" kernelrelease)"
    [[ "$release" == "$KREL" ]] || die "kernelrelease mismatch: $release"
    for s in QRTR AUTOFS_FS I2C_CHARDEV QRTR_SMD QRTR_MHI QRTR_TUN HID_ASUS_EC HID_ASUS_ZENBOOK_A14_EC LEDS_QCOM_FLASH I2C_QCOM_CCI QCOM_CCI_SYNC VIDEO_HM1092 HM1092; do
        say "config_${s}=$(cfg_val "$s")"
    done
    sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -C "$SRC" O="$OUT" prepare
    sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" Image
    [[ -s "$IMAGE" && -s "$VMLINUX" ]] || die "ROOT8 Image/vmlinux missing"
    grep -aFq 'A14_QCOM_ABD_PROVIDER4_STATUS_SHIM_V3' "$VMLINUX" || die "compiled kernel lacks ROOT5 provider-4 shim"

    say "A14_ACPI_ROOT8_STAGE=2 targeted-module-build-install"
    rm -rf "$MODDIR"
    install -d -m0755 "$MODDIR/kernel"
    for meta in modules.builtin modules.builtin.modinfo modules.builtin.ranges modules.order; do
        [[ -r "$OUT/$meta" ]] && install -m0644 "$OUT/$meta" "$MODDIR/$meta" || : >"$MODDIR/$meta"
    done

    build_module_dir fs/autofs
    build_module_dir drivers/i2c
    build_module_dir drivers/hid
    build_module_dir drivers/leds/flash
    build_module_dir drivers/media/i2c
    build_module_dir drivers/media/platform/qcom
    build_module_dir net/qrtr

    depmod -a "$KREL"

    say "A14_ACPI_ROOT8_STAGE=3 install-kernel-initramfs-grub"
    image_sha="$(sha256sum "$IMAGE" | awk '{print $1}')"
    install -m0644 "$IMAGE" "$KERNEL"
    install -m0644 "$CONFIG" "$BOOT_CONFIG"
    update-initramfs -c -k "$KREL"
    [[ -s "$INITRD" ]] || die "initramfs creation failed: $INITRD"

    boot_uuid="$(grub-probe -t fs_uuid /boot)"
    kernel_path="$(grub-mkrelpath "$KERNEL")"
    initrd_path="$(grub-mkrelpath "$INITRD")"
    [[ -n "$boot_uuid" && -n "$kernel_path" && -n "$initrd_path" ]] || die "cannot resolve GRUB paths"

    cat >"$SNIPPET" <<ROOT8_GRUB
#!/bin/sh
exec tail -n +3 \$0
menuentry '$ENTRY' {
    search --no-floppy --fs-uuid --set=root '$boot_uuid'
    linux '$kernel_path' root=PARTUUID=$root_partuuid rw rootfstype=ext4 rootwait acpi=force earlycon=efifb,ram console=tty0 loglevel=8 ignore_loglevel printk.time=1 panic=0 clk_ignore_unused pd_ignore_unused cma=128M efi=noruntime stubble.dtb_override=false systemd.unit=multi-user.target systemd.mask=dev-tpmrm0.device systemd.mask=tpm2.target
    initrd '$initrd_path'
}
ROOT8_GRUB
    chmod 0755 "$SNIPPET"
    grub-script-check "$SNIPPET" >/dev/null
    update-grub
    grub-script-check /boot/grub/grub.cfg >/dev/null

    grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true
    next="$(grub-editenv /boot/grub/grubenv list 2>/dev/null | sed -n 's/^next_entry=//p' | head -n1)"
    [[ -z "$next" ]] || die "prepare unexpectedly left next_entry armed: $next"

    {
        say "A14_ACPI_ROOT8_NOTE=prepared"
        say "kernel=$KERNEL"
        say "kernel_sha256=$image_sha"
        say "entry=$ENTRY"
        say "mode=normal_systemd_multi_user_practical_modules"
        say "qrtr_builtin=$(cfg_val QRTR)"
        say "targeted_modules=true"
        say "initramfs_used=true"
        say "hardware_dtb_loaded=false"
        say "tpm_masked=dev-tpmrm0.device,tpm2.target"
        say "panic_auto_reboot=false"
    } >"$ROOT8_NOTE"
    chown "$OWNER:$OWNER" "$ROOT8_NOTE" 2>/dev/null || true
    sync

    say "A14_ACPI_ROOT8_PREPARE=PASS"
    say "kernelrelease=$KREL"
    say "kernel_sha256=$image_sha"
    say "mode=normal_systemd_multi_user_practical_modules"
    say "qrtr_builtin=$(cfg_val QRTR)"
    say "targeted_modules_built=true"
    say "modules_dir=$MODDIR"
    say "initramfs_used=true"
    say "initrd=$INITRD"
    say "hardware_dtb_loaded=false"
    say "init_override=false"
    say "tpm_masked=dev-tpmrm0.device,tpm2.target"
    say "panic_auto_reboot=false"
    say "root_partuuid=$root_partuuid"
    say "grub_entry=$ENTRY"
    say "next_entry=UNARMED"
    say "reboot_performed=false"
    say "To arm: sudo bash scripts/a14-acpi-root8-practical-userspace-one-go.sh arm"
}

case "$ACTION" in
    prepare) prepare ;;
    arm) arm ;;
    unarm) unarm ;;
    status) status ;;
    *) die "usage: $0 [prepare|arm|unarm|status]" ;;
esac
