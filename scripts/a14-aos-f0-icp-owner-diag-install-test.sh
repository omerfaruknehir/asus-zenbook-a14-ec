#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Install a one-shot isolated boot for the full-F0 ICP owner diagnostic.
set -Eeuo pipefail

release=${A14_KERNEL_RELEASE:-$(uname -r)}
stage=${A14_AOS_F0_ICP_OWNER_STAGE:-"$HOME/Downloads/a14-aos-f0-icp-owner-diag-$release/artifacts"}
work=${A14_AOS_F0_ICP_OWNER_INSTALL_WORK:-"$HOME/Downloads/a14-aos-f0-icp-owner-test-boot-$release"}
base_dtb=${A14_AOS_BASE_DTB:-"/boot/dtb-$release-hm1092-v6-ir-cci"}
test_dtb="/boot/dtb-$release-f0-icp-owner-hm1092-test"
test_initrd="/boot/initrd.img-$release-f0-icp-owner-test"
grub_script=/etc/grub.d/41_a14_f0_icp_owner_test
entry_id=a14-f0-icp-owner-test
entry_title="ASUS Zenbook A14 F0 ICP owner diagnostic ($release)"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for tool in cat cp depmod fdtoverlay fdtget findmnt grep install lsinitramfs \
            mkinitramfs modinfo readlink sed sha256sum sudo update-grub zstd xz gzip; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this installer as your normal user, not with sudo"

[ -r "$base_dtb" ] || fail "base HM1092 DTB is missing: $base_dtb"
[ -s "$stage/qcom-camss.ko" ] || fail "staged diagnostic CAMSS module is missing"
[ -s "$stage/i2c-qcom-cci.ko" ] || fail "staged CCI owner module is missing"
[ -s "$stage/a14-f0-icp-owner-overlay.dtbo" ] || fail "staged CAMSS overlay is missing"
[ -s "$stage/BUILD-INFO.txt" ] || fail "staged BUILD-INFO is missing"
[ -s "$stage/SHA256SUMS" ] || fail "staged SHA256SUMS is missing"
[ -e "/boot/vmlinuz-$release" ] || fail "kernel image was not found"
[ -e "/boot/initrd.img-$release" ] || fail "stock initramfs was not found"
[ -d /etc/initramfs-tools ] || fail "initramfs-tools configuration is missing"

mkdir -p "$work"
printf '%s\n' 'A14 full-F0 ICP owner one-shot installer'
printf '%s\n' '========================================='
printf 'kernel_release=%s\n' "$release"
printf 'stage=%s\n' "$stage"
printf 'base_dtb=%s\n' "$base_dtb"
printf '%s\n' 'default_boot_unchanged=true'
printf '%s\n' 'ssc_activation_allowed=false'
printf '%s\n' 'direct_cpas_mmio_allowed=false'

printf '\n%s\n' '===== VERIFY STAGED PAYLOAD ====='
(
    cd "$stage"
    sha256sum -c SHA256SUMS
)
grep -Fqx 'diagnostic_generation=platform-power-f0-icp-real-owners-no-mmio-v1' \
    "$stage/BUILD-INFO.txt" || fail "unexpected diagnostic generation"
grep -Fqx 'uses_production_icp_handles=true' "$stage/BUILD-INFO.txt" || \
    fail "payload does not use production ICP handles"
grep -Fqx 'uses_production_cci_hold_api=true' "$stage/BUILD-INFO.txt" || \
    fail "payload does not use production CCI hold API"
grep -Fqx 'direct_cpas_mmio_allowed=false' "$stage/BUILD-INFO.txt" || fail "payload allows CPAS MMIO"
grep -Fqx 'ssc_activation_allowed=false' "$stage/BUILD-INFO.txt" || fail "payload allows SSC"
case "$(modinfo -F vermagic "$stage/qcom-camss.ko")" in "$release "*) ;; *) fail "CAMSS vermagic mismatch" ;; esac
case "$(modinfo -F vermagic "$stage/i2c-qcom-cci.ko")" in "$release "*) ;; *) fail "CCI vermagic mismatch" ;; esac
printf '%s\n' 'staged_payload=validated'

printf '\n%s\n' '===== VERIFY HM1092 BASE SYMBOLS ====='
camcc_path=$(fdtget -t s "$base_dtb" /__symbols__ camcc 2>/dev/null || true)
gcc_path=$(fdtget -t s "$base_dtb" /__symbols__ gcc 2>/dev/null || true)
[ -n "$camcc_path" ] || fail "base HM1092 DTB lacks __symbols__/camcc; symbolic merge is unsafe"
[ -n "$gcc_path" ] || fail "base HM1092 DTB lacks __symbols__/gcc; symbolic merge is unsafe"
printf 'camcc_symbol=%s\n' "$camcc_path"
printf 'gcc_symbol=%s\n' "$gcc_path"

printf '\n%s\n' '===== MERGE PRODUCTION CAMSS OWNER RESOURCES ====='
merged_dtb="$work/dtb-$release-f0-icp-owner-hm1092-test"
fdtoverlay -i "$base_dtb" -o "$merged_dtb" "$stage/a14-f0-icp-owner-overlay.dtbo"
camss_node=/soc@0/isp@acb7000
read -r -a reg_names <<< "$(fdtget -t s "$merged_dtb" "$camss_node" reg-names)"
[ "${#reg_names[@]}" -eq 18 ] || fail "merged DTB has ${#reg_names[@]} CAMSS resources, expected 18"
[ "${reg_names[17]}" = cpas-top ] || fail "merged DTB does not end with cpas-top"
read -r -a clock_names <<< "$(fdtget -t s "$merged_dtb" "$camss_node" clock-names)"
[ "${#clock_names[@]}" -eq 31 ] || fail "merged DTB has ${#clock_names[@]} CAMSS clocks, expected 31"
[ "${clock_names[29]}" = icp_ahb ] || fail "merged DTB clock 29 is not icp_ahb"
[ "${clock_names[30]}" = icp ] || fail "merged DTB clock 30 is not icp"
base_model=$(fdtget -t s "$base_dtb" / model)
merged_model=$(fdtget -t s "$merged_dtb" / model)
[ "$base_model" = "$merged_model" ] || fail "merged DTB model changed unexpectedly"
printf 'merged_dtb_model=%s\n' "$merged_model"
printf '%s\n' 'merged_dtb=validated-hm1092-plus-cpas-plus-icp-consumers'

printf '\n%s\n' '===== BUILD ISOLATED INITRAMFS ====='
confdir="$work/initramfs-tools"
rm -rf "$confdir"
cp -a /etc/initramfs-tools "$confdir"
mkdir -p "$confdir/hooks"
hook="$confdir/hooks/a14-f0-icp-owner-test"
cat > "$hook" <<EOF_HOOK
#!/bin/sh
PREREQ=""
prereqs() { echo "\$PREREQ"; }
case "\${1:-}" in
    prereqs) prereqs; exit 0 ;;
esac
. /usr/share/initramfs-tools/hook-functions
[ "\$version" = "$release" ] || exit 0

force_load i2c_qcom_cci
force_load qcom_camss

install_override() {
    name=\$1
    source=\$2
    stock=\$(modinfo -k "\$version" -n "\$name")
    rel=\${stock#/lib/modules/\$version/}
    dest="\$DESTDIR/lib/modules/\$version/\$rel"
    mkdir -p "\$(dirname "\$dest")"
    case "\$dest" in
        *.ko.zst) zstd -q -f -19 "\$source" -o "\$dest" ;;
        *.ko.xz)  xz -C crc32 -9 -c "\$source" > "\$dest" ;;
        *.ko.gz)  gzip -9 -c "\$source" > "\$dest" ;;
        *.ko)     cp "\$source" "\$dest" ;;
        *) echo "Unsupported module compression: \$dest" >&2; exit 1 ;;
    esac
}

install_override i2c_qcom_cci "$stage/i2c-qcom-cci.ko"
install_override qcom_camss "$stage/qcom-camss.ko"
depmod -a -b "\$DESTDIR" "\$version"
EOF_HOOK
chmod 0755 "$hook"

tmp_initrd="$work/initrd.img-$release-f0-icp-owner-test.tmp"
rm -f "$tmp_initrd"
sudo mkinitramfs -d "$confdir" -o "$tmp_initrd" "$release"
[ -s "$tmp_initrd" ] || fail "custom initramfs was not produced"
initrd_list="$work/initramfs-contents.txt"
lsinitramfs "$tmp_initrd" > "$initrd_list"
grep -Fq 'qcom-camss.ko' "$initrd_list" || fail "custom initramfs lacks qcom-camss"
grep -Fq 'i2c-qcom-cci.ko' "$initrd_list" || fail "custom initramfs lacks i2c-qcom-cci"
printf '%s\n' 'custom_initramfs=validated'

printf '\n%s\n' '===== INSTALL TEST-ONLY BOOT FILES ====='
sudo install -m 0644 "$merged_dtb" "$test_dtb"
sudo install -m 0644 "$tmp_initrd" "$test_initrd"

# Validate privileged /boot writes by hashing the installed files through sudo.
merged_dtb_sha=$(sha256sum "$merged_dtb" | sed 's/[[:space:]].*$//')
installed_dtb_sha=$(sudo sha256sum "$test_dtb" | sed 's/[[:space:]].*$//')
[ "$merged_dtb_sha" = "$installed_dtb_sha" ] || fail "installed test DTB differs from validated merged DTB"
tmp_initrd_sha=$(sha256sum "$tmp_initrd" | sed 's/[[:space:]].*$//')
installed_initrd_sha=$(sudo sha256sum "$test_initrd" | sed 's/[[:space:]].*$//')
[ "$tmp_initrd_sha" = "$installed_initrd_sha" ] || fail "installed test initramfs differs from validated custom initramfs"
printf '%s\n' 'installed_boot_payload=validated-exact-hashes'

root_uuid=$(findmnt -no UUID /)
[ -n "$root_uuid" ] || fail "could not resolve root filesystem UUID"
cmdline=$(sed -E 's/(^| )BOOT_IMAGE=[^ ]+//; s/^ +//; s/ +$//' /proc/cmdline)
case " $cmdline " in
    *' a14_aos_f0_icp_owner_test=1 '*) ;;
    *) cmdline="$cmdline a14_aos_f0_icp_owner_test=1" ;;
esac

grub_tmp="$work/41_a14_f0_icp_owner_test"
cat > "$grub_tmp" <<EOF_GRUB
#!/bin/sh
exec tail -n +3 \$0
menuentry '$entry_title' --id '$entry_id' {
    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root $root_uuid
    linux /boot/vmlinuz-$release $cmdline
    initrd /boot/$(basename "$test_initrd")
    devicetree /boot/$(basename "$test_dtb")
}
EOF_GRUB
chmod 0755 "$grub_tmp"
sudo install -m 0755 "$grub_tmp" "$grub_script"
sudo update-grub

# /boot/grub/grub.cfg is commonly root-readable only. Snapshot it through sudo,
# then perform all final assertions as the unprivileged caller.
grub_cfg_snapshot="$work/grub.cfg.generated"
sudo cat /boot/grub/grub.cfg > "$grub_cfg_snapshot"
[ -s "$grub_cfg_snapshot" ] || fail "could not snapshot generated GRUB configuration"
grep -Fq "menuentry '$entry_title'" "$grub_cfg_snapshot" || fail "test GRUB entry was not generated"
grep -Fq "devicetree /boot/$(basename "$test_dtb")" "$grub_cfg_snapshot" || fail "GRUB entry lacks test DTB"
grep -Fq "initrd /boot/$(basename "$test_initrd")" "$grub_cfg_snapshot" || fail "GRUB entry lacks test initramfs"
printf '%s\n' 'grub_entry=validated-from-privileged-snapshot'

printf '\n%s\n' '===== INSTALLED TEST ENTRY ====='
printf 'grub_entry_id=%s\n' "$entry_id"
printf 'grub_entry_title=%s\n' "$entry_title"
printf 'test_dtb=%s\n' "$test_dtb"
printf 'test_initrd=%s\n' "$test_initrd"
printf '%s\n' 'default_boot_unchanged=true'
printf '%s\n' 'persistent_module_override=false'
printf '%s\n' 'ssc_activation_allowed=false'
printf '\nOne-shot test boot command:\n'
printf '  sudo grub-reboot %q && sudo reboot\n' "$entry_id"
printf '\nThe diagnostic still does nothing automatically after boot; the runner must be invoked manually.\n'
