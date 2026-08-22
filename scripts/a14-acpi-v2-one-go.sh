#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# One-command unattended factory-ACPI boot/capture/recovery for ASUS UX3407RA.
set -euo pipefail

KREL="7.1.5-a14-acpi-full0"
GOOD_COMMIT="74c9bd5ebc77e2563b8be50d8cb4af67202c71fe"
EXPECTED_SHA="8c588e767e0466419744b235232676b324b294f1c4ad242b8a28560f7719466b"
ENTRY="ASUS Zenbook A14 — ACPI-ONLY UNRESTRICTED ($KREL)"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
KERNEL="/boot/vmlinuz-$KREL"
INITRD="/boot/initrd.img-$KREL"
HIST_SCRIPT="/run/a14-full-acpi-unrestricted-entry-74c9bd5.sh"
CAPTURE="/usr/local/sbin/a14-acpi-v2-one-go-capture"
UNIT="/etc/systemd/system/a14-acpi-v2-one-go-capture.service"
OWNER="${SUDO_USER:-}"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"
[[ -n "$OWNER" && "$OWNER" != root ]] || die "run with sudo from your normal login"
OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
[[ -n "$OWNER_HOME" && -d "$OWNER_HOME" ]] || die "cannot resolve owner home"

for c in git sha256sum update-grub grub-reboot grub-editenv grub-script-check systemctl awk grep sed sync; do need "$c"; done
[[ "$(uname -r)" != "$KREL" ]] || die "run this from the normal DT/rescue kernel"
[[ -s "$KERNEL" ]] || die "missing installed ACPI kernel: $KERNEL"
[[ -s "$INITRD" ]] || die "missing installed ACPI initrd: $INITRD"
actual_sha="$(sha256sum "$KERNEL" | awk '{print $1}')"
[[ "$actual_sha" == "$EXPECTED_SHA" ]] || die "installed ACPI kernel hash mismatch: $actual_sha"

# Extract the exact boot entry generator from the commit that previously
# reached NVMe root/switch-root, instead of using any later experimental copy.
if ! sudo -u "$OWNER" git -C "$ROOT" cat-file -e "$GOOD_COMMIT^{commit}" 2>/dev/null; then
    sudo -u "$OWNER" git -C "$ROOT" fetch origin "$GOOD_COMMIT"
fi
sudo -u "$OWNER" git -C "$ROOT" show "$GOOD_COMMIT:scripts/a14-full-acpi-unrestricted-entry.sh" >"$HIST_SCRIPT"
chmod 0700 "$HIST_SCRIPT"
grep -Fq 'BOOT_UI_ARGS="earlycon=efifb,ram console=tty0 loglevel=8 ignore_loglevel printk.time=1"' "$HIST_SCRIPT" || die "historical boot UI does not match 74c9 checkpoint"
grep -Fq 'cmdline="${args[*]} $BOOT_UI_ARGS acpi=force"' "$HIST_SCRIPT" || die "historical cmdline construction mismatch"

# Remove stale experimental selections/entries before regenerating the proven one.
grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true
rm -f /etc/grub.d/41_a14_acpi_v2 /etc/grub.d/42_a14_acpi_v2_root_debug

# If root comes up, capture everything automatically; local input is unnecessary.
cat >"$CAPTURE" <<EOF2
#!/usr/bin/env bash
set -u
KREL='$KREL'
OWNER='$OWNER'
OWNER_HOME='$OWNER_HOME'
LOG='/var/log/a14-acpi-v2-one-go.txt'
DL='$OWNER_HOME/Downloads/a14-acpi-v2-one-go.txt'
[[ "\$(uname -r)" == "\$KREL" ]] || exit 0
grep -qw acpi=force /proc/cmdline || exit 0
[[ -d /sys/firmware/acpi/tables ]] || exit 0
[[ ! -e /proc/device-tree/model ]] || exit 0
mkdir -p "\$(dirname "\$DL")"
exec > >(tee "\$LOG") 2>&1

echo 'A14_ACPI_ONE_GO_ROOT_REACHED=1'
echo "timestamp=\$(date --iso-8601=seconds 2>/dev/null || date)"
echo "kernel=\$(uname -a)"
echo "cmdline=\$(cat /proc/cmdline)"
echo "root=\$(findmnt -n -o SOURCE,FSTYPE,OPTIONS / 2>/dev/null || true)"
echo "boot_id=\$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
cp -f "\$LOG" "\$DL" 2>/dev/null || true
chown '$OWNER:$OWNER' "\$DL" 2>/dev/null || true
sync
sleep 45

echo '===== ACPI / DT ====='
printf 'acpi_tables='; [[ -d /sys/firmware/acpi/tables ]] && echo present || echo absent
printf 'device_tree='; [[ -e /proc/device-tree/model ]] && echo present || echo absent
ls -l /sys/firmware/acpi/tables 2>/dev/null || true

echo '===== BLOCK / ROOT ====='
cat /proc/partitions 2>/dev/null || true
lsblk -o NAME,MAJ:MIN,SIZE,FSTYPE,FSVER,LABEL,UUID,MOUNTPOINTS 2>/dev/null || true
findmnt -R / 2>/dev/null || true
ls -l /dev/nvme* 2>/dev/null || true

echo '===== PCI ====='
lspci -nnk 2>/dev/null || true

echo '===== IOMMU ====='
for g in /sys/kernel/iommu_groups/*; do [[ -e "\$g" ]] || continue; echo "group \${g##*/}"; ls -l "\$g/devices" 2>/dev/null || true; done

echo '===== ACPI DEVICES ====='
for d in /sys/bus/acpi/devices/*; do
    [[ -d "\$d" ]] || continue
    printf '%s hid=' "\${d##*/}"
    cat "\$d/hid" 2>/dev/null || printf '?'
    printf ' path='; cat "\$d/path" 2>/dev/null || true
    printf ' driver='; basename "\$(readlink -f "\$d/driver" 2>/dev/null)" 2>/dev/null || true
    echo
done

echo '===== PLATFORM DEVICES ====='
for d in /sys/bus/platform/devices/*; do
    [[ -e "\$d" ]] || continue
    printf '%s driver=' "\${d##*/}"
    basename "\$(readlink -f "\$d/driver" 2>/dev/null)" 2>/dev/null || true
    echo
done

echo '===== INPUT ====='
cat /proc/bus/input/devices 2>/dev/null || true

echo '===== NETWORK ====='
ip -details link 2>/dev/null || true

echo '===== SYSTEMD FAILED ====='
systemctl --failed --no-pager 2>/dev/null || true

echo '===== HIGH SIGNAL DMESG ====='
dmesg 2>/dev/null | grep -Ei 'acpi|nvme|pci|pcie|iort|smmu|iommu|qcom|tlmm|gpio|geni|serialbus|rop1|error|fail|timeout|root|ext4|vfs' || true

echo '===== FULL DMESG ====='
dmesg 2>/dev/null || true

echo '===== KERNEL JOURNAL ====='
journalctl -k -b --no-pager 2>/dev/null || true

echo 'A14_ACPI_ONE_GO_CAPTURE_COMPLETE=1'
cp -f "\$LOG" "\$DL" 2>/dev/null || true
chown '$OWNER:$OWNER' "\$DL" 2>/dev/null || true
grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true
systemctl disable a14-acpi-v2-one-go-capture.service >/dev/null 2>&1 || true
sync
echo 'A14_ACPI_ONE_GO_REBOOTING_TO_DT=1'
systemctl reboot --force --force || reboot -f
EOF2
chmod 0755 "$CAPTURE"

cat >"$UNIT" <<EOF2
[Unit]
Description=ASUS A14 unattended ACPI-only capture and return-to-DT
After=local-fs.target systemd-journald.service
ConditionKernelCommandLine=acpi=force

[Service]
Type=oneshot
ExecStart=$CAPTURE
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF2
systemctl daemon-reload
systemctl enable a14-acpi-v2-one-go-capture.service >/dev/null

# Generate the exact known-good 74c9 no-DTB entry from this DT boot's baseline.
A14_ACPI_SPLASH=0 bash "$HIST_SCRIPT"
SNIPPET=/etc/grub.d/41_a14_full_acpi_checkpoint
[[ -s "$SNIPPET" ]] || die "historical GRUB snippet was not generated"

# Only deliberate deviation: panic=30. initramfs-tools treats a positive panic
# timeout as no-recovery-shell + automatic reboot, which handles missing input.
sed -i -E '/^[[:space:]]*linux[[:space:]]/ s/[[:space:]]*$/ panic=30/' "$SNIPPET"
update-grub

grub-script-check /boot/grub/grub.cfg >/dev/null
linux_line="$(awk '/^menuentry .*ACPI-ONLY UNRESTRICTED/{seen=1} seen && /^[[:space:]]*linux[[:space:]]/{print; exit}' "$SNIPPET")"
[[ -n "$linux_line" ]] || die "cannot find ACPI linux line"
for required in 'acpi=force' 'panic=30' 'earlycon=efifb,ram' 'console=tty0' 'clk_ignore_unused' 'pd_ignore_unused' 'cma=128M' 'efi=noruntime' 'stubble.dtb_override=false'; do
    grep -Fq "$required" <<<"$linux_line" || die "ACPI entry lacks $required"
done
! grep -Eq '^[[:space:]]*devicetree[[:space:]]' "$SNIPPET" || die "ACPI entry loads a DTB"
! grep -Eq '(^|[[:space:]])break=' <<<"$linux_line" || die "ACPI entry still contains break="
! grep -Eq '(^|[[:space:]])debug(=|[[:space:]])' <<<"$linux_line" || die "ACPI entry still contains debug-shell arguments"

grub-reboot "$ENTRY"
next="$(grub-editenv /boot/grub/grubenv list | sed -n 's/^next_entry=//p' | head -n1)"
[[ "$next" == "$ENTRY" ]] || die "failed to arm expected one-shot entry: ${next:-missing}"

sync
say 'A14_ACPI_V2_ONE_GO=ARMED'
say "running_kernel=$(uname -r)"
say "target_kernel=$KERNEL"
say "target_sha256=$actual_sha"
say "entry=$ENTRY"
say "next_entry=$next"
say "capture_log=$OWNER_HOME/Downloads/a14-acpi-v2-one-go.txt"
say 'acpi_interaction_required=false'
say 'root_failure_behavior=automatic-reboot-after-30s'
say 'root_success_behavior=automatic-capture-then-reboot-to-DT'
say 'hardware_dtb_loaded=false'
say "linux_line=$linux_line"
say 'rebooting_now=true'
sleep 3
systemctl reboot
