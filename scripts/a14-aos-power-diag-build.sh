#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Build a non-MMIO A14 CAMSS platform-power diagnostic from the exact stock
# Ubuntu source. The source tree, DTB and installed module tree are not changed.
set -Eeuo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
release=${A14_KERNEL_RELEASE:-$(uname -r)}
headers="/lib/modules/$release/build"
base_work=${A14_AOS_POWER_BASE_WORK:-"$HOME/Downloads/a14-aos-power-base-$release"}
source_root="$base_work/source"
work=${A14_AOS_POWER_DIAG_WORK:-"$HOME/Downloads/a14-aos-power-diag-$release"}
modsrc="$work/qcom-camss-module"
stage="$work/artifacts"
log="$work/build.log"
injector="$repo/scripts/a14-aos-power-diag-inject.py"
jobs=${JOBS:-$(nproc 2>/dev/null || printf '4')}

mkdir -p "$work"
exec > >(tee "$log") 2>&1

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

on_error() {
    status=$?
    printf '\nPower diagnostic build stopped at line %s with status %s.\n' "$1" "$status" >&2
    printf 'Log: %s\n' "$log" >&2
    exit "$status"
}
trap 'on_error $LINENO' ERR

for tool in apt-get cp dpkg-query find grep make modinfo python3 readelf \
            sha256sum strings tee; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done

[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this builder as your normal user, not with sudo"
[ -f "$headers/Makefile" ] || fail "kernel headers are missing: $headers"
[ -r "$headers/Module.symvers" ] || fail "installed Module.symvers is missing"
[ -s "$injector" ] || fail "power diagnostic injector is missing: $injector"

printf '%s\n' 'A14 CAMSS stock-source platform-power diagnostic build'
printf '%s\n' '======================================================'
printf 'kernel_release=%s\n' "$release"
printf 'base_work=%s\n' "$base_work"
printf 'work=%s\n' "$work"
printf 'source_mode=stock-ubuntu-temporary-copy\n'
printf 'dtb_changes=false\n'
printf 'direct_cpas_mmio_allowed=false\n'
printf 'ssc_activation_allowed=false\n'
printf 'system_changes=false\n'

printf '\n%s\n' '===== LOCATE EXACT KERNEL SOURCE ====='
mkdir -p "$source_root"
camss_source=$(find "$source_root" -type f \
    -path '*/drivers/media/platform/qcom/camss/camss.c' -print -quit)
if [ -z "$camss_source" ]; then
    source_pkg=$(dpkg-query -W -f='${source:Package}' \
        "linux-image-$release" 2>/dev/null || true)
    source_version=$(dpkg-query -W -f='${source:Version}' \
        "linux-image-$release" 2>/dev/null || true)
    [ -n "$source_pkg" ] || \
        fail "could not resolve the source package for linux-image-$release"
    [ -n "$source_version" ] || \
        fail "could not resolve the source version for linux-image-$release"

    printf 'source_package=%s\n' "$source_pkg"
    printf 'source_version=%s\n' "$source_version"
    printf '%s\n' 'apt_source_resolution=source-name-forced'

    if ! (cd "$source_root" && \
          apt-get source --only-source "$source_pkg=$source_version"); then
        cat >&2 <<EOF
The exact kernel source package could not be downloaded. Verify that deb-src is
enabled for the repository supplying $source_pkg. No module, DTB, boot file, or
installed package was changed.
EOF
        exit 1
    fi

    camss_source=$(find "$source_root" -type f \
        -path '*/drivers/media/platform/qcom/camss/camss.c' -print -quit)
fi
[ -n "$camss_source" ] || fail "the exact Ubuntu CAMSS source was not found"
src=${camss_source%/drivers/media/platform/qcom/camss/camss.c}
printf 'kernel_source=%s\n' "$src"

if grep -Eq 'AON-DIAG stage=|aon_diag_stage|ap-write-no-read|aon-switch-restore-no-read' \
        "$camss_source"; then
    fail "the source tree contains a retired write-capable diagnostic"
fi
printf '%s\n' 'source_tree_direct_mmio_diagnostic=false'

printf '\n%s\n' '===== CREATE TEMPORARY STOCK CAMSS COPY ====='
rm -rf "$modsrc"
mkdir -p "$modsrc"
cp -a "$src/drivers/media/platform/qcom/camss/." "$modsrc/"
[ -s "$modsrc/camss.c" ] || fail "temporary CAMSS copy is incomplete"
printf 'temporary_camss_source=%s\n' "$modsrc"
printf '%s\n' 'source_tree_modified=false'

printf '\n%s\n' '===== INJECT NON-MMIO POWER PROBE ====='
python3 "$injector" "$modsrc/camss.c"
grep -Fq 'AON-POWER-DIAG begin direct-mmio=false ssc=false' \
    "$modsrc/camss.c" || fail "power diagnostic marker is missing"
grep -Fq 'A14_AON_POWER_CLK_COUNT 7' "$modsrc/camss.c" || \
    fail "seven-clock prerequisite is missing"
probe=$(sed -n \
    '/static int a14_camss_aon_power_probe/,/static DEVICE_ATTR_WO(a14_aon_power_probe)/p' \
    "$modsrc/camss.c")
if printf '%s\n' "$probe" | grep -Eq '\<(readl|writel|ioread|iowrite)\>'; then
    fail "the injected probe contains prohibited direct MMIO"
fi
if printf '%s\n' "$probe" | grep -Eq 'qcom_ssc_hpd|camera.handshake|INIT 576'; then
    fail "the injected probe contains an SSC path"
fi
printf '%s\n' 'power_probe_direct_mmio=false'
printf '%s\n' 'power_probe_ssc_contact=false'

printf '\n%s\n' '===== BUILD DIAGNOSTIC QCOM-CAMSS MODULE ====='
make -C "$headers" M="$modsrc" clean
make -C "$headers" M="$modsrc" W=1 -j"$jobs" modules
camss_ko="$modsrc/qcom-camss.ko"
[ -s "$camss_ko" ] || fail "diagnostic qcom-camss.ko was not produced"

vermagic=$(modinfo -F vermagic "$camss_ko")
case "$vermagic" in
    "$release "*) ;;
    *) fail "diagnostic CAMSS vermagic does not match $release" ;;
esac

symbols="$work/qcom-camss.symbols.txt"
readelf -Ws "$camss_ko" > "$symbols"
strings "$camss_ko" > "$work/qcom-camss.strings.txt"
grep -Fq 'AON-POWER-DIAG begin direct-mmio=false ssc=false' \
    "$work/qcom-camss.strings.txt" || \
    fail "the power probe implementation is missing from the module"
grep -Fq 'a14_aon_power_probe' "$work/qcom-camss.strings.txt" || \
    fail "the power probe sysfs attribute is missing from the module"
if grep -Eq 'AON-DIAG stage=3|ap-write-no-read|aon-switch-restore-no-read' \
        "$work/qcom-camss.strings.txt"; then
    fail "the module contains a retired direct-MMIO diagnostic path"
fi
printf 'camss_module_vermagic=%s\n' "$vermagic"
printf '%s\n' 'qcom_camss_module=validated'

printf '\n%s\n' '===== STAGE POWER-DIAGNOSTIC ARTIFACTS ====='
rm -rf "$stage"
mkdir -p "$stage"
cp "$camss_ko" "$stage/qcom-camss.ko"
cp "$symbols" "$stage/qcom-camss.symbols.txt"
cp "$log" "$stage/build.log"

cat > "$stage/BUILD-INFO.txt" <<EOF_INFO
kernel_release=$release
source_tree=$src
source_mode=stock-ubuntu-temporary-copy
camss_module_vermagic=$vermagic
diagnostic_only=true
diagnostic_generation=platform-power-stock-no-mmio-v2
diagnostic_trigger=a14_aon_power_diag/a14_aon_power_probe
dtb_changes=false
direct_cpas_mmio_allowed=false
ssc_activation_allowed=false
platform_clock_count=7
platform_clocks=camnoc_rt_axi,camnoc_nrt_axi,cpas_ahb,core_ahb,cpas_fast_ahb,gcc_axi_hf,gcc_axi_sf
runtime_pm_includes=top-gdsc,ahb-icc,hf-mnoc-icc,sf-mnoc-icc,sf-icp-mnoc-icc
system_changes=false
EOF_INFO

(
    cd "$stage"
    sha256sum qcom-camss.ko qcom-camss.symbols.txt BUILD-INFO.txt build.log \
        > SHA256SUMS
)

printf 'artifact_directory=%s\n' "$stage"
printf '%s\n' 'diagnostic_generation=platform-power-stock-no-mmio-v2'
printf '%s\n' 'dtb_changes=false'
printf '%s\n' 'direct_cpas_mmio_allowed=false'
printf '%s\n' 'ssc_activation_allowed=false'
printf '%s\n' 'system_changes=false'
printf '%s\n' 'build_result=success'
