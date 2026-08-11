#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Install the F0 CCI-rate diagnostic as a separate isolated boot entry.
set -Eeuo pipefail

release=${A14_KERNEL_RELEASE:-$(uname -r)}
stage=${A14_AOS_F0_CCI_RATE_STAGE:-"$HOME/Downloads/a14-aos-f0-cci-rate-diag-$release/artifacts"}
work=${A14_AOS_F0_CCI_RATE_INSTALL_WORK:-"$HOME/Downloads/a14-aos-f0-cci-rate-test-boot-$release"}
test_dtb="/boot/dtb-$release-aon-f0-cci-rate-test"
test_initrd="/boot/initrd.img-$release-aon-f0-cci-rate-test"
grub_script=/etc/grub.d/44_a14_aon_f0_cci_rate_test
entry_id=a14-aon-f0-cci-rate-test
entry_title="ASUS Zenbook A14 AON F0 CCI rate diagnostic ($release)"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for tool in basename cat cp depmod findmnt gzip install lsinitramfs mkinitramfs modinfo readlink sed sha256sum sudo update-grub xz zstd; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done

[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this script as your normal user, not with sudo"
[ -s "$stage/i2c-qcom-cci.ko" ] || fail "CCI-rate diagnostic module artifact is missing"
[ -s "$stage/BUILD-INFO.txt" ] || fail "CCI-rate diagnostic BUILD-INFO.txt is missing"
[ -s "$stage/SHA256SUMS" ] || fail "CCI-rate diagnostic SHA256SUMS is missing"
[ -e "/boot/vmlinuz-$release" ] || fail "kernel image was not found"
[ -e "/boot/initrd.img-$release" ] || fail "stock initramfs was not found"
[ -d /etc/initramfs-tools ] || fail "initramfs-tools configuration is missing"

case " $(cat /proc/cmdline) " in
    *' a14_aos_power_test=1 '*|*' a14_aos_f0_rate_test=1 '*|*' a14_aos_f0_cci_rate_test=1 '*)
        fail "return to the normal Ubuntu boot before installing this diagnostic entry" ;;
esac

(cd "$stage" && sha256sum -c SHA256SUMS)
grep -Fqx 'diagnostic_only=true' "$stage/BUILD-INFO.txt" || fail "artifact is not diagnostic-only"
grep -Fqx 'diagnostic_generation=platform-power-f0-cci-rate-no-cpas-mmio-v1' "$stage/BUILD-INFO.txt" || fail "artifact is not the CCI-rate diagnostic"
grep -Fqx 'dtb_changes=false' "$stage/BUILD-INFO.txt" || fail "artifact unexpectedly requires DTB changes"
grep -Fqx 'direct_cpas_mmio_allowed=false' "$stage/BUILD-INFO.txt" || fail "artifact does not prohibit CPAS MMIO"
grep -Fqx 'ssc_activation_allowed=false' "$stage/BUILD-INFO.txt" || fail "artifact does not prohibit SSC activation"
grep -Fqx 'restore_original_rate=true' "$stage/BUILD-INFO.txt" || fail "artifact does not restore the original CCI rate"
grep -Fqx 'exact_round_rate_required=true' "$stage/BUILD-INFO.txt" || fail "artifact does not require exact 37.5 MHz support"
case "$(modinfo -F vermagic "$stage/i2c-qcom-cci.ko")" in "$release "*) ;; *) fail "CCI-rate diagnostic module vermagic does not match $release" ;; esac
grep -aFq 'AON-F0-CCI-RATE-DIAG begin' "$stage/i2c-qcom-cci.ko" || fail "selected CCI module lacks the diagnostic"

if [ -n "${A14_AOS_F0_CCI_RATE_BASE_DTB:-}" ]; then
    base_dtb=$A14_AOS_F0_CCI_RATE_BASE_DTB
else
    base_dtb=
    for candidate in "/boot/dtb-$release-hm1092-v6-ir-cci" "/boot/dtb-$release-hm1092-v6" "/boot/dtb-$release"; do
        if [ -r "$candidate" ]; then base_dtb=$candidate; break; fi
    done
fi
[ -n "$base_dtb" ] || fail "no usable A14 base DTB was found"
[ -r "$base_dtb" ] || fail "base DTB is not readable: $base_dtb"

mkdir -p "$work"
printf '%s\n' 'A14 staged F0 CCI-rate diagnostic boot installer'
printf '%s\n' '==============================================='
printf 'kernel_release=%s\n' "$release"
printf 'diagnostic_stage=%s\n' "$stage"
printf 'base_dtb=%s\n' "$base_dtb"
printf '%s\n' 'dtb_changes=false'
printf '%s\n' 'default_boot_unchanged=true'
printf '%s\n' 'persistent_module_override=false'

printf '\n%s\n' '===== BUILD ISOLATED INITRAMFS ====='
confdir="$work/initramfs-tools"
rm -rf "$confdir"
cp -a /etc/initramfs-tools "$confdir"
mkdir -p "$confdir/hooks"
hook="$confdir/hooks/a14-aon-f0-cci-rate-test"
cat > "$hook" <<EOF_HOOK
#!/bin/sh
PREREQ=""
prereqs() { echo "\$PREREQ"; }
case "\${1:-}" in prereqs) prereqs; exit 0 ;; esac
. /usr/share/initramfs-tools/hook-functions
[ "\$version" = "$release" ] || exit 0
force_load i2c_qcom_cci
stock=\$(modinfo -k "\$version" -n i2c_qcom_cci)
rel=\${stock#/lib/modules/\$version/}
dest="\$DESTDIR/lib/modules/\$version/\$rel"
mkdir -p "\$(dirname "\$dest")"
case "\$dest" in
    *.ko.zst) zstd -q -f -19 "$stage/i2c-qcom-cci.ko" -o "\$dest" ;;
    *.ko.xz) xz -C crc32 -9 -c "$stage/i2c-qcom-cci.ko" > "\$dest" ;;
    *.ko.gz) gzip -9 -c "$stage/i2c-qcom-cci.ko" > "\$dest" ;;
    *.ko) cp "$stage/i2c-qcom-cci.ko" "\$dest" ;;
    *) echo "Unsupported CCI module compression: \$dest" >&2; exit 1 ;;
esac
depmod -a -b "\$DESTDIR" "\$version"
EOF_HOOK
chmod 0755 "$hook"

tmp_initrd="$work/initrd.img-$release-aon-f0-cci-rate-test.tmp"
rm -f "$tmp_initrd"
sudo mkinitramfs -d "$confdir" -o "$tmp_initrd" "$release"
[ -s "$tmp_initrd" ] || fail "custom initramfs was not produced"
initrd_list="$work/initramfs-contents.txt"
lsinitramfs "$tmp_initrd" > "$initrd_list"
grep -Eq 'i2c-qcom-cci\.ko(\.|$)' "$initrd_list" || fail "custom initramfs lacks i2c-qcom-cci"
printf '%s\n' 'custom_initramfs=validated'

printf '\n%s\n' '===== INSTALL TEST-ONLY BOOT FILES ====='
sudo install -m 0644 "$base_dtb" "$test_dtb"
sudo install -m 0644 "$tmp_initrd" "$test_initrd"
root_uuid=$(findmnt -no UUID /)
[ -n "$root_uuid" ] || fail "could not resolve root filesystem UUID"
cmdline=$(sed -E 's/(^| )BOOT_IMAGE=[^ ]+//; s/^ +//; s/ +$//' /proc/cmdline)
case " $cmdline " in *' a14_aos_f0_cci_rate_test=1 '*) ;; *) cmdline="$cmdline a14_aos_f0_cci_rate_test=1" ;; esac

grub_tmp="$work/44_a14_aon_f0_cci_rate_test"
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
sudo grep -Fq "menuentry '$entry_title'" /boot/grub/grub.cfg || fail "CCI-rate GRUB entry was not generated"
sudo grep -Fq "initrd /boot/$(basename "$test_initrd")" /boot/grub/grub.cfg || fail "CCI-rate entry does not use custom initramfs"
sudo grep -Fq "devicetree /boot/$(basename "$test_dtb")" /boot/grub/grub.cfg || fail "CCI-rate entry does not use copied base DTB"

printf '\n%s\n' '===== F0 CCI-RATE DIAGNOSTIC ENTRY READY ====='
printf '%s\n' 'installation=validated'
printf 'grub_entry_id=%s\n' "$entry_id"
printf 'grub_entry_title=%s\n' "$entry_title"
printf 'test_dtb=%s\n' "$test_dtb"
printf 'test_initrd=%s\n' "$test_initrd"
printf '%s\n' 'dtb_changes=false'
printf '%s\n' 'default_boot_unchanged=true'
printf '%s\n' 'persistent_module_override=false'
printf '\nReboot and manually select:\n  %s\n' "$entry_title"
printf '\nRun CCI0 only first. Do not load qcom_ssc_hpd or run any AOS activation command.\n'
