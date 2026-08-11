#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Remove only the reversible A14 AOS/CPAS test boot entry and files.
set -Eeuo pipefail

release=${A14_KERNEL_RELEASE:-$(uname -r)}
test_dtb="/boot/dtb-$release-aos-cpas-hm1092-v6-test"
test_initrd="/boot/initrd.img-$release-aos-cpas-test"
grub_script=/etc/grub.d/41_a14_aos_test

[ "${EUID:-$(id -u)}" -ne 0 ] || {
    echo "Run this script as your normal user, not with sudo." >&2
    exit 1
}

sudo rm -f -- "$test_dtb" "$test_initrd" "$grub_script"
sudo update-grub

printf 'removed=%s\n' "$test_dtb"
printf 'removed=%s\n' "$test_initrd"
printf 'removed=%s\n' "$grub_script"
printf '%s\n' 'stock_kernel_modules_unchanged=true'
printf '%s\n' 'normal_hm1092_dtb_unchanged=true'
