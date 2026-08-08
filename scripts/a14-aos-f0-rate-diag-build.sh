#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Build the staged, framework-managed A14 Windows-F0 clock-rate subset probe.
# No DTB changes, direct CPAS MMIO, SSC contact, or installed module override.
set -Eeuo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
release=${A14_KERNEL_RELEASE:-$(uname -r)}
headers="/lib/modules/$release/build"
base_work=${A14_AOS_POWER_BASE_WORK:-"$HOME/Downloads/a14-aos-power-base-$release"}
source_root="$base_work/source"
work=${A14_AOS_F0_RATE_DIAG_WORK:-"$HOME/Downloads/a14-aos-f0-rate-diag-$release"}
modsrc="$work/qcom-camss-module"
stage="$work/artifacts"
log="$work/build.log"
injector="$repo/scripts/a14-aos-f0-rate-diag-inject.py"
jobs=${JOBS:-$(nproc 2>/dev/null || printf '4')}

mkdir -p "$work"
exec > >(tee "$log") 2>&1

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

on_error() {
    status=$?
    printf '\nF0 rate diagnostic build stopped at line %s with status %s.\n' "$1" "$status" >&2
    printf 'Log: %s\n' "$log" >&2
    exit "$status"
}
trap 'on_error $LINENO' ERR

for tool in apt-get cp dpkg-query find grep make modinfo python3 readelf \
            rm sed sha256sum strings tee; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done

[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this builder as your normal user, not with sudo"
[ -f "$headers/Makefile" ] || fail "kernel headers are missing: $headers"
[ -r "$headers/Module.symvers" ] || fail "installed Module.symvers is missing"
[ -s "$injector" ] || fail "F0 rate diagnostic injector is missing: $injector"

printf '%s\n' 'A14 CAMSS staged Windows-F0 clock-rate diagnostic build'
printf '%s\n' '========================================================'
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
    [ -n "$source_pkg" ] || fail "could not resolve source package for linux-image-$release"
    [ -n "$source_version" ] || fail "could not resolve source version for linux-image-$release"
    printf 'source_package=%s\n' "$source_pkg"
    printf 'source_version=%s\n' "$source_version"
    if ! (cd "$source_root" && apt-get source --only-source "$source_pkg=$source_version"); then
        fail "exact kernel source package could not be downloaded"
    fi
    camss_source=$(find "$source_root" -type f \
        -path '*/drivers/media/platform/qcom/camss/camss.c' -print -quit)
fi
[ -n "$camss_source" ] || fail "exact Ubuntu CAMSS source was not found"
src=${camss_source%/drivers/media/platform/qcom/camss/camss.c}
printf 'kernel_source=%s\n' "$src"

if grep -Eq 'AON-DIAG stage=|aon_diag_stage|ap-write-no-read|aon-switch-restore-no-read|AON-POWER-DIAG begin|AON-F0-RATE-DIAG begin' \
        "$camss_source"; then
    fail "stock source contains an existing AOS diagnostic marker"
fi
printf '%s\n' 'source_tree_direct_mmio_diagnostic=false'

printf '\n%s\n' '===== CREATE TEMPORARY STOCK CAMSS COPY ====='
rm -rf "$modsrc"
mkdir -p "$modsrc"
cp -a "$src/drivers/media/platform/qcom/camss/." "$modsrc/"
[ -s "$modsrc/camss.c" ] || fail "temporary CAMSS copy is incomplete"
printf 'temporary_camss_source=%s\n' "$modsrc"
printf '%s\n' 'source_tree_modified=false'

printf '\n%s\n' '===== INJECT STAGED NON-MMIO F0 RATE PROBE ====='
python3 "$injector" "$modsrc/camss.c"
grep -Fq 'AON-F0-RATE-DIAG begin phase=' "$modsrc/camss.c" || \
    fail "F0 rate diagnostic marker is missing"
grep -Fq 'A14_F0_RATE_CLK_COUNT 7' "$modsrc/camss.c" || \
    fail "seven-clock prerequisite is missing"
grep -Fq '300000000' "$modsrc/camss.c" || fail "300 MHz target is missing"
grep -Fq '100000000' "$modsrc/camss.c" || fail "100 MHz target is missing"
probe=$(sed -n \
    '/static int a14_camss_f0_rate_probe/,/static DEVICE_ATTR_WO(a14_f0_rate_probe)/p' \
    "$modsrc/camss.c")
if printf '%s\n' "$probe" | grep -Eq '\<(readl|writel|ioread|iowrite|ioremap)\>'; then
    fail "injected probe contains prohibited direct MMIO"
fi
if printf '%s\n' "$probe" | grep -Eq 'qcom_ssc_hpd|camera.handshake|INIT 576'; then
    fail "injected probe contains an SSC path"
fi
printf '%s\n' 'rate_probe_direct_mmio=false'
printf '%s\n' 'rate_probe_ssc_contact=false'
printf '%s\n' 'rate_probe_restores_original_rates=true'
printf '%s\n' 'rate_probe_exact_rounding_required=true'

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
grep -Fq 'AON-F0-RATE-DIAG begin phase=' "$work/qcom-camss.strings.txt" || \
    fail "F0 rate probe implementation is missing from module"
grep -Fq 'a14_f0_rate_probe' "$work/qcom-camss.strings.txt" || \
    fail "F0 rate sysfs attribute is missing from module"
if grep -Eq 'AON-DIAG stage=3|ap-write-no-read|aon-switch-restore-no-read|AON-POWER-DIAG begin' \
        "$work/qcom-camss.strings.txt"; then
    fail "module contains another or retired diagnostic path"
fi
printf 'camss_module_vermagic=%s\n' "$vermagic"
printf '%s\n' 'qcom_camss_module=validated'

printf '\n%s\n' '===== STAGE F0-RATE DIAGNOSTIC ARTIFACTS ====='
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
diagnostic_generation=platform-power-f0-rate-subset-no-mmio-v1
diagnostic_trigger=a14_f0_rate_diag/a14_f0_rate_probe
diagnostic_status=a14_f0_rate_diag/a14_f0_rate_status
dtb_changes=false
direct_cpas_mmio_allowed=false
ssc_activation_allowed=false
platform_clock_count=7
phase_1=camnoc_rt_axi:300000000,camnoc_nrt_axi:300000000
phase_2=cpas_ahb:80000000,core_ahb:80000000,cpas_fast_ahb:100000000
phase_3=combined-phase-1-and-phase-2
hold_ms=250
exact_round_rate_required=true
restore_original_rates=true
runtime_pm_includes=top-gdsc,ahb-icc,hf-mnoc-icc,sf-mnoc-icc,sf-icp-mnoc-icc
system_changes=false
EOF_INFO

(
    cd "$stage"
    sha256sum qcom-camss.ko qcom-camss.symbols.txt BUILD-INFO.txt build.log > SHA256SUMS
)

printf 'artifact_directory=%s\n' "$stage"
printf '%s\n' 'diagnostic_generation=platform-power-f0-rate-subset-no-mmio-v1'
printf '%s\n' 'dtb_changes=false'
printf '%s\n' 'direct_cpas_mmio_allowed=false'
printf '%s\n' 'ssc_activation_allowed=false'
printf '%s\n' 'system_changes=false'
printf '%s\n' 'build_result=success'
