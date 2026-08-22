#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Minimal ACPI root-mount proof for ASUS Zenbook A14 UX3407RA.
#
# Deliberately does NOT build/install the distro's module universe and does NOT
# use an initramfs. The critical root path is built into one uniquely-versioned
# Image; the kernel mounts the ext4 root by PARTUUID and starts a tiny PID 1
# capture helper directly from that root filesystem.
set -euo pipefail

KREL="7.1.5-a14-acpi-root0"
LOCALVER="-a14-acpi-root0"
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
BASECFG="$WORK/root0-base.config"
ARCHIVE="$WORK/root0-preserved-old-build"
IMAGE="$OUT/arch/arm64/boot/Image"
KERNEL="/boot/vmlinuz-$KREL"
CONFIG="/boot/config-$KREL"
INIT_HELPER="/usr/local/sbin/a14-acpi-root0-init"
SNIPPET="/etc/grub.d/43_a14_acpi_root0"
ENTRY="ASUS Zenbook A14 — ACPI ROOT0 no-initrd ($KREL)"
REPORT="$OWNER_HOME/Downloads/a14-acpi-root0.txt"

for c in make sha256sum awk grep findmnt blkid grub-probe grub-mkrelpath update-grub grub-reboot grub-editenv grub-script-check sync du df; do need "$c"; done
[[ "$(uname -r)" != 7.1.5-a14-acpi-full0 && "$(uname -r)" != "$KREL" ]] || die "run from the normal DT/rescue kernel"
[[ -f "$SRC/Makefile" ]] || die "transformed Linux source missing: $SRC"

# The previous ROOT0 attempt already reclaimed the huge all-modules build and
# saved its config here. Fall back to the preserved archive or installed config
# only if this is the first run of this corrected script.
if [[ ! -s "$BASECFG" ]]; then
    if [[ -s "$ARCHIVE/config-7.1.5-a14-acpi-full0" ]]; then
        cp -f "$ARCHIVE/config-7.1.5-a14-acpi-full0" "$BASECFG"
    elif [[ -s /boot/config-7.1.5-a14-acpi-full0 ]]; then
        cp -f /boot/config-7.1.5-a14-acpi-full0 "$BASECFG"
    else
        die "no base kernel config remains; expected $BASECFG or preserved/installed full0 config"
    fi
fi

# Do not race any old kernel build.
if pgrep -u "$OWNER" -af "make .*a14-full-acpi-kernel.*(modules|Image)" >/dev/null 2>&1; then
    pgrep -u "$OWNER" -af "make .*a14-full-acpi-kernel.*(modules|Image)" || true
    die "an old A14 kernel make is still running; stop it with Ctrl+C and rerun"
fi

root_src="$(findmnt -n -o SOURCE /)"
root_fs="$(findmnt -n -o FSTYPE /)"
[[ "$root_src" == /dev/nvme*n*p* ]] || die "root is not a direct NVMe partition: $root_src"
[[ "$root_fs" == ext4 ]] || die "root filesystem is not ext4: $root_fs"
partuuid="$(blkid -s PARTUUID -o value "$root_src")"
fsuuid="$(blkid -s UUID -o value "$root_src")"
[[ -n "$partuuid" && -n "$fsuuid" ]] || die "cannot resolve root PARTUUID/UUID"

grep -q 'A14 ACPI: wrapperless GENI SE, TX FIFO depth' "$SRC/drivers/i2c/busses/i2c-qcom-geni.c" || die "GENI ACPI transform missing"
grep -q 'a14_iort_pcie_smmuv3_firmware_owned' "$SRC/drivers/acpi/arm64/iort.c" || die "IORT PCIe/SMMU ACPI transform missing"
grep -q 'smmu-reset-after-scr0-write' "$SRC/drivers/iommu/arm/arm-smmu/arm-smmu.c" || die "SMMU ACPI transform missing"
# In Linux 7.1.5 there is no CONFIG_PCI_ACPI Kconfig symbol: pci-acpi.o is
# compiled from drivers/pci/Makefile whenever CONFIG_PCI and CONFIG_ACPI are on.
grep -Fq 'obj-$(CONFIG_ACPI)' "$SRC/drivers/pci/Makefile" || die "unexpected PCI Makefile: ACPI PCI glue rule missing"
grep -Fq 'pci-acpi.o' "$SRC/drivers/pci/Makefile" || die "unexpected PCI Makefile: pci-acpi.o rule missing"

say "===== ROOT0 SPACE ====="
df -h "$OWNER_HOME" || true
du -sh "$OUT" 2>/dev/null || true

rm -rf "$OUT"
mkdir -p "$OUT"
cp -f "$BASECFG" "$OUT/.config"
chown -R "$OWNER:$OWNER" "$OUT" "$BASECFG"

C="$SRC/scripts/config"
[[ -x "$C" ]] || die "kernel scripts/config missing"
sudo -u "$OWNER" "$C" --file "$OUT/.config" --set-str LOCALVERSION "$LOCALVER"
sudo -u "$OWNER" "$C" --file "$OUT/.config" --disable LOCALVERSION_AUTO

# Explicit user-facing/build-critical options. These are the options ROOT0
# actually needs to mount an ext4 root on NVMe without modules or initramfs.
critical_y=(
    ACPI EFI EFI_STUB
    BLOCK EFI_PARTITION
    PCI PCIEPORTBUS PCI_MSI
    IOMMU_SUPPORT ARM_SMMU ARM_SMMU_V3
    BLK_DEV_NVME
    EXT4_FS
    DEVTMPFS DEVTMPFS_MOUNT TMPFS
    MAGIC_SYSRQ
)
for sym in "${critical_y[@]}"; do
    sudo -u "$OWNER" "$C" --file "$OUT/.config" --enable "$sym"
done

# Helpful infrastructure. If a symbol is hidden/derived, olddefconfig is the
# authority; we do not fail merely because scripts/config cannot force it.
optional_y=(
    PCI_HOST_GENERIC PCIE_QCOM
    QCOM_SCM QCOM_WOA_PEP_COMPAT QCOM_WOA_QPPX_COMPAT
    PINCTRL_MSM PINCTRL_X1E80100
    I2C I2C_QCOM_GENI I2C_HID I2C_HID_ACPI
    HID HID_GENERIC
)
for sym in "${optional_y[@]}"; do
    sudo -u "$OWNER" "$C" --file "$OUT/.config" --enable "$sym"
done

sudo -u "$OWNER" "$C" --file "$OUT/.config" --disable DEBUG_INFO
sudo -u "$OWNER" "$C" --file "$OUT/.config" --enable DEBUG_INFO_NONE
sudo -u "$OWNER" "$C" --file "$OUT/.config" --disable DEBUG_INFO_BTF
sudo -u "$OWNER" "$C" --file "$OUT/.config" --disable GDB_SCRIPTS

say "A14_ACPI_ROOT0_STAGE=1 olddefconfig"
sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -C "$SRC" O="$OUT" olddefconfig

for sym in "${critical_y[@]}"; do
    grep -q "^CONFIG_${sym}=y$" "$OUT/.config" || die "required built-in CONFIG_${sym}=y was not retained"
done
# Derived ARM64 ACPI/PCI plumbing that must exist after Kconfig resolution.
grep -q '^CONFIG_IOMMU_DMA=y$' "$OUT/.config" || die "ARM64 derived CONFIG_IOMMU_DMA=y missing"
grep -q '^CONFIG_PCI_ECAM=y$' "$OUT/.config" || die "ARM64 PCI ECAM support missing"

release="$(sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -s -C "$SRC" O="$OUT" kernelrelease)"
[[ "$release" == "$KREL" ]] || die "kernelrelease mismatch: $release"

say "A14_ACPI_ROOT0_CONFIG=PASS"
say "pci_acpi_glue=derived-from-CONFIG_ACPI"
say "iommu_dma=derived-arm64"
say "kernelrelease=$release"
say "A14_ACPI_ROOT0_STAGE=2 Image-only-build"
say "modules_build=false"
say "initramfs_build=false"
sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" Image
[[ -s "$IMAGE" ]] || die "root0 Image missing"
image_sha="$(sha256sum "$IMAGE" | awk '{print $1}')"

say "===== ROOT0 BUILD SIZE ====="
du -sh "$OUT" || true
df -h "$OWNER_HOME" || true

install -m0644 "$IMAGE" "$KERNEL"
install -m0644 "$OUT/.config" "$CONFIG"
rm -f "/boot/initrd.img-$KREL"
rm -rf "/lib/modules/$KREL"

cat >"$INIT_HELPER" <<EOF2
#!/usr/bin/env bash
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin
OWNER='$OWNER'
REPORT='$REPORT'
mkdir -p /proc /sys /dev /run
mountpoint -q /proc 2>/dev/null || mount -t proc proc /proc 2>/dev/null || true
mountpoint -q /sys 2>/dev/null || mount -t sysfs sysfs /sys 2>/dev/null || true
mountpoint -q /dev 2>/dev/null || mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mountpoint -q /run 2>/dev/null || mount -t tmpfs tmpfs /run 2>/dev/null || true
exec > >(tee "\$REPORT") 2>&1

echo 'A14_ACPI_ROOT0_DIRECT_ROOT_MOUNT=PASS'
echo "timestamp=\$(date --iso-8601=seconds 2>/dev/null || date)"
echo "kernel=\$(uname -a)"
echo "cmdline=\$(cat /proc/cmdline)"
echo "root_mount=\$(grep ' / ' /proc/mounts 2>/dev/null || true)"
echo '===== partitions ====='; cat /proc/partitions 2>/dev/null || true
echo '===== nvme ====='; ls -l /dev/nvme* 2>/dev/null || true
echo '===== acpi ====='; ls -l /sys/firmware/acpi/tables 2>/dev/null || true
echo '===== live device tree ====='; if [[ -e /proc/device-tree/model ]]; then tr '\0' ' ' </proc/device-tree/model; echo; else echo ABSENT; fi
echo '===== pci ====='; lspci -nnk 2>/dev/null || true
echo '===== iommu groups ====='; for g in /sys/kernel/iommu_groups/*; do [[ -e "\$g" ]] || continue; echo "group \${g##*/}"; ls -l "\$g/devices" 2>/dev/null || true; done
echo '===== input ====='; cat /proc/bus/input/devices 2>/dev/null || true
echo '===== high-signal dmesg ====='; dmesg 2>/dev/null | grep -Ei 'acpi|nvme|pci|pcie|iort|smmu|iommu|tlmm|gpio|geni|QCOM0C0D|ROP1|root|ext4|vfs|fail|error|timeout' || true
echo '===== full dmesg ====='; dmesg 2>/dev/null || true
echo 'A14_ACPI_ROOT0_CAPTURE_COMPLETE=1'
chown '$OWNER:$OWNER' "\$REPORT" 2>/dev/null || true
sync
sleep 3
echo 1 >/proc/sys/kernel/sysrq 2>/dev/null || true
echo b >/proc/sysrq-trigger 2>/dev/null || true
sleep 10
/sbin/reboot -f 2>/dev/null || /usr/sbin/reboot -f 2>/dev/null || true
while :; do sleep 60; done
EOF2
chmod 0755 "$INIT_HELPER"

grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true
rm -f /etc/grub.d/41_a14_acpi_v2 /etc/grub.d/42_a14_acpi_v2_root_debug /etc/grub.d/41_a14_full_acpi_checkpoint "$SNIPPET"

boot_uuid="$(grub-probe --target=fs_uuid "$KERNEL")"
kp="$(grub-mkrelpath "$KERNEL")"
cmdline="root=PARTUUID=$partuuid rw rootfstype=ext4 rootwait init=$INIT_HELPER acpi=force earlycon=efifb,ram console=tty0 loglevel=8 ignore_loglevel printk.time=1 panic=30 clk_ignore_unused pd_ignore_unused cma=128M efi=noruntime stubble.dtb_override=false"

cat >"$SNIPPET" <<EOF2
#!/bin/sh
exec tail -n +3 \$0
# Minimal A14 ACPI root proof: deliberately NO DTB and NO initramfs.
menuentry '$ENTRY' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root $boot_uuid
    set gfxpayload=keep
    linux $kp $cmdline
}
EOF2
chmod 0755 "$SNIPPET"

update-grub
grub-script-check /boot/grub/grub.cfg >/dev/null
linux_line="$(awk '/^menuentry .*ACPI ROOT0/{seen=1} seen && /^[[:space:]]*linux[[:space:]]/{print; exit}' "$SNIPPET")"
[[ -n "$linux_line" ]] || die "ROOT0 linux line missing"
for req in "root=PARTUUID=$partuuid" 'rootfstype=ext4' 'rootwait' "init=$INIT_HELPER" 'acpi=force' 'panic=30'; do
    grep -Fq "$req" <<<"$linux_line" || die "ROOT0 line lacks $req"
done
! grep -Eq '^[[:space:]]*initrd[[:space:]]' "$SNIPPET" || die "ROOT0 unexpectedly uses initramfs"
! grep -Eq '^[[:space:]]*devicetree[[:space:]]' "$SNIPPET" || die "ROOT0 unexpectedly loads DTB"

grub-reboot "$ENTRY"
next="$(grub-editenv /boot/grub/grubenv list | sed -n 's/^next_entry=//p' | head -n1)"
[[ "$next" == "$ENTRY" ]] || die "failed to arm ROOT0 entry: ${next:-missing}"

say "A14_ACPI_ROOT0_ONE_GO=READY"
say "kernelrelease=$KREL"
say "image_sha256=$image_sha"
say "root_source=$root_src"
say "root_partuuid=$partuuid"
say "root_fsuuid=$fsuuid"
say "modules_built=false"
say "modules_installed=false"
say "initramfs_used=false"
say "systemd_used_for_test=false"
say "dracut_used_for_test=false"
say "hardware_dtb_loaded=false"
say "report_on_success=$REPORT"
say "root_failure_behavior=kernel-panic-auto-reboot-after-30s"
say "root_success_behavior=PID1-capture-sync-auto-reboot"
say "next_entry=$next"
say "linux_line=$linux_line"
say "rebooting_now=true"
sync
sleep 3
systemctl reboot
