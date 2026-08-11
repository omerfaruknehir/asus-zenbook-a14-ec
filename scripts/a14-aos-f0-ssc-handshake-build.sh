#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Build the isolated full-F0 + SSC handshake discriminator.
# Nothing is installed or activated by this script.
set -Eeuo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
release=${A14_KERNEL_RELEASE:-$(uname -r)}
headers="/lib/modules/$release/build"
work=${A14_AOS_F0_ICP_OWNER_WORK:-"$HOME/Downloads/a14-aos-f0-icp-owner-diag-$release"}
base_stage="$work/artifacts"
probe_stage=${A14_AOS_F0_SSC_STAGE:-"$work/ssc-handshake-artifacts"}
camss_modsrc="$work/qcom-camss-module"
cci_modsrc="$work/i2c-qcom-cci-module"
extender="$repo/scripts/a14-aos-f0-ssc-handshake-extend.py"
hpd_src="$repo/kernel/aos"
jobs=${JOBS:-$(nproc 2>/dev/null || printf '4')}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for tool in bash cp find grep make modinfo nm python3 rm sha256sum strings uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this builder as your normal user, not with sudo"
[ -f "$headers/Makefile" ] || fail "kernel headers are missing: $headers"
[ -s "$extender" ] || fail "handshake diagnostic extender is missing"

printf '%s\n' 'A14 full-F0 + SSC handshake discriminator build'
printf '%s\n' '==============================================='
printf 'kernel_release=%s\n' "$release"
printf 'work=%s\n' "$work"
printf 'probe_stage=%s\n' "$probe_stage"
printf '%s\n' 'build_only=true'
printf '%s\n' 'direct_cpas_mmio_allowed=false'
printf '%s\n' 'automatic_ssc_activation=false'

printf '\n%s\n' '===== BUILD KNOWN-SAFE STAGE-C OWNER BASE ====='
A14_AOS_F0_ICP_OWNER_WORK="$work" \
    bash "$repo/scripts/a14-aos-f0-icp-owner-diag-build.sh"

[ -s "$camss_modsrc/camss.c" ] || fail "generated Stage-C CAMSS source is missing"
[ -s "$cci_modsrc/Module.symvers" ] || fail "CCI owner Module.symvers is missing"
[ -d "$base_stage" ] || fail "Stage-C artifact directory is missing"

printf '\n%s\n' '===== EXTEND ONLY THE GENERATED DIAGNOSTIC HOLD ====='
python3 "$extender" "$camss_modsrc/camss.c"
grep -Fq 'A14-F0-SSC-HANDSHAKE-DIAG extension' "$camss_modsrc/camss.c" || \
    fail "bounded hold extension was not injected"
grep -Fq 'value > 5000' "$camss_modsrc/camss.c" || \
    fail "bounded hold maximum is missing"
if grep -Eq 'A14-F0-SSC-HANDSHAKE-DIAG.*(readl|writel|ioremap)' "$camss_modsrc/camss.c"; then
    fail "handshake hold extension unexpectedly contains direct MMIO"
fi

printf '\n%s\n' '===== REBUILD EXTENDED DIAGNOSTIC CAMSS ====='
make -C "$headers" M="$camss_modsrc" clean
make -C "$headers" M="$camss_modsrc" W=1 \
    KBUILD_EXTRA_SYMBOLS="$cci_modsrc/Module.symvers" -j"$jobs" modules
camss_ko="$camss_modsrc/qcom-camss.ko"
[ -s "$camss_ko" ] || fail "extended diagnostic qcom-camss.ko was not produced"
case "$(modinfo -F vermagic "$camss_ko")" in "$release "*) ;; *) fail "CAMSS vermagic mismatch" ;; esac
strings "$camss_ko" | grep -Fq 'AON-F0-ICP-OWNER-DIAG targets-ok hold-ms=%u' || \
    fail "extended CAMSS binary lacks dynamic hold marker"

printf '\n%s\n' '===== BUILD MANUALLY-GATED SSC HPD PROBE ====='
make -C "$hpd_src" KDIR="$headers" clean
make -C "$hpd_src" KDIR="$headers" W=1 \
    AOS_CAMSS_HANDOFF=1 \
    AOS_UNROUTED_HANDSHAKE_DIAG=1 \
    AOS_CAMSS_INCLUDE="$camss_modsrc/include" \
    KBUILD_EXTRA_SYMBOLS="$camss_modsrc/Module.symvers" \
    -j"$jobs" modules
hpd_ko="$hpd_src/qcom_ssc_hpd.ko"
[ -s "$hpd_ko" ] || fail "diagnostic qcom_ssc_hpd.ko was not produced"
case "$(modinfo -F vermagic "$hpd_ko")" in "$release "*) ;; *) fail "HPD vermagic mismatch" ;; esac
modinfo "$hpd_ko" | grep -Fq 'allow_unrouted_handshake_probe' || \
    fail "HPD module lacks the explicit runtime diagnostic gate"
strings "$hpd_ko" | grep -Fq 'AON mux not switched' || \
    fail "HPD module lacks the no-mux diagnostic marker"
nm -u "$hpd_ko" | grep -q 'qcom_camss_aon_acquire' || \
    fail "HPD module was not built against the CAMSS handoff API"

printf '\n%s\n' '===== ASSEMBLE TEST-ONLY PAYLOAD ====='
rm -rf "$probe_stage"
cp -a "$base_stage" "$probe_stage"
cp "$camss_ko" "$probe_stage/qcom-camss.ko"
cp "$hpd_ko" "$probe_stage/qcom_ssc_hpd.ko"
cat >> "$probe_stage/BUILD-INFO.txt" <<'EOF_INFO'
ssc_handshake_discriminator=true
ssc_module_staged=true
ssc_unrouted_handshake_runtime_gate=true
stage_c_hold_runtime_configurable=true
stage_c_hold_max_ms=5000
cpas_ownership_mux_touched=false
automatic_ssc_activation=false
EOF_INFO
(
    cd "$probe_stage"
    rm -f SHA256SUMS
    find . -type f -maxdepth 1 ! -name SHA256SUMS -print0 |
        sort -z | xargs -0 sha256sum > SHA256SUMS
    sha256sum -c SHA256SUMS
)

printf '\n%s\n' '===== RESULT ====='
printf '%s\n' 'build_result=success'
printf 'probe_stage=%s\n' "$probe_stage"
printf 'hpd_module=%s\n' "$probe_stage/qcom_ssc_hpd.ko"
printf '%s\n' 'direct_cpas_mmio_allowed=false'
printf '%s\n' 'automatic_ssc_activation=false'
printf '\nInstall the isolated boot with:\n'
printf '  A14_AOS_F0_ICP_OWNER_STAGE=%q bash %q\n' "$probe_stage" \
    "$repo/scripts/a14-aos-f0-icp-owner-diag-install-test.sh"
