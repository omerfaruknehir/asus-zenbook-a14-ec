#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Rebuild a module tree that exactly matches the validated ACPI Image, create a
# fresh non-hostonly Dracut initrd, arm one ACPI-only boot, capture automatically
# after switch-root, and return to the normal DT boot without local input.
set -euo pipefail

KREL="7.1.5-a14-acpi-full0"
GOOD_COMMIT="74c9bd5ebc77e2563b8be50d8cb4af67202c71fe"
EXPECTED_IMAGE_SHA="8c588e767e0466419744b235232676b324b294f1c4ad242b8a28560f7719466b"
ENTRY="ASUS Zenbook A14 — ACPI-ONLY UNRESTRICTED ($KREL)"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
OWNER="${SUDO_USER:-}"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"
[[ -n "$OWNER" && "$OWNER" != root ]] || die "run with sudo from your normal user"
OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
[[ -d "$OWNER_HOME" ]] || die "cannot resolve owner home"

WORK="${A14_74C9_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="$WORK/linux-7.1.5"
OUT="$WORK/build"
IMAGE="$OUT/arch/arm64/boot/Image"
KERNEL="/boot/vmlinuz-$KREL"
INITRD="/boot/initrd.img-$KREL"
STAMP="$WORK/74c9bd5-build.ready"
TS="$(date +%Y%m%d-%H%M%S)"
EVIDENCE="$OWNER_HOME/Downloads/a14-acpi-v2-pre-repair-$TS.txt"
STAGE="/var/tmp/a14-modules-stage-$TS"
OLD_MOD="/lib/modules/$KREL.pre-v2-mismatch-$TS"
OLD_INITRD="/boot/initrd.img-$KREL.pre-v2-mismatch-$TS"
HIST_SCRIPT="/run/a14-full-acpi-unrestricted-entry-74c9bd5.sh"
SNIPPET="/etc/grub.d/41_a14_full_acpi_checkpoint"
CAPTURE="/usr/local/sbin/a14-acpi-v2-autocapture"
UNIT="/etc/systemd/system/a14-acpi-v2-autocapture.service"
NEW_INITRD="/boot/initrd.img-$KREL.new-$TS"

for c in git make sha256sum awk grep sed find modinfo depmod dracut lsinitrd grub-reboot grub-editenv grub-script-check update-grub systemctl findmnt blkid journalctl; do need "$c"; done
[[ "$(uname -r)" != "$KREL" ]] || die "run this from the normal DT/rescue kernel"
[[ -f "$SRC/Makefile" && -f "$OUT/.config" ]] || die "validated ACPI source/build tree missing under $WORK"
[[ -s "$IMAGE" && -s "$OUT/vmlinux" ]] || die "validated ACPI build artifacts missing"
[[ -s "$KERNEL" && -s "$INITRD" ]] || die "installed ACPI kernel/initrd missing"
[[ -r "$STAMP" ]] || die "finalized build stamp missing: $STAMP"

# Never leave an old debug entry armed while repairing.
grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true
rm -f /etc/grub.d/41_a14_acpi_v2 /etc/grub.d/42_a14_acpi_v2_root_debug

# Preserve whatever evidence the previous ACPI attempt actually left behind.
{
    echo "timestamp=$(date --iso-8601=seconds 2>/dev/null || date)"
    echo "running_kernel=$(uname -a)"
    echo "cmdline=$(cat /proc/cmdline)"
    echo "===== CURRENT FSTAB ====="
    cat /etc/fstab 2>/dev/null || true
    echo "===== CURRENT UUIDS ====="
    blkid 2>/dev/null || true
    echo "===== CURRENT ROOT ====="
    findmnt -R / 2>/dev/null || true
    echo "===== JOURNAL BOOTS ====="
    journalctl --list-boots --no-pager 2>/dev/null || true
    echo "===== PREVIOUS BOOT HIGH SIGNAL ====="
    journalctl -b -1 --no-pager 2>/dev/null | grep -Ei 'acpi|dracut|initqueue|disk|uuid|nvme|pci|pcie|iort|smmu|iommu|root|mount|fail|timeout|QCOM0C0D|ROP1' || true
    echo "===== PREVIOUS KERNEL ====="
    journalctl -k -b -1 --no-pager 2>/dev/null || true
} >"$EVIDENCE" 2>&1
chown "$OWNER:$OWNER" "$EVIDENCE" 2>/dev/null || true

image_sha="$(sha256sum "$IMAGE" | awk '{print $1}')"
installed_sha="$(sha256sum "$KERNEL" | awk '{print $1}')"
[[ "$image_sha" == "$EXPECTED_IMAGE_SHA" ]] || die "build Image hash changed: $image_sha"
[[ "$installed_sha" == "$EXPECTED_IMAGE_SHA" ]] || die "installed Image hash changed: $installed_sha"
exact_release="$(sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -s -C "$SRC" O="$OUT" kernelrelease)"
[[ "$exact_release" == "$KREL" ]] || die "kernelrelease mismatch: $exact_release"

grep -q 'A14 ACPI: wrapperless GENI SE, TX FIFO depth' "$SRC/drivers/i2c/busses/i2c-qcom-geni.c" || die "wrong transformed source: GENI marker missing"
grep -q 'a14_iort_pcie_smmuv3_firmware_owned' "$SRC/drivers/acpi/arm64/iort.c" || die "wrong transformed source: IORT marker missing"
grep -q 'smmu-reset-after-scr0-write' "$SRC/drivers/iommu/arm/arm-smmu/arm-smmu.c" || die "wrong transformed source: SMMU marker missing"

say "A14_ACPI_V2_REPAIR_STAGE=1 matching-modules-build"
say "config_MODVERSIONS=$(sed -n 's/^CONFIG_MODVERSIONS=//p' "$OUT/.config" || true)"
say "config_NVME=$(sed -n 's/^CONFIG_BLK_DEV_NVME=//p' "$OUT/.config" || true)"
say "config_EXT4=$(sed -n 's/^CONFIG_EXT4_FS=//p' "$OUT/.config" || true)"
sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" modules
[[ "$(sha256sum "$IMAGE" | awk '{print $1}')" == "$EXPECTED_IMAGE_SHA" ]] || die "Image changed while building modules"
[[ -s "$OUT/Module.symvers" ]] || die "Module.symvers missing after modules build"

say "A14_ACPI_V2_REPAIR_STAGE=2 staged-modules-install"
rm -rf "$STAGE"
mkdir -p "$STAGE"
chown "$OWNER:$OWNER" "$STAGE"
sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= make -C "$SRC" O="$OUT" INSTALL_MOD_PATH="$STAGE" modules_install
STAGED_MOD="$STAGE/lib/modules/$KREL"
[[ -d "$STAGED_MOD" ]] || die "staged module tree missing"
sample="$(find "$STAGED_MOD/kernel" -type f \( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' -o -name '*.ko.gz' \) -print -quit)"
[[ -n "$sample" ]] || die "staged module tree is empty"
vermagic="$(modinfo -F vermagic "$sample" 2>/dev/null || true)"
[[ "$vermagic" == "$KREL"* ]] || die "staged module vermagic mismatch: $vermagic"

# Transactionally replace the old same-release modules; this is the key repair.
say "A14_ACPI_V2_REPAIR_STAGE=3 replace-mismatched-module-tree"
[[ -d "/lib/modules/$KREL" ]] || die "current module tree unexpectedly missing"
mv "/lib/modules/$KREL" "$OLD_MOD"
mv "$STAGED_MOD" "/lib/modules/$KREL"
ln -sfn "$OUT" "/lib/modules/$KREL/build"
ln -sfn "$SRC" "/lib/modules/$KREL/source"
depmod -a "$KREL"

# Build a GENERAL-PURPOSE Dracut image, not a host-only image inferred from the
# currently running DT kernel. Ubuntu 26.04 defaults to Dracut.
say "A14_ACPI_V2_REPAIR_STAGE=4 fresh-nonhostonly-dracut"
cp -a "$INITRD" "$OLD_INITRD"
rm -f "$NEW_INITRD"
dracut --force --no-hostonly "$NEW_INITRD" "$KREL"
[[ -s "$NEW_INITRD" ]] || die "Dracut did not produce a new initrd"

if grep -q '^CONFIG_BLK_DEV_NVME=m$' "$OUT/.config"; then
    lsinitrd "$NEW_INITRD" | grep -Eq '/nvme\.ko(\.|$)' || die "new Dracut image lacks modular NVMe driver"
fi
if grep -q '^CONFIG_EXT4_FS=m$' "$OUT/.config"; then
    lsinitrd "$NEW_INITRD" | grep -Eq '/ext4\.ko(\.|$)' || die "new Dracut image lacks modular ext4 driver"
fi
mv "$NEW_INITRD" "$INITRD"

# Install a capture service that runs immediately after switch-root, before
# local-fs.target can strand us on a secondary /etc/fstab disk job.
cat >"$CAPTURE" <<EOF2
#!/usr/bin/env bash
set -u
OWNER='$OWNER'
OWNER_HOME='$OWNER_HOME'
KREL='$KREL'
LOG='\$OWNER_HOME/Downloads/a14-acpi-v2-after-repair.txt'
[[ "\$(uname -r)" == "\$KREL" ]] || exit 0
grep -qw acpi=force /proc/cmdline || exit 0
exec >"\$LOG" 2>&1

echo 'A14_ACPI_AFTER_REPAIR_SWITCH_ROOT=PASS'
echo "timestamp=\$(date --iso-8601=seconds 2>/dev/null || date)"
echo "kernel=\$(uname -a)"
echo "cmdline=\$(cat /proc/cmdline)"
echo "root=\$(findmnt -n -o SOURCE,FSTYPE,OPTIONS / 2>/dev/null || true)"
echo '===== fstab ====='; cat /etc/fstab 2>/dev/null || true
echo '===== blkid ====='; blkid 2>/dev/null || true
echo '===== partitions ====='; cat /proc/partitions 2>/dev/null || true
echo '===== nvme ====='; ls -l /dev/nvme* 2>/dev/null || true
echo '===== pci ====='; lspci -nnk 2>/dev/null || true
echo '===== input ====='; cat /proc/bus/input/devices 2>/dev/null || true
echo '===== initial jobs ====='; systemctl list-jobs --no-pager 2>/dev/null || true
echo '===== initial failed ====='; systemctl --failed --no-pager 2>/dev/null || true
echo '===== high signal dmesg ====='; dmesg 2>/dev/null | grep -Ei 'acpi|dracut|nvme|pci|pcie|iort|smmu|iommu|tlmm|gpio|geni|QCOM0C0D|ROP1|root|mount|fail|timeout' || true
sync
sleep 45
echo '===== jobs after 45 sec ====='; systemctl list-jobs --no-pager 2>/dev/null || true
echo '===== failed after 45 sec ====='; systemctl --failed --no-pager 2>/dev/null || true
echo '===== kernel journal ====='; journalctl -k -b --no-pager 2>/dev/null || true
echo '===== full boot journal ====='; journalctl -b --no-pager 2>/dev/null || true
echo 'A14_ACPI_AFTER_REPAIR_CAPTURE_COMPLETE=1'
chown '$OWNER:$OWNER' "\$LOG" 2>/dev/null || true
grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true
systemctl disable a14-acpi-v2-autocapture.service >/dev/null 2>&1 || true
sync
systemctl reboot --force --force || reboot -f
EOF2
chmod 0755 "$CAPTURE"

cat >"$UNIT" <<EOF2
[Unit]
Description=ASUS A14 ACPI v2 early unattended capture
DefaultDependencies=no
After=systemd-journald.service
Before=local-fs.target
ConditionKernelCommandLine=acpi=force

[Service]
Type=oneshot
ExecStart=$CAPTURE
TimeoutStartSec=0

[Install]
WantedBy=sysinit.target
EOF2
systemctl daemon-reload
systemctl enable a14-acpi-v2-autocapture.service >/dev/null

# Regenerate the exact historical no-DTB entry from the commit which previously
# reached root. Do not use later experimental GRUB generators.
say "A14_ACPI_V2_REPAIR_STAGE=5 exact-historical-acpi-entry"
if ! sudo -u "$OWNER" git -C "$ROOT" cat-file -e "$GOOD_COMMIT^{commit}" 2>/dev/null; then
    sudo -u "$OWNER" git -C "$ROOT" fetch origin "$GOOD_COMMIT"
fi
sudo -u "$OWNER" git -C "$ROOT" show "$GOOD_COMMIT:scripts/a14-full-acpi-unrestricted-entry.sh" >"$HIST_SCRIPT"
chmod 0700 "$HIST_SCRIPT"
A14_ACPI_SPLASH=0 bash "$HIST_SCRIPT"
[[ -s "$SNIPPET" ]] || die "historical GRUB snippet not generated"

# No shell is useful on this machine yet. If Dracut still cannot get storage,
# reboot automatically rather than hanging in initqueue/emergency forever.
sed -i -E '/^[[:space:]]*linux[[:space:]]/ s/[[:space:]]*$/ rd.shell=0 rd.emergency=reboot rd.retry=45 rd.timeout=60/' "$SNIPPET"
update-grub
grub-script-check /boot/grub/grub.cfg >/dev/null
linux_line="$(awk '/^menuentry .*ACPI-ONLY UNRESTRICTED/{seen=1} seen && /^[[:space:]]*linux[[:space:]]/{print; exit}' "$SNIPPET")"
[[ -n "$linux_line" ]] || die "historical ACPI linux line missing"
for req in 'acpi=force' 'rd.shell=0' 'rd.emergency=reboot' 'rd.retry=45' 'rd.timeout=60' 'clk_ignore_unused' 'pd_ignore_unused' 'cma=128M' 'efi=noruntime' 'stubble.dtb_override=false'; do
    grep -Fq "$req" <<<"$linux_line" || die "final ACPI entry lacks $req"
done
! grep -Eq '^[[:space:]]*devicetree[[:space:]]' "$SNIPPET" || die "final ACPI entry loads a DTB"

# Verify the installed module tree is the one just built, then arm exactly one boot.
newsample="$(find "/lib/modules/$KREL/kernel" -type f \( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' -o -name '*.ko.gz' \) -print -quit)"
[[ -n "$newsample" ]] || die "installed rebuilt module tree is empty"
newvermagic="$(modinfo -F vermagic "$newsample" 2>/dev/null || true)"
[[ "$newvermagic" == "$KREL"* ]] || die "installed rebuilt module vermagic mismatch"

grub-reboot "$ENTRY"
next="$(grub-editenv /boot/grub/grubenv list | sed -n 's/^next_entry=//p' | head -n1)"
[[ "$next" == "$ENTRY" ]] || die "failed to arm expected ACPI entry: ${next:-missing}"

say "A14_ACPI_V2_REPAIR_AND_BOOT=READY"
say "matching_modules_built=true"
say "module_tree_backup=$OLD_MOD"
say "old_initrd_backup=$OLD_INITRD"
say "new_initrd=$INITRD"
say "dracut_nonhostonly=true"
say "pre_repair_evidence=$EVIDENCE"
say "success_capture=$OWNER_HOME/Downloads/a14-acpi-v2-after-repair.txt"
say "next_entry=$next"
say "local_input_required=false"
say "storage_failure_behavior=dracut-auto-reboot"
say "switch_root_success_behavior=auto-capture-then-reboot"
say "linux_line=$linux_line"
sync
sleep 3
systemctl reboot
