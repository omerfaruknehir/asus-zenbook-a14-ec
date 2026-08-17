#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Collect evidence left by a failed A14 full-ACPI boot while running the known-good DT kernel.
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "ERROR: run with sudo/root" >&2
    exit 1
fi

owner="${SUDO_USER:-root}"
if [[ "$owner" == root ]]; then
    owner_home="/root"
else
    owner_home="$(getent passwd "$owner" | cut -d: -f6)"
fi
[[ -n "$owner_home" ]] || { echo "ERROR: cannot resolve owner home" >&2; exit 1; }

ts="$(date +%Y%m%d-%H%M%S)"
out="$owner_home/Downloads/a14-full-acpi-crash-$ts"
archive="$out.tar.xz"
mkdir -p "$out"

{
    echo "capture_time=$(date --iso-8601=seconds)"
    echo "running_kernel=$(uname -r)"
    echo "uname=$(uname -a)"
    echo "cmdline=$(cat /proc/cmdline)"
} > "$out/current-boot.txt"

journalctl --list-boots --no-pager > "$out/journal-boots.txt" 2>&1 || true
journalctl -b -1 -k --no-pager > "$out/previous-boot-kernel.log" 2>&1 || true
journalctl -b -1 --no-pager > "$out/previous-boot.log" 2>&1 || true

dmesg > "$out/current-dmesg.log" 2>&1 || true

dmesg 2>/dev/null | grep -Ei 'pstore|efi|panic|watchdog|reset|reboot|ACPI' \
    > "$out/current-pstore-efi-summary.log" || true

if [[ -d /sys/fs/pstore ]]; then
    mkdir -p "$out/sys-fs-pstore"
    cp -a /sys/fs/pstore/. "$out/sys-fs-pstore/" 2>/dev/null || true
    ls -la /sys/fs/pstore > "$out/sys-fs-pstore-list.txt" 2>&1 || true
fi

if [[ -d /var/lib/systemd/pstore ]]; then
    mkdir -p "$out/systemd-pstore"
    cp -a /var/lib/systemd/pstore/. "$out/systemd-pstore/" 2>/dev/null || true
    find /var/lib/systemd/pstore -maxdepth 2 -type f -printf '%p\n' \
        > "$out/systemd-pstore-list.txt" 2>&1 || true
fi

if command -v efibootmgr >/dev/null 2>&1; then
    efibootmgr -v > "$out/efibootmgr.txt" 2>&1 || true
fi

{
    ls -l /boot/vmlinuz-7.1.5-a14-acpi-full0 \
          /boot/initrd.img-7.1.5-a14-acpi-full0 \
          /boot/config-7.1.5-a14-acpi-full0 2>&1 || true
    echo
    if [[ -f /etc/grub.d/41_a14_full_acpi ]]; then
        cat /etc/grub.d/41_a14_full_acpi
    else
        echo "GRUB snippet missing"
    fi
} > "$out/full-acpi-install-state.txt"

# Preserve the directory and also make one upload-friendly archive.
tar -C "$(dirname "$out")" -cJf "$archive" "$(basename "$out")"
chown -R "$owner":"$(id -gn "$owner" 2>/dev/null || echo "$owner")" "$out" "$archive" 2>/dev/null || true

printf '%s\n' "A14_FULL_ACPI_CRASH_CAPTURE=COMPLETE"
printf 'directory=%s\n' "$out"
printf 'archive=%s\n' "$archive"
