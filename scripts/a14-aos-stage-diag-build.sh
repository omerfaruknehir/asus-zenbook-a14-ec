#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Build a diagnostic-only qcom-camss module with isolated AON probe stages.
set -Eeuo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
release=${A14_KERNEL_RELEASE:-$(uname -r)}
headers="/lib/modules/$release/build"
base_work=${A14_AOS_BASE_WORK:-"$HOME/Downloads/a14-aos-stage-$release"}
source_root="$base_work/source"
base_stage="$base_work/artifacts"
work=${A14_AOS_DIAG_WORK:-"$HOME/Downloads/a14-aos-diag-$release"}
modsrc="$work/qcom-camss-module"
stage="$work/artifacts"
log="$work/build.log"
patch="$repo/kernel-patches/aos/diagnostics/0001-media-qcom-camss-add-aon-stage-probe.patch"
jobs=${JOBS:-$(nproc 2>/dev/null || printf '4')}

mkdir -p "$work"
exec > >(tee "$log") 2>&1

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

on_error() {
    status=$?
    printf '\nDiagnostic build stopped at line %s with status %s.\n' "$1" "$status" >&2
    printf 'Log: %s\n' "$log" >&2
    exit "$status"
}
trap 'on_error $LINENO' ERR

for tool in cp find git grep make modinfo readelf sha256sum strings tee; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done

[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this builder as your normal user, not with sudo"
[ -f "$headers/Makefile" ] || fail "kernel headers are missing: $headers"
[ -r "$headers/Module.symvers" ] || fail "installed Module.symvers is missing"
[ -s "$patch" ] || fail "diagnostic patch is missing: $patch"
[ -s "$base_stage/qcom_ssc_hpd.ko" ] || fail "validated SSC artifact is missing"
[ -s "$base_stage/x1e80100-asus-zenbook-a14-aos-cpas.dtb" ] || \
    fail "validated CPAS DTB artifact is missing"

camss_source=$(find "$source_root" -type f \
    -path '*/drivers/media/platform/qcom/camss/camss.c' -print -quit)
[ -n "$camss_source" ] || fail "the exact Ubuntu source tree is missing under $source_root"
src=${camss_source%/drivers/media/platform/qcom/camss/camss.c}

printf '%s\n' 'A14 CAMSS staged diagnostic build'
printf '%s\n' '================================='
printf 'kernel_release=%s\n' "$release"
printf 'kernel_source=%s\n' "$src"
printf 'work=%s\n' "$work"
printf 'system_changes=false\n'

printf '\n%s\n' '===== VERIFY PRODUCTION HANDOFF PATCH ====='
grep -Fq 'X1E_CPAS_AON_CAM_SEL_CTRL' "$camss_source" || \
    fail "the production CAMSS handoff patch is not applied"
grep -Fq 'qcom_camss_aon_acquire' "$camss_source" || \
    fail "the production CAMSS provider API is missing"
printf '%s\n' 'production_handoff_patch=present'

printf '\n%s\n' '===== APPLY DIAGNOSTIC-ONLY PATCH ====='
if grep -Fq 'AON-DIAG stage=' "$camss_source"; then
    printf '%s\n' 'diagnostic_patch=already-applied'
else
    git -C "$src" apply --check "$patch" || \
        fail "diagnostic patch does not apply cleanly to the exact Ubuntu source"
    git -C "$src" apply "$patch"
    printf '%s\n' 'diagnostic_patch=applied'
fi

grep -Fq 'aon_diag_stage' "$camss_source" || \
    fail "diagnostic sysfs control is missing after patching"

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
grep -Fq 'qcom_camss_aon_acquire' "$symbols" || \
    fail "CAMSS acquire symbol is missing"
grep -Fq 'qcom_camss_aon_release' "$symbols" || \
    fail "CAMSS release symbol is missing"
strings "$camss_ko" > "$work/qcom-camss.strings.txt"
grep -Fq 'AON-DIAG stage=%u begin' "$work/qcom-camss.strings.txt" || \
    fail "diagnostic stage implementation is missing from the module"
grep -Fq 'aon_diag_stage' "$work/qcom-camss.strings.txt" || \
    fail "diagnostic sysfs attribute is missing from the module"
printf '%s\n' 'diagnostic_qcom_camss_module=validated'

printf '\n%s\n' '===== STAGE DIAGNOSTIC ARTIFACTS ====='
rm -rf "$stage"
mkdir -p "$stage"
cp "$camss_ko" "$stage/qcom-camss.ko"
cp "$base_stage/qcom_ssc_hpd.ko" "$stage/qcom_ssc_hpd.ko"
cp "$base_stage/x1e80100-asus-zenbook-a14-aos-cpas.dtb" \
    "$stage/x1e80100-asus-zenbook-a14-aos-cpas.dtb"
cp "$symbols" "$stage/qcom-camss.symbols.txt"
cp "$log" "$stage/build.log"

cat > "$stage/BUILD-INFO.txt" <<EOF
kernel_release=$release
source_tree=$src
camss_module_vermagic=$vermagic
diagnostic_only=true
diagnostic_stages=1:runtime-pm,2:cpas-clocks,3:cpas-read,4:write-current,5:aon-switch-restore
ssc_activation_allowed=false
system_changes=false
EOF

(
    cd "$stage"
    sha256sum qcom-camss.ko qcom_ssc_hpd.ko \
        x1e80100-asus-zenbook-a14-aos-cpas.dtb \
        qcom-camss.symbols.txt BUILD-INFO.txt build.log > SHA256SUMS
)

printf 'artifact_directory=%s\n' "$stage"
printf '%s\n' 'ssc_activation_allowed=false'
printf '%s\n' 'system_changes=false'
printf '%s\n' 'build_result=success'
