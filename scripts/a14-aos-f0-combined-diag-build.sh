#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Build/stage the previously validated CAMSS F0-rate and CCI-rate diagnostics
# together for one combined framework-managed prerequisite hold.
set -Eeuo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
release=${A14_KERNEL_RELEASE:-$(uname -r)}
work=${A14_AOS_F0_COMBINED_WORK:-"$HOME/Downloads/a14-aos-f0-combined-diag-$release"}
stage="$work/artifacts"
log="$work/build.log"
camss_work=${A14_AOS_F0_RATE_DIAG_WORK:-"$HOME/Downloads/a14-aos-f0-rate-diag-$release"}
cci_work=${A14_AOS_F0_CCI_RATE_WORK:-"$HOME/Downloads/a14-aos-f0-cci-rate-diag-$release"}

mkdir -p "$work"
exec > >(tee "$log") 2>&1

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
on_error() {
    status=$?
    printf '\nCombined F0 diagnostic build stopped at line %s with status %s.\n' "$1" "$status" >&2
    printf 'Log: %s\n' "$log" >&2
    exit "$status"
}
trap 'on_error $LINENO' ERR

for tool in bash cp grep modinfo mkdir rm sha256sum strings tee uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this builder as your normal user, not with sudo"

printf '%s\n' 'A14 combined Windows-F0 prerequisite diagnostic build'
printf '%s\n' '===================================================='
printf 'kernel_release=%s\n' "$release"
printf 'work=%s\n' "$work"
printf '%s\n' 'operation=build-and-stage-only'
printf '%s\n' 'dtb_changes=false'
printf '%s\n' 'direct_cpas_mmio_allowed=false'
printf '%s\n' 'ssc_activation_allowed=false'
printf '%s\n' 'icp_clock_manipulation=false'
printf '%s\n' 'raw_interconnect_manipulation=false'
printf '%s\n' 'system_changes=false'

printf '\n%s\n' '===== BUILD PROVEN CAMSS F0 SUBSET MODULE ====='
A14_AOS_F0_RATE_DIAG_WORK="$camss_work" \
    bash "$repo/scripts/a14-aos-f0-rate-diag-build.sh"

printf '\n%s\n' '===== BUILD PROVEN CCI F0 RATE MODULE ====='
A14_AOS_F0_CCI_RATE_WORK="$cci_work" \
    bash "$repo/scripts/a14-aos-f0-cci-rate-diag-build.sh"

camss_stage="$camss_work/artifacts"
cci_stage="$cci_work/artifacts"
[ -s "$camss_stage/qcom-camss.ko" ] || fail "CAMSS F0 diagnostic artifact is missing"
[ -s "$cci_stage/i2c-qcom-cci.ko" ] || fail "CCI F0 diagnostic artifact is missing"

grep -Fqx 'diagnostic_generation=platform-power-f0-rate-subset-no-mmio-v1' \
    "$camss_stage/BUILD-INFO.txt" || fail "unexpected CAMSS diagnostic generation"
grep -Fqx 'diagnostic_generation=platform-power-f0-cci-rate-no-cpas-mmio-v1' \
    "$cci_stage/BUILD-INFO.txt" || fail "unexpected CCI diagnostic generation"
for info in "$camss_stage/BUILD-INFO.txt" "$cci_stage/BUILD-INFO.txt"; do
    grep -Fqx 'diagnostic_only=true' "$info" || fail "$info is not diagnostic-only"
    grep -Fqx 'dtb_changes=false' "$info" || fail "$info unexpectedly needs DT changes"
    grep -Fqx 'direct_cpas_mmio_allowed=false' "$info" || fail "$info does not prohibit CPAS MMIO"
    grep -Fqx 'ssc_activation_allowed=false' "$info" || fail "$info does not prohibit SSC activation"
done

case "$(modinfo -F vermagic "$camss_stage/qcom-camss.ko")" in "$release "*) ;; *) fail "CAMSS module vermagic mismatch" ;; esac
case "$(modinfo -F vermagic "$cci_stage/i2c-qcom-cci.ko")" in "$release "*) ;; *) fail "CCI module vermagic mismatch" ;; esac

grep -aFq 'AON-F0-RATE-DIAG begin phase=' "$camss_stage/qcom-camss.ko" || fail "CAMSS module lacks F0 diagnostic"
grep -aFq 'AON-F0-CCI-RATE-DIAG begin' "$cci_stage/i2c-qcom-cci.ko" || fail "CCI module lacks F0 diagnostic"
if strings "$camss_stage/qcom-camss.ko" "$cci_stage/i2c-qcom-cci.ko" |
        grep -Eq 'AON-DIAG stage=3|ap-write-no-read|aon-switch-restore-no-read|0x0ac191e0'; then
    fail "staged diagnostic contains a retired/direct CPAS path"
fi

printf '\n%s\n' '===== STAGE COMBINED DIAGNOSTIC ====='
rm -rf "$stage"
mkdir -p "$stage"
cp "$camss_stage/qcom-camss.ko" "$stage/qcom-camss.ko"
cp "$cci_stage/i2c-qcom-cci.ko" "$stage/i2c-qcom-cci.ko"
cp "$camss_stage/BUILD-INFO.txt" "$stage/CAMSS-BUILD-INFO.txt"
cp "$cci_stage/BUILD-INFO.txt" "$stage/CCI-BUILD-INFO.txt"
cp "$log" "$stage/build.log"

cat > "$stage/BUILD-INFO.txt" <<EOF_INFO
kernel_release=$release
diagnostic_only=true
diagnostic_generation=platform-power-f0-combined-framework-only-v1
camss_generation=platform-power-f0-rate-subset-no-mmio-v1
cci_generation=platform-power-f0-cci-rate-no-cpas-mmio-v1
dtb_changes=false
direct_cpas_mmio_allowed=false
ssc_activation_allowed=false
icp_clock_manipulation=false
raw_interconnect_manipulation=false
camss_phase=3
camss_targets=camnoc_rt_axi:300000000,camnoc_nrt_axi:300000000,cpas_ahb:80000000,core_ahb:80000000,cpas_fast_ahb:100000000
cci0_target=37500000
cci1_target=37500000
per_probe_hold_ms=250
combined_runner_requires_overlap=true
restore_cci_original_rates=true
camnoc_restore_limitation=known-19.2-to-240-parking-after-explicit-programming
system_changes=false
EOF_INFO

(
    cd "$stage"
    sha256sum qcom-camss.ko i2c-qcom-cci.ko CAMSS-BUILD-INFO.txt CCI-BUILD-INFO.txt BUILD-INFO.txt build.log > SHA256SUMS
)

printf 'artifact_directory=%s\n' "$stage"
printf '%s\n' 'diagnostic_generation=platform-power-f0-combined-framework-only-v1'
printf '%s\n' 'direct_cpas_mmio_allowed=false'
printf '%s\n' 'ssc_activation_allowed=false'
printf '%s\n' 'build_result=success'
