#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Build an isolated full-F0/no-mux SSC discriminator whose only protocol
# difference from the previous probe is the Windows-matched INIT576 restart
# counter: field 2 = 5 instead of 0.
set -Eeuo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
release=${A14_KERNEL_RELEASE:-$(uname -r)}
headers="/lib/modules/$release/build"
work=${A14_AOS_F0_ICP_OWNER_WORK:-"$HOME/Downloads/a14-aos-f0-icp-owner-diag-$release"}
wire_stage=${A14_AOS_F0_SSC_WIRE_STAGE:-"$work/ssc-wireexact-artifacts"}
wire_src="$work/qcom-ssc-hpd-wireexact"
camss_modsrc="$work/qcom-camss-module"
jobs=${JOBS:-$(nproc 2>/dev/null || printf '4')}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for tool in bash cp find grep make modinfo nm python3 rm sha256sum sort uname xargs; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this builder as your normal user, not with sudo"
[ -f "$headers/Makefile" ] || fail "kernel headers are missing: $headers"

printf '%s\n' 'A14 Windows-matched INIT576 discriminator build'
printf '%s\n' '==============================================='
printf 'kernel_release=%s\n' "$release"
printf 'wire_stage=%s\n' "$wire_stage"
printf '%s\n' 'handshake_sensor_name=ov02c10'
printf '%s\n' 'handshake_restart_count=5'
printf '%s\n' 'handshake_camera_id=2'
printf '%s\n' 'cpas_ownership_mux_access=false'
printf '%s\n' 'direct_cpas_mmio=false'
printf '%s\n' 'build_only=true'

printf '\n%s\n' '===== BUILD EXISTING FULL-F0/NO-MUX BASE ====='
A14_AOS_F0_SSC_STAGE="$wire_stage" \
    bash "$repo/scripts/a14-aos-f0-ssc-handshake-build.sh"

[ -s "$camss_modsrc/Module.symvers" ] || fail "CAMSS diagnostic Module.symvers is missing"
[ -s "$wire_stage/qcom-camss.ko" ] || fail "full-F0 CAMSS module is missing from wire stage"

printf '\n%s\n' '===== CREATE DIAGNOSTIC-ONLY WINDOWS-MATCHED HPD SOURCE ====='
rm -rf "$wire_src"
cp -a "$repo/kernel/aos" "$wire_src"
python3 - "$wire_src/qcom_ssc_hpd_protocol.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = """\tpayload[p++] = 0x10;\n\tpayload[p++] = 0x00;\n\tpayload[p++] = 0x18;\n\tpayload[p++] = 0x02;\n"""
new = """\t/* qcAlwaysOnSensing.dll constructs qsh_camera_handshake_init with\n\t * num_restarts_detected_since_last_successful_op = 5 on this A14.\n\t * Keep this diagnostic-only until the hardware discriminator returns.\n\t */\n\tpayload[p++] = 0x10;\n\tpayload[p++] = 0x05;\n\tpayload[p++] = 0x18;\n\tpayload[p++] = 0x02;\n"""
count = text.count(old)
if count != 1:
    raise SystemExit(f"ERROR: expected one INIT576 field2=0 sequence, found {count}")
patched = text.replace(old, new, 1)
if patched.count("num_restarts_detected_since_last_successful_op = 5") != 1:
    raise SystemExit("ERROR: Windows-matched source marker validation failed")
if patched.count("\tpayload[p++] = 0x10;\n\tpayload[p++] = 0x05;\n\tpayload[p++] = 0x18;\n\tpayload[p++] = 0x02;\n") != 1:
    raise SystemExit("ERROR: exact INIT576 field sequence validation failed")
path.write_text(patched, encoding="utf-8")
PY

grep -Fq 'num_restarts_detected_since_last_successful_op = 5' \
    "$wire_src/qcom_ssc_hpd_protocol.c" || fail "wire-exact source marker is missing"
printf '%s\n' 'wire_exact_source=validated'

printf '\n%s\n' '===== REBUILD ONLY THE HPD MODULE ====='
make -C "$wire_src" KDIR="$headers" clean
make -C "$wire_src" KDIR="$headers" W=1 \
    AOS_CAMSS_HANDOFF=1 \
    AOS_UNROUTED_HANDSHAKE_DIAG=1 \
    AOS_CAMSS_INCLUDE="$camss_modsrc/include" \
    KBUILD_EXTRA_SYMBOLS="$camss_modsrc/Module.symvers" \
    -j"$jobs" modules
hpd_ko="$wire_src/qcom_ssc_hpd.ko"
[ -s "$hpd_ko" ] || fail "Windows-matched qcom_ssc_hpd.ko was not produced"
case "$(modinfo -F vermagic "$hpd_ko")" in "$release "*) ;; *) fail "HPD vermagic mismatch" ;; esac
hpd_modinfo=$(modinfo "$hpd_ko")
grep -Fq 'allow_unrouted_handshake_probe' <<< "$hpd_modinfo" || \
    fail "wire-exact HPD module lacks the explicit runtime diagnostic gate"
hpd_undef=$(nm -u "$hpd_ko")
grep -q 'qcom_camss_aon_acquire' <<< "$hpd_undef" || \
    fail "wire-exact HPD module was not linked against CAMSS handoff"

cp "$hpd_ko" "$wire_stage/qcom_ssc_hpd.ko"
cat >> "$wire_stage/BUILD-INFO.txt" <<'EOF_INFO'
windows_matched_init576=true
handshake_sensor_name=ov02c10
handshake_restart_count=5
handshake_camera_id=2
handshake_sensor_otp_data=omitted
single_protocol_variable_vs_previous_probe=restart_count_0_to_5
cpas_ownership_mux_touched=false
EOF_INFO
(
    cd "$wire_stage"
    rm -f SHA256SUMS
    find . -maxdepth 1 -type f ! -name SHA256SUMS -print0 |
        sort -z | xargs -0 sha256sum > SHA256SUMS
    sha256sum -c SHA256SUMS
)

printf '\n%s\n' '===== RESULT ====='
printf '%s\n' 'build_result=success'
printf '%s\n' 'wire_exact_init576=validated'
printf 'wire_stage=%s\n' "$wire_stage"
printf '%s\n' 'direct_cpas_mmio=false'
printf '%s\n' 'automatic_ssc_activation=false'
printf '\nInstall the one-shot diagnostic boot with:\n'
printf '  bash %q\n' "$repo/scripts/a14-aos-f0-ssc-wireexact-install.sh"
