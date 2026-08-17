#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Collect evidence after an unexpected whole-system freeze/reboot on the A14.
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "ERROR: run with sudo/root" >&2
    exit 1
fi

owner="${SUDO_USER:-root}"
if [[ "$owner" == root ]]; then
    owner_home=/root
else
    owner_home="$(getent passwd "$owner" | cut -d: -f6)"
fi
[[ -n "$owner_home" ]] || { echo "ERROR: cannot resolve owner home" >&2; exit 1; }

ts="$(date +%Y%m%d-%H%M%S)"
out="$owner_home/Downloads/a14-system-reboot-$ts"
archive="$out.tar.xz"
mkdir -p "$out"

{
    echo "capture_time=$(date --iso-8601=seconds)"
    echo "running_kernel=$(uname -r)"
    echo "uname=$(uname -a)"
    echo "cmdline=$(cat /proc/cmdline)"
    echo "uptime=$(cat /proc/uptime)"
} > "$out/current-boot.txt"

# Preserve several prior boots because the target crash may not be -1 if the
# user has already rebooted again.
for n in 1 2 3 4; do
    journalctl -b "-$n" -k --no-pager > "$out/kernel-boot-minus-$n.log" 2>&1 || true
    journalctl -b "-$n" --no-pager > "$out/full-boot-minus-$n.log" 2>&1 || true
done

journalctl --list-boots --no-pager > "$out/journal-boots.txt" 2>&1 || true
last -x > "$out/last-x.txt" 2>&1 || true

# Focused kernel fault extraction from the prior boots.
for n in 1 2 3 4; do
    {
        echo "===== boot -$n ====="
        journalctl -b "-$n" -k --no-pager 2>/dev/null | \
          grep -Ei 'panic|oops|BUG:|SError|watchdog|soft lockup|hard lockup|rcu.*stall|hung task|timeout|reset|reboot|drm|gpu|adreno|msm|dpu|display|iommu|smmu|pcie|aer|nvme|acpi|firmware|qcom|remoteproc|fatal|segfault|general protection|page fault|machine check' || true
    } > "$out/focused-boot-minus-$n.log"
done

# pstore may contain firmware/kernel crash evidence from the prior reset.
mkdir -p "$out/pstore"
cp -a /sys/fs/pstore/. "$out/pstore/" 2>/dev/null || true

# GNOME Control Center / shell / compositor crashes around the incident.
if command -v coredumpctl >/dev/null 2>&1; then
    coredumpctl list --no-pager > "$out/coredump-list.txt" 2>&1 || true
    coredumpctl info gnome-control-center --no-pager > "$out/coredump-gnome-control-center.txt" 2>&1 || true
    coredumpctl info gnome-shell --no-pager > "$out/coredump-gnome-shell.txt" 2>&1 || true
    coredumpctl info Xwayland --no-pager > "$out/coredump-xwayland.txt" 2>&1 || true
fi

# Current hardware/driver state after reboot.
{
    echo '===== PCI ====='
    lspci -nnk 2>/dev/null || true
    echo '===== DRM ====='
    ls -l /sys/class/drm 2>/dev/null || true
    echo '===== modules ====='
    lsmod 2>/dev/null | grep -Ei 'msm|drm|gpu|adreno|qcom|nvme|pcie' || true
} > "$out/current-hardware.txt"

# Relevant persistent logs around desktop startup/current boot too.
journalctl -b --no-pager | grep -Ei 'gnome-control-center|gnome-shell|mutter|drm|gpu|adreno|msm|dpu|watchdog|SError|reset|firmware|qcom' > "$out/current-focused.log" 2>&1 || true

chown -R "$owner":"$(id -gn "$owner")" "$out" 2>/dev/null || true

tar -C "$(dirname "$out")" -cJf "$archive" "$(basename "$out")"
chown "$owner":"$(id -gn "$owner")" "$archive" 2>/dev/null || true

cat <<EOF
A14_SYSTEM_REBOOT_CAPTURE=COMPLETE
directory=$out
archive=$archive
EOF
