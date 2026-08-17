#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Remove all installed full-ACPI experiment GRUB/kernel artifacts while keeping
# the already-built source/output tree under ~/Downloads/a14-full-acpi-kernel.
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "ERROR: run with sudo/root" >&2
    exit 1
fi

KREL=7.1.5-a14-acpi-full0

if [[ "$(uname -r)" == "$KREL" ]]; then
    echo "ERROR: currently running $KREL; boot a known-good non-experimental kernel first" >&2
    exit 1
fi

for c in update-grub depmod; do
    command -v "$c" >/dev/null 2>&1 || { echo "ERROR: missing command: $c" >&2; exit 1; }
done

# Custom GRUB entries and debug backups.
rm -f \
    /etc/grub.d/41_a14_full_acpi \
    /etc/grub.d/41_a14_full_acpi.before-debug \
    /etc/grub.d/42_a14_full_acpi_dt_control

# Control DTB copied from the known-good live FDT.
rm -rf /boot/a14-full-acpi-control

# Remove the installed experimental kernel so Ubuntu's 10_linux generator no
# longer creates additional automatic menu/submenu entries for it.
rm -f \
    "/boot/vmlinuz-$KREL" \
    "/boot/initrd.img-$KREL" \
    "/boot/System.map-$KREL" \
    "/boot/config-$KREL"
rm -rf "/lib/modules/$KREL"

# Clean stale initramfs fragments if any were left by interrupted installs.
rm -f "/boot/initrd.img-$KREL.new" "/boot/initrd.img-$KREL.old"

# Rebuild module deps for the running kernel and regenerate the complete GRUB menu.
depmod -a "$(uname -r)" || true
update-grub

echo "A14_FULL_ACPI_GRUB_CLEAN=COMPLETE"
echo "removed_kernel=$KREL"
echo "preserved_build_tree=${SUDO_USER:+/home/$SUDO_USER/Downloads/a14-full-acpi-kernel}"
echo "The compiled source/build tree was not deleted."
