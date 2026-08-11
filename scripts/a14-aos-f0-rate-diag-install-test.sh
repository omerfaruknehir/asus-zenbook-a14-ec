#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Install the staged F0-rate CAMSS diagnostic in a separate isolated boot.
set -Eeuo pipefail

release=${A14_KERNEL_RELEASE:-$(uname -r)}
stage=${A14_AOS_F0_RATE_DIAG_STAGE:-"$HOME/Downloads/a14-aos-f0-rate-diag-$release/artifacts"}
work=${A14_AOS_F0_RATE_INSTALL_WORK:-"$HOME/Downloads/a14-aos-f0-rate-test-boot-$release"}
test_dtb="/boot/dtb-$release-aon-f0-rate-test"
test_initrd="/boot/initrd.img-$release-aon-f0-rate-test"
grub_script=/etc/grub.d/43_a14_aon_f0_rate_test
entry_id=a14-aon-f0-rate-test
entry_title="ASUS Zenbook A14 AON F0 rate diagnostic ($release)"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

for tool in basename cat cp depmod findmnt gzip install lsinitramfs mkinitramfs modinfo \
            readlink sha256sum sudo update-grub xz zstd; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done

[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this script as your normal user, not with sudo"
[ -s "$stage/qcom-camss.ko" ] || fail "F0-rate diagnostic CAMSS artifact is missing"
[ -s "$stage/BUILD-INFO.txt" ] || fail "F0-rate diagnostic BUILD-INFO.txt is missing"
[ -s "$stage/SHA256SUMS" ] || fail "F0-rate diagnostic SHA256SUMS is missing"
[ -e "/boot/vmlinuz-$release" ] || fail "kernel image was not found: /boot/vmlinuz-$release"
[ -e "/boot/initrd.img-$release" ] || fail "stock initramfs was not found: /boot/initrd.img-$release"
[ -d /etc/initramfs-tools ] || fail "initramfs-tools configuration is missing"
[ -r /usr/share/initramfs-tools/hook-functions ] || fail "initramfs hook functions are missing"

case " $(cat /proc/cmdline) " in
    *' a14_aos_power_test=1 '*|*' a14_aos_f0_rate_test=1 '*)
        fail "return to the normal Ubuntu boot before installing this diagnostic entry"
        ;;
esac

(
    cd "$stage"
    sha256sum -c SHA256SUMS
)
grep -Fqx 'diagnostic_only=true' "$stage/BUILD-INFO.txt" || fail "artifact is not diagnostic-only"
grep -Fqx 'diagnostic_generation=platform-power-f0-rate-subset-no-mmio-v1' \
    "$stage/BUILD-INFO.txt" || fail "artifact is not the staged F0-rate diagnostic"
grep -Fqx 'dtb_changes=false' "$stage/BUILD-INFO.txt" || fail "artifact unexpectedly requires DTB changes"
grep -Fqx 'direct_cpas_mmio_allowed=false' "$stage/BUILD-INFO.txt" || fail "artifact does not prohibit direct CPAS MMIO"
grep -Fqx 'ssc_activation_allowed=false' "$stage/BUILD-INFO.txt" || fail "artifact does not prohibit SSC activation"
grep -Fqx 'restore_original_rates=true' "$stage/BUILD-INFO.txt" || fail "artifact does not guarantee rate restoration"
grep -Fqx 'exact_round_rate_required=true' "$stage/BUILD-INFO.txt" || fail "artifact does not require exact round-rate support"

case "$(modinfo -F vermagic "$stage/qcom-camss.ko")" in
    "$release "*) ;;
    *) fail "F0-rate diagnostic CAMSS vermagic does not match $release" ;;
esac

grep -aFq 'AON-F0-RATE-DIAG begin phase=' "$stage/qcom-camss.ko" || \
    fail "selected CAMSS module lacks the F0-rate probe"
if grep -aEq 'AON-DIAG stage=3|ap-write-no-read|aon-switch-restore-no-read|AON-POWER-DIAG begin' \
        "$stage/qcom-camss.ko"; then
    fail "selected CAMSS module contains another or retired diagnostic"
fi

if [ -n "${A14_AOS_F0_RATE_BASE_DTB:-}" ]; then
    base_dtb=$A14_AOS_F0_RATE_BASE_DTB
else
    base_dtb=
    for candidate in \
        "/boot/dtb-$release-hm1092-v6-ir-cci" \
        "/boot/dtb-$release-hm1092-v6" \
        "/boot/dtb-$release"; do
        if [ -r "$candidate" ]; then
            base_dtb=$candidate
            break
        fi
    done
fi
[ -n "$base_dtb" ] || fail "no usable A14 base DTB was found"
[ -r "$base_dtb" ] || fail "base DTB is not readable: $base_dtb"

mkdir -p "$work"
printf '%s\n' 'A14 staged F0-rate diagnostic boot installer'
printf '%s\n' '============================================'
printf 'kernel_release=%s\n' "$release"
printf 'diagnostic_stage=%s\n' "$stage"
printf 'base_dtb=%s\n' "$base_dtb"
printf 'test_dtb=%s\n' "$test_dtb"
printf 'test_initrd=%s\n' "$test_initrd"
printf 'dtb_changes=false\n'
printf 'direct_cpas_mmio_allowed=false\n'
printf 'ssc_activation_allowed=false\n'
printf 'default_boot_unchanged=true\n'
printf 'persistent_module_override=false\n'

printf '\n%s\n' '===== BUILD ISOLATED INITRAMFS ====='
confdir="$work/initramfs-tools"
rm -rf "$confdir"
cp -a /etc/initramfs-tools "$confdir"
mkdir -p "$confdir/hooks"
hook="$confdir/hooks/a14-aon-f0-rate-test"
cat > "$hook" <<EOF_HOOK
#!/bin/sh
PREREQ=""
prereqs() { echo "\$PREREQ"; }
case "\${1:-}" in
    prereqs) prereqs; exit 0 ;;
esac
. /usr/share/initramfs-tools/hook-functions

[ "\$version" = "$release" ] || exit 0
force_load qcom_camss

stock=\$(modinfo -k "\$version" -n qcom_camss)
rel=\${stock#/lib/modules/\$version/}
dest="\$DESTDIR/lib/modules/\$version/\$rel"
mkdir -p "\$(dirname "\$dest")"

case "\$dest" in
    *.ko.zst) zstd -q -f -19 "$stage/qcom-camss.ko" -o "\$dest" ;;
    *.ko.xz) xz -C crc32 -9 -c "$stage/qcom-camss.ko" > "\$dest" ;;
    *.ko.gz) gzip -9 -c "$stage/qcom-camss.ko" > "\$dest" ;;
    *.ko) cp "$stage/qcom-camss.ko" "\$dest" ;;
    *) echo "Unsupported CAMSS module compression: \$dest" >&2; exit 1 ;;
esac

depmod -a -b "\$DESTDIR" "\$version"
EOF_HOOK
chmod 0755 "$hook"

tmp_initrd="$work/initrd.img-$release-aon-f0-rate-test.tmp"
rm -f "$tmp_initrd"
sudo mkinitramfs -d "$confdir" -o "$tmp_initrd" "$release"
[ -s "$tmp_initrd" ] || fail "custom initramfs was not produced"

initrd_list="$work/initramfs-contents.txt"
lsinitramfs "$tmp_initrd" > "$initrd_list"
grep -Fq 'qcom-camss.ko' "$initrd_list" || fail "custom initramfs lacks qcom-camss"
printf '%s\n' 'custom_initramfs=validated'

printf '\n%s\n' '===== INSTALL TEST-ONLY BOOT FILES ====='
sudo install -m 0644 "$base_dtb" "$test_dtb"
sudo install -m 0644 "$tmp_initrd" "$test_initrd"

root_uuid=$(findmnt -no UUID /)
[ -n "$root_uuid" ] || fail "could not resolve root filesystem UUID"
cmdline=$(sed -E 's/(^| )BOOT_IMAGE=[^ ]+//; s/^ +//; s/ +$//' /proc/cmdline)
case " $cmdline " in
    *' a14_aos_f0_rate_test=1 '*) ;;
    *) cmdline="$cmdline a14_aos_f0_rate_test=1" ;;
esac

grub_tmp="$work/43_a14_aon_f0_rate_test"
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

sudo grep -Fq "menuentry '$entry_title'" /boot/grub/grub.cfg || fail "F0-rate GRUB entry was not generated"
sudo grep -Fq "devicetree /boot/$(basename "$test_dtb")" /boot/grub/grub.cfg || fail "F0-rate entry does not use copied stock DTB"
sudo grep -Fq "initrd /boot/$(basename "$test_initrd")" /boot/grub/grub.cfg || fail "F0-rate entry does not use custom initramfs"

printf '\n%s\n' '===== F0-RATE DIAGNOSTIC ENTRY READY ====='
printf '%s\n' 'installation=validated'
printf 'grub_entry_id=%s\n' "$entry_id"
printf 'grub_entry_title=%s\n' "$entry_title"
printf 'test_dtb=%s\n' "$test_dtb"
printf 'test_initrd=%s\n' "$test_initrd"
printf '%s\n' 'dtb_changes=false'
printf '%s\n' 'boot_selection=manual-grub-menu'
printf '%s\n' 'default_boot_unchanged=true'
printf '%s\n' 'persistent_module_override=false'
printf '\nReboot and manually select from the GRUB menu:\n'
printf '  %s\n' "$entry_title"
printf '\nRun only phase 1 first. Do not load qcom_ssc_hpd or run any AOS activation command.\n'
