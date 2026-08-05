#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Build a staged A14 CAMSS AOS module + DTB without changing the running system.
set -Eeuo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
release=${A14_KERNEL_RELEASE:-$(uname -r)}
headers="/lib/modules/$release/build"
config="/boot/config-$release"
work=${A14_AOS_WORKDIR:-"$HOME/Downloads/a14-aos-stage-$release"}
source_root="$work/source"
dtb_obj="$work/dtb-object"
camss_modsrc="$work/qcom-camss-module"
stage="$work/artifacts"
log="$work/build.log"
jobs=${JOBS:-$(nproc 2>/dev/null || printf '4')}

mkdir -p "$work"
exec > >(tee "$log") 2>&1

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

on_error() {
    status=$?
    printf '\nBuild stopped at line %s with status %s.\n' "$1" "$status" >&2
    printf 'Log: %s\n' "$log" >&2
    exit "$status"
}
trap 'on_error $LINENO' ERR

require() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"
}

for tool in apt-get awk cp df diff dpkg-query dtc fdtget find git grep make \
            modinfo nm python3 readelf sed sha256sum tee; do
    require "$tool"
done

[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this builder as your normal user, not with sudo"
[ -f "$headers/Makefile" ] || fail "kernel headers are missing: $headers"
[ -r "$headers/Module.symvers" ] || fail "installed Module.symvers is missing: $headers/Module.symvers"
[ -r "$config" ] || fail "running-kernel config is missing: $config"
grep -qx 'CONFIG_VIDEO_QCOM_CAMSS=m' "$config" || fail "CAMSS is not modular in $config"
grep -qx 'CONFIG_QCOM_QMI_HELPERS=y' "$config" || fail "QCOM QMI helpers are unavailable"
grep -qx 'CONFIG_IIO=m' "$config" || fail "IIO is not modular as expected"
if grep -qx 'CONFIG_MODULE_SIG_FORCE=y' "$config"; then
    fail "this kernel enforces signed modules; no signing key was configured"
fi

source_pkg=$(dpkg-query -W -f='${source:Package}' "linux-image-$release" 2>/dev/null || true)
source_version=$(dpkg-query -W -f='${source:Version}' "linux-image-$release" 2>/dev/null || true)
[ -n "$source_pkg" ] || fail "could not resolve the source package for linux-image-$release"
[ -n "$source_version" ] || fail "could not resolve the source version for linux-image-$release"

available_kb=$(df -Pk "$work" | awk 'NR == 2 { print $4 }')
[ "$available_kb" -ge 10485760 ] || fail "at least 10 GiB free space is required in $work"

printf '%s\n' 'A14 CAMSS AOS staged build'
printf '%s\n' '==========================='
printf 'kernel_release=%s\n' "$release"
printf 'source_package=%s\n' "$source_pkg"
printf 'source_version=%s\n' "$source_version"
printf 'headers=%s\n' "$(readlink -f "$headers")"
printf 'work=%s\n' "$work"
printf 'jobs=%s\n' "$jobs"
printf 'system_changes=false\n'

printf '\n%s\n' '===== LIVE RESOURCE GUARD ====='
preflight="$work/preflight.txt"
"$repo/scripts/a14-aos-kernel-build-preflight.sh" > "$preflight"
actual_resources="$work/live-camss-resources.txt"
expected_resources="$work/expected-camss-resources.txt"
sed -n 's/^camss_resource_[0-9][0-9]=//p' "$preflight" > "$actual_resources"
cat > "$expected_resources" <<'EOF'
csid0,0x0acb7000,0x2000
csid1,0x0acb9000,0x2000
csid2,0x0acbb000,0x2000
csid_lite0,0x0acc6000,0x1000
csid_lite1,0x0acca000,0x1000
csid_wrapper,0x0acb6000,0x1000
csiphy0,0x0ace4000,0x1000
csiphy1,0x0ace6000,0x1000
csiphy2,0x0ace8000,0x1000
csiphy4,0x0acec000,0x4000
csitpg0,0x0acf6000,0x1000
csitpg1,0x0acf7000,0x1000
csitpg2,0x0acf8000,0x1000
vfe0,0x0ac62000,0xf000
vfe1,0x0ac71000,0xf000
vfe_lite0,0x0acc7000,0x2000
vfe_lite1,0x0accb000,0x2000
EOF
if ! diff -u "$expected_resources" "$actual_resources"; then
    fail "the live CAMSS resource layout differs from the validated UX3407RA layout"
fi
printf '%s\n' 'live_resource_layout=validated'

printf '\n%s\n' '===== EXACT UBUNTU SOURCE ====='
mkdir -p "$source_root"
camss_source=$(find "$source_root" -type f \
    -path '*/drivers/media/platform/qcom/camss/camss.c' -print -quit)
if [ -z "$camss_source" ]; then
    printf 'Downloading exact source package %s=%s...\n' "$source_pkg" "$source_version"
    if ! (cd "$source_root" && apt-get source "$source_pkg=$source_version"); then
        cat >&2 <<EOF
The exact source package could not be downloaded. This usually means deb-src
entries are disabled for the repository that supplied $source_pkg.
No source, module, DTB, boot file, or installed package was changed.
EOF
        exit 1
    fi
    camss_source=$(find "$source_root" -type f \
        -path '*/drivers/media/platform/qcom/camss/camss.c' -print -quit)
fi
[ -n "$camss_source" ] || fail "CAMSS source was not found after apt-get source"
src=${camss_source%/drivers/media/platform/qcom/camss/camss.c}
printf 'kernel_source=%s\n' "$src"
[ -f "$src/arch/arm64/boot/dts/qcom/x1e80100-asus-zenbook-a14.dts" ] || \
    fail "the exact Ubuntu source does not contain the A14 DTS"

if grep -q 'X1E_CPAS_AON_CAM_SEL_CTRL' \
        "$src/drivers/media/platform/qcom/camss/camss.c"; then
    printf '%s\n' 'patch_state=already-applied'
else
    "$repo/kernel-patches/aos/cpas-handoff/apply.sh" "$src"
    printf '%s\n' 'patch_state=applied'
fi

grep -q '<0 0x0ac62000 0 0xf000>' \
    "$src/arch/arm64/boot/dts/qcom/x1e80100-asus-zenbook-a14-aos.dtsi" || \
    fail "patched DTS does not preserve the live vfe0 size"
grep -q '<0 0x0ac71000 0 0xf000>' \
    "$src/arch/arm64/boot/dts/qcom/x1e80100-asus-zenbook-a14-aos.dtsi" || \
    fail "patched DTS does not preserve the live vfe1 size"

printf '\n%s\n' '===== PATCHED A14 DTB ====='
mkdir -p "$dtb_obj"
cp "$config" "$dtb_obj/.config"
make -C "$src" O="$dtb_obj" ARCH=arm64 olddefconfig
if ! make -C "$src" O="$dtb_obj" ARCH=arm64 -j"$jobs" \
        qcom/x1e80100-asus-zenbook-a14.dtb; then
    make -C "$src" O="$dtb_obj" ARCH=arm64 -j"$jobs" \
        arch/arm64/boot/dts/qcom/x1e80100-asus-zenbook-a14.dtb
fi
patched_dtb="$dtb_obj/arch/arm64/boot/dts/qcom/x1e80100-asus-zenbook-a14.dtb"
[ -s "$patched_dtb" ] || fail "patched A14 DTB was not produced"

camss_node=/soc@0/isp@acb7000
read -r -a reg_names <<< "$(fdtget -t s "$patched_dtb" "$camss_node" reg-names)"
[ "${#reg_names[@]}" -eq 18 ] || fail "patched DTB has ${#reg_names[@]} CAMSS names, expected 18"
[ "${reg_names[17]}" = cpas-top ] || fail "patched DTB does not end with cpas-top"
read -r -a reg_cells <<< "$(fdtget -t x "$patched_dtb" "$camss_node" reg)"
[ "${#reg_cells[@]}" -eq 72 ] || fail "patched DTB has ${#reg_cells[@]} CAMSS reg cells, expected 72"
last=$(( ${#reg_cells[@]} - 4 ))
[ "${reg_cells[$last]}" = 0 ] || fail "cpas-top high address cell is not zero"
[ "${reg_cells[$((last + 1))],,}" = ac19000 ] || fail "cpas-top base is not 0x0ac19000"
[ "${reg_cells[$((last + 2))]}" = 0 ] || fail "cpas-top high size cell is not zero"
[ "${reg_cells[$((last + 3))],,}" = c000 ] || fail "cpas-top size is not 0x0c000"
printf '%s\n' 'patched_dtb=validated'

printf '\n%s\n' '===== PATCHED QCOM-CAMSS MODULE ====='
rm -rf "$camss_modsrc"
mkdir -p "$camss_modsrc/include/media"
cp -a "$src/drivers/media/platform/qcom/camss/." "$camss_modsrc/"
cp "$src/include/media/qcom_camss.h" "$camss_modsrc/include/media/"
printf '\nccflags-y += -I$(src)/include\n' >> "$camss_modsrc/Makefile"
make -C "$headers" M="$camss_modsrc" clean
make -C "$headers" M="$camss_modsrc" W=1 -j"$jobs" modules
camss_ko="$camss_modsrc/qcom-camss.ko"
[ -s "$camss_ko" ] || fail "patched qcom-camss.ko was not produced"
modinfo -F vermagic "$camss_ko" | grep -q "^$release " || fail "CAMSS module vermagic does not match $release"
readelf -Ws "$camss_ko" | grep -q 'qcom_camss_aon_acquire' || fail "CAMSS acquire symbol is missing"
readelf -Ws "$camss_ko" | grep -q 'qcom_camss_aon_release' || fail "CAMSS release symbol is missing"
grep -q 'qcom_camss_aon_acquire' "$camss_modsrc/Module.symvers" || fail "CAMSS acquire symbol CRC is missing"
grep -q 'qcom_camss_aon_release' "$camss_modsrc/Module.symvers" || fail "CAMSS release symbol CRC is missing"
printf '%s\n' 'qcom_camss_module=validated'

printf '\n%s\n' '===== HANDOFF-ENABLED SSC MODULE ====='
make -C "$repo/kernel/aos" clean KDIR="$headers"
make -C "$repo/kernel/aos" \
    KDIR="$headers" \
    W=1 \
    AOS_CAMSS_HANDOFF=1 \
    AOS_CAMSS_INCLUDE="$camss_modsrc/include" \
    KBUILD_EXTRA_SYMBOLS="$camss_modsrc/Module.symvers" \
    -j"$jobs"
ssc_ko="$repo/kernel/aos/qcom_ssc_hpd.ko"
[ -s "$ssc_ko" ] || fail "handoff-enabled qcom_ssc_hpd.ko was not produced"
modinfo -F vermagic "$ssc_ko" | grep -q "^$release " || fail "SSC module vermagic does not match $release"
ssc_depends=$(modinfo -F depends "$ssc_ko")
printf 'ssc_depends=%s\n' "$ssc_depends"
printf '%s' "$ssc_depends" | grep -Eq '(^|,)qcom_camss(,|$)' || \
    fail "SSC module does not declare its qcom_camss dependency"
printf '%s\n' 'qcom_ssc_hpd_module=validated'

printf '\n%s\n' '===== STAGED ARTIFACTS ====='
rm -rf "$stage"
mkdir -p "$stage"
cp "$camss_ko" "$stage/qcom-camss.ko"
cp "$ssc_ko" "$stage/qcom_ssc_hpd.ko"
cp "$patched_dtb" "$stage/x1e80100-asus-zenbook-a14-aos-cpas.dtb"
cp "$preflight" "$stage/preflight.txt"
cp "$log" "$stage/build.log"
cat > "$stage/BUILD-INFO.txt" <<EOF
kernel_release=$release
source_package=$source_pkg
source_version=$source_version
source_tree=$src
camss_module_vermagic=$(modinfo -F vermagic "$camss_ko")
ssc_module_vermagic=$(modinfo -F vermagic "$ssc_ko")
ssc_module_depends=$ssc_depends
camss_resource_count=18
camss_resource_17=cpas-top,0x0ac19000,0x0c000
system_changes=false
EOF
(
    cd "$stage"
    sha256sum qcom-camss.ko qcom_ssc_hpd.ko \
        x1e80100-asus-zenbook-a14-aos-cpas.dtb BUILD-INFO.txt preflight.txt \
        > SHA256SUMS
)

printf 'artifact_directory=%s\n' "$stage"
printf '%s\n' 'system_changes=false'
printf '%s\n' 'build_result=success'
printf '\nThe running module, installed module tree, initramfs, GRUB configuration, and boot DTBs were not modified.\n'
