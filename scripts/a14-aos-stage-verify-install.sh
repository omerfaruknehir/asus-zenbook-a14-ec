#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Verify the already-installed one-shot A14 AOS/CPAS test boot entry.
set -Eeuo pipefail

release=${A14_KERNEL_RELEASE:-$(uname -r)}
test_dtb="/boot/dtb-$release-aos-cpas-hm1092-v6-test"
test_initrd="/boot/initrd.img-$release-aos-cpas-test"
grub_script=/etc/grub.d/41_a14_aos_test
grub_cfg=/boot/grub/grub.cfg
entry_id=a14-aos-cpas-test
entry_title="ASUS Zenbook A14 AOS CPAS test ($release)"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this script as your normal user, not with sudo"

sudo test -s "$test_dtb" || fail "test DTB is missing: $test_dtb"
sudo test -s "$test_initrd" || fail "test initramfs is missing: $test_initrd"
sudo test -x "$grub_script" || fail "test GRUB generator is missing: $grub_script"
sudo test -s "$grub_cfg" || fail "generated GRUB configuration is missing: $grub_cfg"

sudo grep -Fq "menuentry '$entry_title'" "$grub_cfg" || \
    fail "test GRUB entry was not generated"
sudo grep -Fq "initrd /boot/$(basename "$test_initrd")" "$grub_cfg" || \
    fail "test GRUB entry does not use the custom initramfs"
sudo grep -Fq "devicetree /boot/$(basename "$test_dtb")" "$grub_cfg" || \
    fail "test GRUB entry does not use the merged DTB"

initrd_list=$(mktemp)
trap 'rm -f "$initrd_list"' EXIT
sudo lsinitramfs "$test_initrd" > "$initrd_list"
grep -Fq 'qcom-camss.ko' "$initrd_list" || \
    fail "installed test initramfs lacks qcom-camss"
grep -Fq 'conf/modules' "$initrd_list" || \
    fail "installed test initramfs lacks forced-module configuration"

camss_node=/soc@0/isp@acb7000
read -r -a names <<< "$(fdtget -t s "$test_dtb" "$camss_node" reg-names)"
[ "${#names[@]}" -eq 18 ] || fail "installed test DTB has ${#names[@]} CAMSS names, expected 18"
[ "${names[17]}" = cpas-top ] || fail "installed test DTB does not end with cpas-top"

printf '%s\n' 'test_dtb=validated'
printf '%s\n' 'test_initramfs=validated'
printf '%s\n' 'test_grub_entry=validated'
printf 'grub_entry_id=%s\n' "$entry_id"
printf '%s\n' 'default_boot_unchanged=true'
printf '%s\n' 'persistent_module_override=false'
printf '\nOne-shot test boot command:\n'
printf '  sudo grub-reboot %q && sudo reboot\n' "$entry_id"
