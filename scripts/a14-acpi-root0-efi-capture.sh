#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Reuse the already-built ROOT0 kernel, make VFAT/NLS built-in only if needed,
# then capture synchronously to both Linux root and the EFI System Partition.
set -euo pipefail

KREL="7.1.5-a14-acpi-root0"
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
KERNEL="/boot/vmlinuz-$KREL"
CONFIG="$OUT/.config"
INIT_HELPER="/usr/local/sbin/a14-acpi-root0-init"
SNIPPET="/etc/grub.d/43_a14_acpi_root0"
ENTRY="ASUS Zenbook A14 — ACPI ROOT0 no-initrd ($KREL)"
ROOTLOG="$OWNER_HOME/Downloads/a14-acpi-root0.txt"
ESPLOG_NAME="a14-acpi-root0.txt"

for c in make sha256sum awk grep sed findmnt blkid lsblk grub-probe grub-mkrelpath update-grub grub-reboot grub-editenv grub-script-check sync du df; do need "$c"; done
[[ "$(uname -r)" != "$KREL" ]] || die "run from the normal DT/rescue kernel"
[[ -f "$SRC/Makefile" && -f "$CONFIG" && -s "$IMAGE" && -s "$KERNEL" ]] || die "existing ROOT0 build/install missing; run a14-acpi-root0-one-go.sh first"

# Cancel any stale experimental next boot before changing anything.
grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true

root_src="$(findmnt -n -o SOURCE /)"
root_fs="$(findmnt -n -o FSTYPE /)"
[[ "$root_src" == /dev/nvme*n*p* ]] || die "root is not direct NVMe: $root_src"
[[ "$root_fs" == ext4 ]] || die "root is not ext4: $root_fs"
root_parent="$(lsblk -no PKNAME "$root_src" | head -n1)"
[[ -n "$root_parent" ]] || die "cannot resolve root parent disk"
root_partuuid="$(blkid -s PARTUUID -o value "$root_src")"
[[ -n "$root_partuuid" ]] || die "cannot resolve root PARTUUID"

# Prefer an already-mounted ESP on the same NVMe; otherwise select the first
# GPT EFI System Partition on the same parent disk.
esp_dev=""
while read -r dev target fstype; do
    [[ -n "$dev" ]] || continue
    [[ "$fstype" == vfat || "$fstype" == fat ]] || continue
    [[ "$(lsblk -no PKNAME "$dev" 2>/dev/null | head -n1)" == "$root_parent" ]] || continue
    case "$target" in /boot/efi|/efi|/boot) esp_dev="$dev"; break;; esac
done < <(findmnt -rn -o SOURCE,TARGET,FSTYPE 2>/dev/null || true)

if [[ -z "$esp_dev" ]]; then
    ESP_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
    while read -r dev parent parttype; do
        [[ "$parent" == "$root_parent" ]] || continue
        [[ "${parttype,,}" == "$ESP_GUID" ]] || continue
        esp_dev="$dev"
        break
    done < <(lsblk -rpn -o NAME,PKNAME,PARTTYPE)
fi
[[ -b "$esp_dev" ]] || die "could not identify a writable EFI System Partition on /dev/$root_parent"
esp_partuuid="$(blkid -s PARTUUID -o value "$esp_dev" 2>/dev/null || true)"
esp_uuid="$(blkid -s UUID -o value "$esp_dev" 2>/dev/null || true)"

say "root_device=$root_src"
say "root_partuuid=$root_partuuid"
say "esp_device=$esp_dev"
say "esp_partuuid=${esp_partuuid:-unknown}"
say "esp_fsuuid=${esp_uuid:-unknown}"

# ROOT0 normally inherits Ubuntu's VFAT as a module. Since ROOT0 intentionally
# has no module tree, make FAT/VFAT + the common FAT NLS tables built-in. This
# is an incremental Image-only rebuild, not make modules.
C="$SRC/scripts/config"
need_rebuild=0
for sym in FAT_FS VFAT_FS NLS_CODEPAGE_437 NLS_ISO8859_1; do
    if ! grep -q "^CONFIG_${sym}=y$" "$CONFIG"; then
        sudo -u "$OWNER" "$C" --file "$CONFIG" --enable "$sym"
        need_rebuild=1
    fi
done

if (( need_rebuild )); then
    say "A14_ACPI_ROOT0_EFI_STAGE=1 incremental-vfat-image-rebuild"
    sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -C "$SRC" O="$OUT" olddefconfig
    for sym in FAT_FS VFAT_FS NLS_CODEPAGE_437 NLS_ISO8859_1; do
        grep -q "^CONFIG_${sym}=y$" "$CONFIG" || die "CONFIG_${sym}=y did not stick"
    done
    release="$(sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -s -C "$SRC" O="$OUT" kernelrelease)"
    [[ "$release" == "$KREL" ]] || die "kernelrelease changed: $release"
    sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" Image
    [[ -s "$IMAGE" ]] || die "rebuilt ROOT0 Image missing"
    install -m0644 "$IMAGE" "$KERNEL"
    install -m0644 "$CONFIG" "/boot/config-$KREL"
else
    say "A14_ACPI_ROOT0_EFI_STAGE=1 vfat-already-built-in"
fi

say "root0_build_size=$(du -sh "$OUT" | awk '{print $1}')"
say "root0_image_sha256=$(sha256sum "$KERNEL" | awk '{print $1}')"

# The previous helper used process substitution + tee. Replace that with direct
# writes and sync -f after every important record. The ESP is mounted with the
# sync option and receives an independent copy.
cat >"$INIT_HELPER" <<EOF2
#!/usr/bin/env bash
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin
ROOTLOG='$ROOTLOG'
ESPDEV='$esp_dev'
ESPLOGNAME='$ESPLOG_NAME'
ESPMNT=/run/a14-esp

# Root is already mounted before init= is executed. Make the first durable mark
# before depending on proc/sys/dev mounts or any capture utility.
printf '%s\n' 'A14_ACPI_ROOT0_INIT_ENTERED=1' >>"\$ROOTLOG"
sync -f "\$ROOTLOG" 2>/dev/null || sync

mkdir -p /proc /sys /dev /run "\$ESPMNT"
mountpoint -q /proc 2>/dev/null || mount -t proc proc /proc 2>/dev/null || true
mountpoint -q /sys 2>/dev/null || mount -t sysfs sysfs /sys 2>/dev/null || true
mountpoint -q /dev 2>/dev/null || mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mountpoint -q /run 2>/dev/null || mount -t tmpfs tmpfs /run 2>/dev/null || true

ESPLOG=""
if mount -t vfat -o rw,sync "\$ESPDEV" "\$ESPMNT" 2>/dev/null; then
    ESPLOG="\$ESPMNT/\$ESPLOGNAME"
    : >"\$ESPLOG"
    printf '%s\n' 'A14_ACPI_ROOT0_EFI_MOUNT=PASS' >>"\$ESPLOG"
    sync -f "\$ESPLOG" 2>/dev/null || sync
    printf '%s\n' 'A14_ACPI_ROOT0_EFI_MOUNT=PASS' >>"\$ROOTLOG"
else
    printf '%s\n' 'A14_ACPI_ROOT0_EFI_MOUNT=FAIL' >>"\$ROOTLOG"
fi
sync -f "\$ROOTLOG" 2>/dev/null || sync

emit(){
    local line="\$*"
    printf '%s\n' "\$line" >>"\$ROOTLOG"
    sync -f "\$ROOTLOG" 2>/dev/null || sync
    if [[ -n "\$ESPLOG" ]]; then
        printf '%s\n' "\$line" >>"\$ESPLOG"
        sync -f "\$ESPLOG" 2>/dev/null || sync
    fi
}
append_file(){
    local src="\$1"
    [[ -r "\$src" ]] || return 0
    cat "\$src" >>"\$ROOTLOG" 2>/dev/null || true
    sync -f "\$ROOTLOG" 2>/dev/null || sync
    if [[ -n "\$ESPLOG" ]]; then
        cat "\$src" >>"\$ESPLOG" 2>/dev/null || true
        sync -f "\$ESPLOG" 2>/dev/null || sync
    fi
}
append_cmd(){
    local tmp=/run/a14-cap.tmp
    "\$@" >"\$tmp" 2>&1 || true
    append_file "\$tmp"
    rm -f "\$tmp"
}

emit 'A14_ACPI_ROOT0_DIRECT_ROOT_MOUNT=PASS'
emit "timestamp=\$(date --iso-8601=seconds 2>/dev/null || date)"
emit "kernel=\$(uname -a)"
emit "cmdline=\$(cat /proc/cmdline 2>/dev/null || true)"
emit "root_mount=\$(grep ' / ' /proc/mounts 2>/dev/null || true)"
emit '===== partitions ====='; append_file /proc/partitions
emit '===== nvme nodes ====='; append_cmd sh -c 'ls -l /dev/nvme* 2>&1'
emit '===== ACPI tables ====='; append_cmd sh -c 'ls -l /sys/firmware/acpi/tables 2>&1'
emit '===== live device tree ====='
if [[ -e /proc/device-tree/model ]]; then append_cmd sh -c "tr '\\0' ' ' </proc/device-tree/model; echo"; else emit 'ABSENT'; fi
emit '===== PCI ====='; command -v lspci >/dev/null 2>&1 && append_cmd lspci -nnk
emit '===== INPUT ====='; append_file /proc/bus/input/devices
emit '===== HIGH SIGNAL DMESG ====='; append_cmd sh -c "dmesg | grep -Ei 'acpi|nvme|pci|pcie|iort|smmu|iommu|tlmm|gpio|geni|QCOM0C0D|ROP1|root|ext4|vfs|fail|error|timeout'"
emit '===== FULL DMESG ====='; append_cmd dmesg
emit 'A14_ACPI_ROOT0_CAPTURE_COMPLETE=1'

chown '$OWNER:$OWNER' "\$ROOTLOG" 2>/dev/null || true
sync
if [[ -n "\$ESPLOG" ]]; then
    umount "\$ESPMNT" 2>/dev/null || true
    sync
fi
sleep 2
/sbin/reboot -f 2>/dev/null || /usr/sbin/reboot -f 2>/dev/null || true
echo 1 >/proc/sys/kernel/sysrq 2>/dev/null || true
echo b >/proc/sysrq-trigger 2>/dev/null || true
while :; do sleep 60; done
EOF2
chmod 0755 "$INIT_HELPER"

# Recreate a clean no-initrd ROOT0 one-shot entry.
rm -f "$ROOTLOG"
rm -f /etc/grub.d/41_a14_acpi_v2 /etc/grub.d/42_a14_acpi_v2_root_debug /etc/grub.d/41_a14_full_acpi_checkpoint
boot_uuid="$(grub-probe --target=fs_uuid "$KERNEL")"
kp="$(grub-mkrelpath "$KERNEL")"
cmdline="root=PARTUUID=$root_partuuid rw rootfstype=ext4 rootwait init=$INIT_HELPER acpi=force earlycon=efifb,ram console=tty0 loglevel=8 ignore_loglevel printk.time=1 panic=30 clk_ignore_unused pd_ignore_unused cma=128M efi=noruntime stubble.dtb_override=false"
cat >"$SNIPPET" <<EOF2
#!/bin/sh
exec tail -n +3 \$0
# ROOT0 synchronous root+ESP capture. NO DTB. NO initramfs.
menuentry '$ENTRY' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root $boot_uuid
    set gfxpayload=keep
    linux $kp $cmdline
}
EOF2
chmod 0755 "$SNIPPET"
update-grub
grub-script-check /boot/grub/grub.cfg >/dev/null
! grep -Eq '^[[:space:]]*initrd[[:space:]]' "$SNIPPET" || die "ROOT0 unexpectedly has initrd"
! grep -Eq '^[[:space:]]*devicetree[[:space:]]' "$SNIPPET" || die "ROOT0 unexpectedly has DTB"

grub-reboot "$ENTRY"
next="$(grub-editenv /boot/grub/grubenv list | sed -n 's/^next_entry=//p' | head -n1)"
[[ "$next" == "$ENTRY" ]] || die "failed to arm ROOT0 EFI capture entry"

say "A14_ACPI_ROOT0_EFI_CAPTURE=READY"
say "root_log=$ROOTLOG"
say "efi_device=$esp_dev"
say "efi_log=/$ESPLOG_NAME"
say "modules_built=false"
say "initramfs_used=false"
say "systemd_used=false"
say "synchronous_direct_writes=true"
say "next_entry=$next"
say "rebooting_now=true"
sync
sleep 2
systemctl reboot
