#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Install the stock-source non-MMIO CAMSS power diagnostic in an isolated boot.
set -Eeuo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
release=${A14_KERNEL_RELEASE:-$(uname -r)}
stage=${A14_AOS_POWER_DIAG_STAGE:-"$HOME/Downloads/a14-aos-power-diag-$release/artifacts"}
work=${A14_AOS_POWER_INSTALL_WORK:-"$HOME/Downloads/a14-aos-power-test-boot-$release"}
test_dtb="/boot/dtb-$release-aon-power-test"
test_initrd="/boot/initrd.img-$release-aon-power-test"
grub_script=/etc/grub.d/42_a14_aon_power_test
entry_id=a14-aon-power-test
entry_title="ASUS Zenbook A14 AON power diagnostic ($release)"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

for tool in cp depmod findmnt gzip install lsinitramfs mkinitramfs modinfo \
            readlink sha256sum sudo update-grub xz zstd; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done

[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this script as your normal user, not with sudo"
[ -s "$stage/qcom-camss.ko" ] || fail "power-diagnostic CAMSS artifact is missing"
[ -s "$stage/BUILD-INFO.txt" ] || fail "power-diagnostic BUILD-INFO.txt is missing"
[ -s "$stage/SHA256SUMS" ] || fail "power-diagnostic SHA256SUMS is missing"
[ -e "/boot/vmlinuz-$release" ] || fail "kernel image was not found: /boot/vmlinuz-$release"
[ -e "/boot/initrd.img-$release" ] || fail "stock initramfs was not found: /boot/initrd.img-$release"
[ -d /etc/initramfs-tools ] || fail "initramfs-tools configuration is missing"
[ -r /usr/share/initramfs-tools/hook-functions ] || \
    fail "initramfs hook functions are missing"

case " $(cat /proc/cmdline) " in
    *' a14_aos_power_test=1 '*)
        fail "return to the normal boot before reinstalling the diagnostic entry"
        ;;
esac

(
    cd "$stage"
    sha256sum -c SHA256SUMS
)
grep -Fqx 'diagnostic_only=true' "$stage/BUILD-INFO.txt" || \
    fail "the selected artifact is not diagnostic-only"
grep -Fqx 'diagnostic_generation=platform-power-stock-no-mmio-v2' \
    "$stage/BUILD-INFO.txt" || \
    fail "the selected artifact is not the stock-source power diagnostic"
grep -Fqx 'dtb_changes=false' "$stage/BUILD-INFO.txt" || \
    fail "the selected artifact unexpectedly requires DTB changes"
grep -Fqx 'direct_cpas_mmio_allowed=false' "$stage/BUILD-INFO.txt" || \
    fail "the selected artifact does not prohibit direct CPAS MMIO"
grep -Fqx 'ssc_activation_allowed=false' "$stage/BUILD-INFO.txt" || \
    fail "the selected artifact does not prohibit SSC activation"

case "$(modinfo -F vermagic "$stage/qcom-camss.ko")" in
    "$release "*) ;;
    *) fail "power-diagnostic CAMSS vermagic does not match $release" ;;
esac
# Search the module directly. A `strings | grep -q` pipeline is unsafe under
# pipefail because grep exits early on a match and strings can report SIGPIPE.
grep -aFq 'AON-POWER-DIAG begin direct-mmio=false ssc=false' \
    "$stage/qcom-camss.ko" || \
    fail "the selected CAMSS module lacks the non-MMIO power probe"
if grep -aEq 'AON-DIAG stage=3|ap-write-no-read|aon-switch-restore-no-read' \
        "$stage/qcom-camss.ko"; then
    fail "the selected CAMSS module contains a retired direct-MMIO diagnostic"
fi

if [ -n "${A14_AOS_POWER_BASE_DTB:-}" ]; then
    base_dtb=$A14_AOS_POWER_BASE_DTB
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
printf '%s\n' 'A14 stock-source power diagnostic boot installer'
printf '%s\n' '================================================='
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
hook="$confdir/hooks/a14-aon-power-test"
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
    *.ko.zst)
        zstd -q -f -19 "$stage/qcom-camss.ko" -o "\$dest"
        ;;
    *.ko.xz)
        xz -C crc32 -9 -c "$stage/qcom-camss.ko" > "\$dest"
        ;;
    *.ko.gz)
        gzip -9 -c "$stage/qcom-camss.ko" > "\$dest"
        ;;
    *.ko)
        cp "$stage/qcom-camss.ko" "\$dest"
        ;;
    *)
        echo "Unsupported CAMSS module compression: \$dest" >&2
        exit 1
        ;;
esac

depmod -a -b "\$DESTDIR" "\$version"
EOF_HOOK
chmod 0755 "$hook"

tmp_initrd="$work/initrd.img-$release-aon-power-test.tmp"
rm -f "$tmp_initrd"
sudo mkinitramfs -d "$confdir" -o "$tmp_initrd" "$release"
[ -s "$tmp_initrd" ] || fail "custom initramfs was not produced"

initrd_list="$work/initramfs-contents.txt"
lsinitramfs "$tmp_initrd" > "$initrd_list"
grep -Fq 'qcom-camss.ko' "$initrd_list" || \
    fail "custom initramfs lacks qcom-camss"
printf '%s\n' 'custom_initramfs=validated'

printf '\n%s\n' '===== INSTALL TEST-ONLY BOOT FILES ====='
sudo install -m 0644 "$base_dtb" "$test_dtb"
sudo install -m 0644 "$tmp_initrd" "$test_initrd"

root_uuid=$(findmnt -no UUID /)
[ -n "$root_uuid" ] || fail "could not resolve root filesystem UUID"
cmdline=$(sed -E 's/(^| )BOOT_IMAGE=[^ ]+//; s/^ +//; s/ +$//' /proc/cmdline)
case " $cmdline " in
    *' a14_aos_power_test=1 '*) ;;
    *) cmdline="$cmdline a14_aos_power_test=1" ;;
esac

grub_tmp="$work/42_a14_aon_power_test"
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

sudo grep -Fq "menuentry '$entry_title'" /boot/grub/grub.cfg || \
    fail "power diagnostic GRUB entry was not generated"
sudo grep -Fq "devicetree /boot/$(basename "$test_dtb")" /boot/grub/grub.cfg || \
    fail "power diagnostic entry does not use the copied stock DTB"
sudo grep -Fq "initrd /boot/$(basename "$test_initrd")" /boot/grub/grub.cfg || \
    fail "power diagnostic entry does not use the custom initramfs"

printf '\n%s\n' '===== POWER-DIAGNOSTIC ENTRY READY ====='
printf '%s\n' 'installation=validated'
printf 'grub_entry_id=%s\n' "$entry_id"
printf 'grub_entry_title=%s\n' "$entry_title"
printf 'test_dtb=%s\n' "$test_dtb"
printf 'test_initrd=%s\n' "$test_initrd"
printf '%s\n' 'dtb_changes=false'
printf '%s\n' 'boot_selection=manual-grub-menu'
printf '%s\n' 'default_boot_unchanged=true'
printf '%s\n' 'persistent_module_override=false'
printf '\nReboot normally and manually select from the GRUB menu:\n'
printf '  %s\n' "$entry_title"
printf '\nDo not load qcom_ssc_hpd or run an AOS activation command in this boot.\n'
