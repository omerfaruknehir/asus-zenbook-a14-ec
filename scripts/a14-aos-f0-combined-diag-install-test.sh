#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Install both proven F0 diagnostic modules into one isolated test initramfs.
# The copied DTB is unchanged. The normal/default boot is not modified.
set -Eeuo pipefail

release=${A14_KERNEL_RELEASE:-$(uname -r)}
stage=${A14_AOS_F0_COMBINED_STAGE:-"$HOME/Downloads/a14-aos-f0-combined-diag-$release/artifacts"}
work=${A14_AOS_F0_COMBINED_INSTALL_WORK:-"$HOME/Downloads/a14-aos-f0-combined-test-boot-$release"}
test_dtb="/boot/dtb-$release-aon-f0-combined-test"
test_initrd="/boot/initrd.img-$release-aon-f0-combined-test"
grub_script=/etc/grub.d/46_a14_aon_f0_combined_test
entry_id=a14-aon-f0-combined-test
entry_title="ASUS Zenbook A14 AON combined F0 prerequisite diagnostic ($release)"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for tool in basename cat cp depmod findmnt gzip install lsinitramfs mkinitramfs modinfo readlink sed sha256sum sudo update-grub xz zstd; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done

[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this script as your normal user, not with sudo"
for f in qcom-camss.ko i2c-qcom-cci.ko BUILD-INFO.txt SHA256SUMS; do
    [ -s "$stage/$f" ] || fail "combined diagnostic artifact is missing: $stage/$f"
done
[ -e "/boot/vmlinuz-$release" ] || fail "kernel image was not found"
[ -e "/boot/initrd.img-$release" ] || fail "stock initramfs was not found"
[ -d /etc/initramfs-tools ] || fail "initramfs-tools configuration is missing"

case " $(cat /proc/cmdline) " in
    *' a14_aos_power_test=1 '*|*' a14_aos_f0_rate_test=1 '*|*' a14_aos_f0_cci_rate_test=1 '*|*' a14_aos_f0_combined_test=1 '*)
        fail "return to the normal Ubuntu boot before installing this diagnostic entry" ;;
esac

(cd "$stage" && sha256sum -c SHA256SUMS)
grep -Fqx 'diagnostic_only=true' "$stage/BUILD-INFO.txt" || fail "artifact is not diagnostic-only"
grep -Fqx 'diagnostic_generation=platform-power-f0-combined-framework-only-v1' "$stage/BUILD-INFO.txt" || fail "wrong combined diagnostic generation"
grep -Fqx 'dtb_changes=false' "$stage/BUILD-INFO.txt" || fail "artifact unexpectedly requires DTB changes"
grep -Fqx 'direct_cpas_mmio_allowed=false' "$stage/BUILD-INFO.txt" || fail "artifact does not prohibit CPAS MMIO"
grep -Fqx 'ssc_activation_allowed=false' "$stage/BUILD-INFO.txt" || fail "artifact does not prohibit SSC activation"
grep -Fqx 'icp_clock_manipulation=false' "$stage/BUILD-INFO.txt" || fail "artifact does not prohibit ICP manipulation"
grep -Fqx 'raw_interconnect_manipulation=false' "$stage/BUILD-INFO.txt" || fail "artifact does not prohibit raw ICC manipulation"
case "$(modinfo -F vermagic "$stage/qcom-camss.ko")" in "$release "*) ;; *) fail "CAMSS diagnostic vermagic mismatch" ;; esac
case "$(modinfo -F vermagic "$stage/i2c-qcom-cci.ko")" in "$release "*) ;; *) fail "CCI diagnostic vermagic mismatch" ;; esac

grep -aFq 'AON-F0-RATE-DIAG begin phase=' "$stage/qcom-camss.ko" || fail "CAMSS module lacks diagnostic"
grep -aFq 'AON-F0-CCI-RATE-DIAG begin' "$stage/i2c-qcom-cci.ko" || fail "CCI module lacks diagnostic"

if [ -n "${A14_AOS_F0_COMBINED_BASE_DTB:-}" ]; then
    base_dtb=$A14_AOS_F0_COMBINED_BASE_DTB
else
    base_dtb=
    for candidate in "/boot/dtb-$release-hm1092-v6-ir-cci" "/boot/dtb-$release-hm1092-v6" "/boot/dtb-$release"; do
        if [ -r "$candidate" ]; then base_dtb=$candidate; break; fi
    done
fi
[ -n "$base_dtb" ] || fail "no usable A14 base DTB was found"
[ -r "$base_dtb" ] || fail "base DTB is not readable: $base_dtb"

mkdir -p "$work"
printf '%s\n' 'A14 combined F0 prerequisite diagnostic boot installer'
printf '%s\n' '======================================================='
printf 'kernel_release=%s\n' "$release"
printf 'diagnostic_stage=%s\n' "$stage"
printf 'base_dtb=%s\n' "$base_dtb"
printf '%s\n' 'dtb_changes=false'
printf '%s\n' 'default_boot_unchanged=true'
printf '%s\n' 'persistent_module_override=false'
printf '%s\n' 'direct_cpas_mmio=false'
printf '%s\n' 'ssc_activation=false'

printf '\n%s\n' '===== BUILD ISOLATED INITRAMFS ====='
confdir="$work/initramfs-tools"
rm -rf "$confdir"
cp -a /etc/initramfs-tools "$confdir"
mkdir -p "$confdir/hooks"
hook="$confdir/hooks/a14-aon-f0-combined-test"
cat > "$hook" <<EOF_HOOK
#!/bin/sh
PREREQ=""
prereqs() { echo "\$PREREQ"; }
case "\${1:-}" in prereqs) prereqs; exit 0 ;; esac
. /usr/share/initramfs-tools/hook-functions
[ "\$version" = "$release" ] || exit 0

replace_module() {
    module=\$1
    source=\$2
    force_load "\$module"
    stock=\$(modinfo -k "\$version" -n "\$module")
    rel=\${stock#/lib/modules/\$version/}
    dest="\$DESTDIR/lib/modules/\$version/\$rel"
    mkdir -p "\$(dirname "\$dest")"
    case "\$dest" in
        *.ko.zst) zstd -q -f -19 "\$source" -o "\$dest" ;;
        *.ko.xz) xz -C crc32 -9 -c "\$source" > "\$dest" ;;
        *.ko.gz) gzip -9 -c "\$source" > "\$dest" ;;
        *.ko) cp "\$source" "\$dest" ;;
        *) echo "Unsupported module compression: \$dest" >&2; exit 1 ;;
    esac
}

replace_module qcom_camss "$stage/qcom-camss.ko"
replace_module i2c_qcom_cci "$stage/i2c-qcom-cci.ko"
depmod -a -b "\$DESTDIR" "\$version"
EOF_HOOK
chmod 0755 "$hook"

tmp_initrd="$work/initrd.img-$release-aon-f0-combined-test.tmp"
rm -f "$tmp_initrd"
sudo mkinitramfs -d "$confdir" -o "$tmp_initrd" "$release"
[ -s "$tmp_initrd" ] || fail "custom initramfs was not produced"
initrd_list="$work/initramfs-contents.txt"
lsinitramfs "$tmp_initrd" > "$initrd_list"
grep -Eq 'qcom-camss\.ko(\.|$)' "$initrd_list" || fail "custom initramfs lacks qcom-camss"
grep -Eq 'i2c-qcom-cci\.ko(\.|$)' "$initrd_list" || fail "custom initramfs lacks i2c-qcom-cci"
printf '%s\n' 'custom_initramfs=validated'

printf '\n%s\n' '===== INSTALL TEST-ONLY BOOT FILES ====='
sudo install -m 0644 "$base_dtb" "$test_dtb"
sudo install -m 0644 "$tmp_initrd" "$test_initrd"
root_uuid=$(findmnt -no UUID /)
[ -n "$root_uuid" ] || fail "could not resolve root filesystem UUID"
cmdline=$(sed -E 's/(^| )BOOT_IMAGE=[^ ]+//; s/^ +//; s/ +$//' /proc/cmdline)
case " $cmdline " in *' a14_aos_f0_combined_test=1 '*) ;; *) cmdline="$cmdline a14_aos_f0_combined_test=1" ;; esac

grub_tmp="$work/46_a14_aon_f0_combined_test"
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
sudo grep -Fq "menuentry '$entry_title'" /boot/grub/grub.cfg || fail "combined GRUB entry was not generated"
sudo grep -Fq "initrd /boot/$(basename "$test_initrd")" /boot/grub/grub.cfg || fail "combined entry does not use custom initramfs"
sudo grep -Fq "devicetree /boot/$(basename "$test_dtb")" /boot/grub/grub.cfg || fail "combined entry does not use copied base DTB"

printf '\n%s\n' '===== COMBINED F0 DIAGNOSTIC ENTRY READY ====='
printf '%s\n' 'installation=validated'
printf 'grub_entry_id=%s\n' "$entry_id"
printf 'grub_entry_title=%s\n' "$entry_title"
printf 'test_dtb=%s\n' "$test_dtb"
printf 'test_initrd=%s\n' "$test_initrd"
printf '%s\n' 'dtb_changes=false'
printf '%s\n' 'default_boot_unchanged=true'
printf '%s\n' 'persistent_module_override=false'
printf '%s\n' 'direct_cpas_mmio=false'
printf '%s\n' 'ssc_activation=false'
printf '\nReboot and manually select:\n  %s\n' "$entry_title"
printf '\nThis boot only combines the previously validated framework-managed probes.\nNo AOS ownership/mux access is present.\n'
