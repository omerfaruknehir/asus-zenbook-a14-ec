#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Prepare a one-shot, reversible A14 AOS/CPAS boot test.
set -Eeuo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
release=${A14_KERNEL_RELEASE:-$(uname -r)}
stage=${A14_AOS_STAGE:-"$HOME/Downloads/a14-aos-stage-$release/artifacts"}
work=${A14_AOS_INSTALL_WORK:-"$HOME/Downloads/a14-aos-test-boot-$release"}
base_dtb=${A14_AOS_BASE_DTB:-"/boot/dtb-$release-hm1092-v6-ir-cci"}
test_dtb="/boot/dtb-$release-aos-cpas-hm1092-v6-test"
test_initrd="/boot/initrd.img-$release-aos-cpas-test"
grub_script=/etc/grub.d/41_a14_aos_test
entry_id=a14-aos-cpas-test
entry_title="ASUS Zenbook A14 AOS CPAS test ($release)"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

for tool in awk cp depmod diff dtc fdtoverlay fdtget find findmnt grep install \
            lsinitramfs mkinitramfs modinfo readlink sed sha256sum stat \
            update-grub zstd; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done

[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this script as your normal user, not with sudo"
[ -r "$base_dtb" ] || fail "base HM1092 DTB is missing: $base_dtb"
[ -s "$stage/qcom-camss.ko" ] || fail "staged CAMSS module is missing"
[ -s "$stage/qcom_ssc_hpd.ko" ] || fail "staged SSC module is missing"
[ -s "$stage/SHA256SUMS" ] || fail "staged SHA256SUMS is missing"
[ -r "/boot/vmlinuz-$release" ] || fail "kernel image is missing"
[ -r "/boot/initrd.img-$release" ] || fail "stock initramfs is missing"
[ -d /etc/initramfs-tools ] || fail "initramfs-tools configuration is missing"
[ -r /usr/share/initramfs-tools/hook-functions ] || \
    fail "initramfs-tools hook-functions is missing"

mkdir -p "$work"

printf '%s\n' 'A14 AOS/CPAS reversible test installer'
printf '%s\n' '======================================='
printf 'kernel_release=%s\n' "$release"
printf 'stage=%s\n' "$stage"
printf 'base_dtb=%s\n' "$base_dtb"
printf 'test_dtb=%s\n' "$test_dtb"
printf 'test_initrd=%s\n' "$test_initrd"
printf 'default_boot_unchanged=true\n'

printf '\n%s\n' '===== VERIFY STAGED PAYLOAD ====='
(
    cd "$stage"
    sha256sum -c SHA256SUMS
)
case "$(modinfo -F vermagic "$stage/qcom-camss.ko")" in
    "$release "*) ;;
    *) fail "staged CAMSS vermagic does not match $release" ;;
esac
case "$(modinfo -F vermagic "$stage/qcom_ssc_hpd.ko")" in
    "$release "*) ;;
    *) fail "staged SSC vermagic does not match $release" ;;
esac
printf '%s\n' 'staged_payload=validated'

printf '\n%s\n' '===== MERGE CPAS RESOURCE INTO CURRENT HM1092 DTB ====='
overlay_dts="$work/a14-aos-cpas-overlay.dts"
overlay_dtbo="$work/a14-aos-cpas-overlay.dtbo"
merged_dtb="$work/dtb-$release-aos-cpas-hm1092-v6-test"
cat > "$overlay_dts" <<'DTS'
/dts-v1/;
/plugin/;

/ {
    fragment@0 {
        target-path = "/soc@0/isp@acb7000";

        __overlay__ {
            reg = <0 0x0acb7000 0 0x2000>,
                  <0 0x0acb9000 0 0x2000>,
                  <0 0x0acbb000 0 0x2000>,
                  <0 0x0acc6000 0 0x1000>,
                  <0 0x0acca000 0 0x1000>,
                  <0 0x0acb6000 0 0x1000>,
                  <0 0x0ace4000 0 0x1000>,
                  <0 0x0ace6000 0 0x1000>,
                  <0 0x0ace8000 0 0x1000>,
                  <0 0x0acec000 0 0x4000>,
                  <0 0x0acf6000 0 0x1000>,
                  <0 0x0acf7000 0 0x1000>,
                  <0 0x0acf8000 0 0x1000>,
                  <0 0x0ac62000 0 0xf000>,
                  <0 0x0ac71000 0 0xf000>,
                  <0 0x0acc7000 0 0x2000>,
                  <0 0x0accb000 0 0x2000>,
                  <0 0x0ac19000 0 0xc000>;

            reg-names = "csid0", "csid1", "csid2",
                        "csid_lite0", "csid_lite1", "csid_wrapper",
                        "csiphy0", "csiphy1", "csiphy2", "csiphy4",
                        "csitpg0", "csitpg1", "csitpg2",
                        "vfe0", "vfe1", "vfe_lite0", "vfe_lite1",
                        "cpas-top";
        };
    };
};
DTS

dtc -@ -I dts -O dtb -o "$overlay_dtbo" "$overlay_dts"
fdtoverlay -i "$base_dtb" -o "$merged_dtb" "$overlay_dtbo"

camss_node=/soc@0/isp@acb7000
read -r -a names <<< "$(fdtget -t s "$merged_dtb" "$camss_node" reg-names)"
[ "${#names[@]}" -eq 18 ] || fail "merged DTB has ${#names[@]} CAMSS names, expected 18"
[ "${names[17]}" = cpas-top ] || fail "merged DTB does not end with cpas-top"
read -r -a cells <<< "$(fdtget -t x "$merged_dtb" "$camss_node" reg)"
[ "${#cells[@]}" -eq 72 ] || fail "merged DTB has ${#cells[@]} CAMSS cells, expected 72"
last=$(( ${#cells[@]} - 4 ))
[ "${cells[$last]}" = 0 ] || fail "cpas-top high address cell is not zero"
[ "${cells[$((last + 1))],,}" = ac19000 ] || fail "cpas-top base is wrong"
[ "${cells[$((last + 2))]}" = 0 ] || fail "cpas-top high size cell is not zero"
[ "${cells[$((last + 3))],,}" = c000 ] || fail "cpas-top size is wrong"

base_model=$(fdtget -t s "$base_dtb" / model)
merged_model=$(fdtget -t s "$merged_dtb" / model)
[ "$base_model" = "$merged_model" ] || fail "merged DTB model changed unexpectedly"
printf 'merged_dtb_model=%s\n' "$merged_model"
printf '%s\n' 'merged_dtb=validated'

printf '\n%s\n' '===== BUILD ISOLATED INITRAMFS ====='
confdir="$work/initramfs-tools"
rm -rf "$confdir"
cp -a /etc/initramfs-tools "$confdir"
mkdir -p "$confdir/hooks"
hook="$confdir/hooks/a14-aos-camss-test"
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

tmp_initrd="$work/initrd.img-$release-aos-cpas-test.tmp"
rm -f "$tmp_initrd"
sudo mkinitramfs -d "$confdir" -o "$tmp_initrd" "$release"
[ -s "$tmp_initrd" ] || fail "custom initramfs was not produced"

initrd_list="$work/initramfs-contents.txt"
lsinitramfs "$tmp_initrd" > "$initrd_list"
grep -Fq 'qcom-camss.ko' "$initrd_list" || fail "custom initramfs lacks qcom-camss"
grep -Fq 'conf/modules' "$initrd_list" || fail "custom initramfs lacks forced-module configuration"
printf '%s\n' 'custom_initramfs=validated'

printf '\n%s\n' '===== INSTALL TEST-ONLY BOOT FILES ====='
sudo install -m 0644 "$merged_dtb" "$test_dtb"
sudo install -m 0644 "$tmp_initrd" "$test_initrd"

root_uuid=$(findmnt -no UUID /)
[ -n "$root_uuid" ] || fail "could not resolve root filesystem UUID"
cmdline=$(sed -E 's/(^| )BOOT_IMAGE=[^ ]+//; s/^ +//; s/ +$//' /proc/cmdline)
case " $cmdline " in
    *' a14_aos_cpas_test=1 '*) ;;
    *) cmdline="$cmdline a14_aos_cpas_test=1" ;;
esac

grub_tmp="$work/41_a14_aos_test"
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

grep -Fq "menuentry '$entry_title'" /boot/grub/grub.cfg || \
    fail "test GRUB entry was not generated"
grep -Fq "devicetree /boot/$(basename "$test_dtb")" /boot/grub/grub.cfg || \
    fail "test GRUB entry does not use the merged DTB"
grep -Fq "initrd /boot/$(basename "$test_initrd")" /boot/grub/grub.cfg || \
    fail "test GRUB entry does not use the custom initramfs"

printf '\n%s\n' '===== INSTALLED TEST ENTRY ====='
printf 'grub_entry_id=%s\n' "$entry_id"
printf 'grub_entry_title=%s\n' "$entry_title"
printf 'test_dtb=%s\n' "$test_dtb"
printf 'test_initrd=%s\n' "$test_initrd"
printf 'default_boot_unchanged=true\n'
printf 'persistent_module_override=false\n'
printf '\nOne-shot test boot command:\n'
printf '  sudo grub-reboot %q && sudo reboot\n' "$entry_id"
printf '\nA failed test boot falls back to the normal Ubuntu entry on the next reboot.\n'
