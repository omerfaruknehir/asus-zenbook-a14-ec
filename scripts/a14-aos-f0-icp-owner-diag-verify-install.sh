#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Verify the already-installed isolated Stage C boot without changing the system.
set -Eeuo pipefail

release=${A14_KERNEL_RELEASE:-$(uname -r)}
work=${A14_AOS_F0_ICP_OWNER_INSTALL_WORK:-"$HOME/Downloads/a14-aos-f0-icp-owner-test-boot-$release"}
test_dtb="/boot/dtb-$release-f0-icp-owner-hm1092-test"
test_initrd="/boot/initrd.img-$release-f0-icp-owner-test"
entry_id=a14-f0-icp-owner-test
entry_title="ASUS Zenbook A14 F0 ICP owner diagnostic ($release)"
merged_dtb="$work/dtb-$release-f0-icp-owner-hm1092-test"
tmp_initrd="$work/initrd.img-$release-f0-icp-owner-test.tmp"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for tool in basename cat grep lsinitramfs sed sha256sum sudo uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this verifier as your normal user, not with sudo"
[ -s "$merged_dtb" ] || fail "validated merged DTB is missing from installer work: $merged_dtb"
[ -s "$tmp_initrd" ] || fail "validated custom initramfs is missing from installer work: $tmp_initrd"

printf '%s\n' 'A14 Stage C installed-boot verifier'
printf '%s\n' '=================================='
printf 'kernel_release=%s\n' "$release"
printf '%s\n' 'operation=read-only-verification'
printf '%s\n' 'hardware_activation=false'
printf '%s\n' 'ssc_activation=false'
printf '%s\n' 'direct_cpas_mmio=false'

printf '\n%s\n' '===== VERIFY INSTALLED BOOT PAYLOAD ====='
sudo test -s "$test_dtb" || fail "installed test DTB is missing: $test_dtb"
sudo test -s "$test_initrd" || fail "installed test initramfs is missing: $test_initrd"
merged_dtb_sha=$(sha256sum "$merged_dtb" | sed 's/[[:space:]].*$//')
installed_dtb_sha=$(sudo sha256sum "$test_dtb" | sed 's/[[:space:]].*$//')
[ "$merged_dtb_sha" = "$installed_dtb_sha" ] || fail "installed test DTB differs from validated merged DTB"
tmp_initrd_sha=$(sha256sum "$tmp_initrd" | sed 's/[[:space:]].*$//')
installed_initrd_sha=$(sudo sha256sum "$test_initrd" | sed 's/[[:space:]].*$//')
[ "$tmp_initrd_sha" = "$installed_initrd_sha" ] || fail "installed test initramfs differs from validated custom initramfs"
printf '%s\n' 'installed_boot_payload=validated-exact-hashes'

printf '\n%s\n' '===== VERIFY ISOLATED INITRAMFS CONTENTS ====='
initrd_list="$work/installed-initramfs-contents.txt"
sudo lsinitramfs "$test_initrd" > "$initrd_list"
grep -Fq 'qcom-camss.ko' "$initrd_list" || fail "installed test initramfs lacks qcom-camss"
grep -Fq 'i2c-qcom-cci.ko' "$initrd_list" || fail "installed test initramfs lacks i2c-qcom-cci"
if grep -Fq 'qcom_ssc_hpd' "$initrd_list" || grep -Fq 'qcom-ssc-hpd' "$initrd_list"; then
    fail "installed test initramfs contains qcom_ssc_hpd; refusing Stage C boot"
fi
printf '%s\n' 'installed_initramfs=no-ssc-camss-cci-validated'

printf '\n%s\n' '===== VERIFY GENERATED GRUB ENTRY ====='
grub_cfg_snapshot="$work/grub.cfg.installed"
sudo cat /boot/grub/grub.cfg > "$grub_cfg_snapshot"
[ -s "$grub_cfg_snapshot" ] || fail "could not snapshot generated GRUB configuration"
grep -Fq "menuentry '$entry_title' --id '$entry_id'" "$grub_cfg_snapshot" || fail "test GRUB entry/id was not generated"
grep -Fq "linux /boot/vmlinuz-$release" "$grub_cfg_snapshot" || fail "test GRUB entry lacks expected kernel"
grep -Fq 'a14_aos_f0_icp_owner_test=1' "$grub_cfg_snapshot" || fail "test GRUB entry lacks isolated-boot marker"
grep -Fq "initrd /boot/$(basename "$test_initrd")" "$grub_cfg_snapshot" || fail "test GRUB entry lacks test initramfs"
grep -Fq "devicetree /boot/$(basename "$test_dtb")" "$grub_cfg_snapshot" || fail "test GRUB entry lacks test DTB"
printf '%s\n' 'grub_entry=validated-id-kernel-initrd-dtb-marker'

printf '\n%s\n' '===== RESULT ====='
printf 'grub_entry_id=%s\n' "$entry_id"
printf '%s\n' 'installed_stage_c_boot=validated'
printf '%s\n' 'hardware_test_not_run=true'
printf '%s\n' 'safe_to_arm_one_shot=true'
