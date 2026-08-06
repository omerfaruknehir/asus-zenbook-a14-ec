#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Build a CAMSS diagnostic that exercises the complete Linux-visible platform
# power prerequisite without accessing the AON mux or contacting SSC.
set -Eeuo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
release=${A14_KERNEL_RELEASE:-$(uname -r)}
headers="/lib/modules/$release/build"
base_work=${A14_AOS_POWER_BASE_WORK:-"$HOME/Downloads/a14-aos-power-base-$release"}
source_root="$base_work/source"
base_stage="$base_work/artifacts"
work=${A14_AOS_POWER_DIAG_WORK:-"$HOME/Downloads/a14-aos-power-diag-$release"}
modsrc="$work/qcom-camss-module"
stage="$work/artifacts"
log="$work/build.log"
power_patch="$repo/kernel-patches/aos/power-diagnostics/0001-media-qcom-camss-add-platform-power-probe.patch"
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

for tool in apt-get cp dpkg-query find git grep make modinfo readelf sed sha256sum strings tee; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done

[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this builder as your normal user, not with sudo"
[ -f "$headers/Makefile" ] || fail "kernel headers are missing: $headers"
[ -r "$headers/Module.symvers" ] || fail "installed Module.symvers is missing"
[ -s "$power_patch" ] || fail "power diagnostic patch is missing: $power_patch"

printf '%s\n' 'A14 CAMSS platform-power diagnostic build'
printf '%s\n' '========================================='
printf 'kernel_release=%s\n' "$release"
printf 'base_work=%s\n' "$base_work"
printf 'work=%s\n' "$work"
printf 'direct_cpas_mmio_allowed=false\n'
printf 'ssc_activation_allowed=false\n'
printf 'system_changes=false\n'

printf '\n%s\n' '===== PREFETCH EXACT KERNEL SOURCE ====='
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
enabled for the repository supplying $source_pkg. The --only-source option is
required here because APT otherwise resolves linux-qcom-x1e to the similarly
named meta binary package.
No module, DTB, boot file, or installed package was changed.
EOF
        exit 1
    fi

    camss_source=$(find "$source_root" -type f \
        -path '*/drivers/media/platform/qcom/camss/camss.c' -print -quit)
fi
[ -n "$camss_source" ] || \
    fail "the exact source download completed but CAMSS source is still missing"
printf 'prefetched_kernel_source=%s\n' \
    "${camss_source%/drivers/media/platform/qcom/camss/camss.c}"

printf '\n%s\n' '===== BUILD FRESH QUARANTINED BASE ====='
A14_AOS_WORKDIR="$base_work" bash "$repo/scripts/a14-aos-stage-build.sh"

[ -s "$base_stage/qcom_ssc_hpd.ko" ] || fail "base SSC artifact is missing"
[ -s "$base_stage/x1e80100-asus-zenbook-a14-aos-cpas.dtb" ] || \
    fail "base CPAS DTB artifact is missing"

camss_source=$(find "$source_root" -type f \
    -path '*/drivers/media/platform/qcom/camss/camss.c' -print -quit)
[ -n "$camss_source" ] || fail "the fresh Ubuntu CAMSS source was not found"
src=${camss_source%/drivers/media/platform/qcom/camss/camss.c}

provider=$(sed -n \
    '/int qcom_camss_aon_acquire/,/EXPORT_SYMBOL_GPL(qcom_camss_aon_release)/p' \
    "$camss_source")
printf '%s\n' "$provider" | grep -Fq 'ret = -EOPNOTSUPP' || \
    fail "the production direct-MMIO quarantine is not applied"
if printf '%s\n' "$provider" | grep -Eq '\<(readl|writel)\>'; then
    fail "the production provider still contains direct CPAS MMIO"
fi
if grep -Eq 'AON-DIAG stage=|aon_diag_stage|ap-write-no-read|aon-switch-restore-no-read' \
        "$camss_source"; then
    fail "a retired write-capable diagnostic is present in the fresh source"
fi

printf '\n%s\n' '===== APPLY NON-MMIO POWER PROBE ====='
if grep -Fq 'AON-POWER-DIAG begin direct-mmio=false' "$camss_source"; then
    printf '%s\n' 'power_diagnostic_patch=already-applied'
else
    git -C "$src" apply --check "$power_patch" || \
        fail "the power diagnostic patch does not apply to the quarantined source"
    git -C "$src" apply "$power_patch"
    printf '%s\n' 'power_diagnostic_patch=applied'
fi

grep -Fq 'aon_power_probe' "$camss_source" || \
    fail "the non-MMIO sysfs trigger is missing"
grep -Fq 'X1E_AON_POWER_CLK_COUNT' "$camss_source" || \
    fail "the seven-clock power prerequisite is missing"
power_probe=$(sed -n \
    '/static int qcom_camss_aon_power_probe/,/static DEVICE_ATTR_WO(aon_power_probe)/p' \
    "$camss_source")
if printf '%s\n' "$power_probe" | grep -Eq '\<(readl|writel|ioread|iowrite)\>'; then
    fail "the power probe contains prohibited direct MMIO"
fi
printf '%s\n' 'power_probe_direct_mmio=false'

printf '\n%s\n' '===== BUILD DIAGNOSTIC QCOM-CAMSS MODULE ====='
rm -rf "$modsrc"
mkdir -p "$modsrc/include/media"
cp -a "$src/drivers/media/platform/qcom/camss/." "$modsrc/"
cp "$src/include/media/qcom_camss.h" "$modsrc/include/media/"
printf '\nccflags-y += -I$(src)/include\n' >> "$modsrc/Makefile"

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
grep -Fq 'qcom_camss_aon_acquire' "$symbols" || fail "CAMSS acquire symbol is missing"
grep -Fq 'qcom_camss_aon_release' "$symbols" || fail "CAMSS release symbol is missing"
strings "$camss_ko" > "$work/qcom-camss.strings.txt"
grep -Fq 'AON-POWER-DIAG begin direct-mmio=false' "$work/qcom-camss.strings.txt" || \
    fail "the power probe implementation is missing from the module"
grep -Fq 'aon_power_probe' "$work/qcom-camss.strings.txt" || \
    fail "the power probe sysfs attribute is missing from the module"
if grep -Eq 'AON-DIAG stage=3|ap-write-no-read|aon-switch-restore-no-read' \
        "$work/qcom-camss.strings.txt"; then
    fail "the module contains a retired direct-MMIO diagnostic path"
fi

printf '\n%s\n' '===== STAGE POWER-DIAGNOSTIC ARTIFACTS ====='
rm -rf "$stage"
mkdir -p "$stage"
cp "$camss_ko" "$stage/qcom-camss.ko"
cp "$base_stage/qcom_ssc_hpd.ko" "$stage/qcom_ssc_hpd.ko"
cp "$base_stage/x1e80100-asus-zenbook-a14-aos-cpas.dtb" \
    "$stage/x1e80100-asus-zenbook-a14-aos-cpas.dtb"
cp "$symbols" "$stage/qcom-camss.symbols.txt"
cp "$log" "$stage/build.log"

cat > "$stage/BUILD-INFO.txt" <<EOF_INFO
kernel_release=$release
source_tree=$src
camss_module_vermagic=$vermagic
diagnostic_only=true
diagnostic_generation=platform-power-no-mmio-v1
diagnostic_trigger=aon_power_diag/aon_power_probe
direct_cpas_mmio_allowed=false
ssc_activation_allowed=false
platform_clock_count=7
platform_clocks=camnoc_rt_axi,camnoc_nrt_axi,cpas_ahb,core_ahb,cpas_fast_ahb,gcc_axi_hf,gcc_axi_sf
runtime_pm_includes=top-gdsc,ahb-icc,hf-mnoc-icc,sf-mnoc-icc,sf-icp-mnoc-icc
system_changes=false
EOF_INFO

(
    cd "$stage"
    sha256sum qcom-camss.ko qcom_ssc_hpd.ko \
        x1e80100-asus-zenbook-a14-aos-cpas.dtb \
        qcom-camss.symbols.txt BUILD-INFO.txt build.log > SHA256SUMS
)

printf 'artifact_directory=%s\n' "$stage"
printf '%s\n' 'diagnostic_generation=platform-power-no-mmio-v1'
printf '%s\n' 'direct_cpas_mmio_allowed=false'
printf '%s\n' 'ssc_activation_allowed=false'
printf '%s\n' 'system_changes=false'
printf '%s\n' 'build_result=success'
