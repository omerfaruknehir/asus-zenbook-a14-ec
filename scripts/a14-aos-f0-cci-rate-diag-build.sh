#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Build an isolated, framework-managed A14 Windows-F0 CCI-rate diagnostic.
set -Eeuo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
release=${A14_KERNEL_RELEASE:-$(uname -r)}
headers="/lib/modules/$release/build"
base_work=${A14_AOS_POWER_BASE_WORK:-"$HOME/Downloads/a14-aos-power-base-$release"}
source_root="$base_work/source"
work=${A14_AOS_F0_CCI_RATE_WORK:-"$HOME/Downloads/a14-aos-f0-cci-rate-diag-$release"}
modsrc="$work/i2c-qcom-cci-module"
stage="$work/artifacts"
log="$work/build.log"
injector="$repo/scripts/a14-aos-f0-cci-rate-diag-inject.py"
jobs=${JOBS:-$(nproc 2>/dev/null || printf '4')}

mkdir -p "$work"
exec > >(tee "$log") 2>&1

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
on_error() {
    status=$?
    printf '\nF0 CCI-rate diagnostic build stopped at line %s with status %s.\n' "$1" "$status" >&2
    printf 'Log: %s\n' "$log" >&2
    exit "$status"
}
trap 'on_error $LINENO' ERR

for tool in apt-get cp dpkg-query find grep make modinfo python3 readelf rm sed sha256sum strings tee; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done

[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this builder as your normal user, not with sudo"
[ -f "$headers/Makefile" ] || fail "kernel headers are missing: $headers"
[ -r "$headers/Module.symvers" ] || fail "installed Module.symvers is missing"
[ -s "$injector" ] || fail "CCI diagnostic injector is missing: $injector"

printf '%s\n' 'A14 Windows-F0 CCI clock-rate diagnostic build'
printf '%s\n' '=============================================='
printf 'kernel_release=%s\n' "$release"
printf 'work=%s\n' "$work"
printf '%s\n' 'source_mode=stock-ubuntu-temporary-copy'
printf '%s\n' 'dtb_changes=false'
printf '%s\n' 'direct_cpas_mmio_allowed=false'
printf '%s\n' 'ssc_activation_allowed=false'
printf '%s\n' 'cci_target_rate=37500000'
printf '%s\n' 'system_changes=false'

printf '\n%s\n' '===== LOCATE EXACT KERNEL SOURCE ====='
mkdir -p "$source_root"
cci_source=$(find "$source_root" -type f -path '*/drivers/i2c/busses/i2c-qcom-cci.c' -print -quit)
if [ -z "$cci_source" ]; then
    source_pkg=$(dpkg-query -W -f='${source:Package}' "linux-image-$release" 2>/dev/null || true)
    source_version=$(dpkg-query -W -f='${source:Version}' "linux-image-$release" 2>/dev/null || true)
    [ -n "$source_pkg" ] || fail "could not resolve source package for linux-image-$release"
    [ -n "$source_version" ] || fail "could not resolve source version for linux-image-$release"
    printf 'source_package=%s\n' "$source_pkg"
    printf 'source_version=%s\n' "$source_version"
    (cd "$source_root" && apt-get source --only-source "$source_pkg=$source_version") || \
        fail "exact kernel source package could not be downloaded"
    cci_source=$(find "$source_root" -type f -path '*/drivers/i2c/busses/i2c-qcom-cci.c' -print -quit)
fi
[ -n "$cci_source" ] || fail "exact Ubuntu i2c-qcom-cci source was not found"
src=${cci_source%/drivers/i2c/busses/i2c-qcom-cci.c}
printf 'kernel_source=%s\n' "$src"

if grep -Eq 'AON-DIAG stage=|AON-POWER-DIAG begin|AON-F0-RATE-DIAG begin|AON-F0-CCI-RATE-DIAG begin|ap-write-no-read|aon-switch-restore-no-read' "$cci_source"; then
    fail "stock CCI source contains an existing AOS diagnostic marker"
fi

printf '\n%s\n' '===== CREATE TEMPORARY CCI MODULE COPY ====='
rm -rf "$modsrc"
mkdir -p "$modsrc"
cp "$cci_source" "$modsrc/i2c-qcom-cci.c"
cat > "$modsrc/Makefile" <<'EOF_MAKE'
obj-m += i2c-qcom-cci.o
EOF_MAKE

printf '\n%s\n' '===== INJECT NON-MMIO CCI RATE PROBE ====='
python3 "$injector" "$modsrc/i2c-qcom-cci.c"
grep -Fq 'AON-F0-CCI-RATE-DIAG begin' "$modsrc/i2c-qcom-cci.c" || fail "CCI rate diagnostic marker is missing"
grep -Fq 'A14_F0_CCI_TARGET_RATE 37500000UL' "$modsrc/i2c-qcom-cci.c" || fail "37.5 MHz target is missing"
helper=$(sed -n '/static int a14_f0_cci_rate_probe/,/static DEVICE_ATTR_WO(a14_f0_cci_rate_probe)/p' "$modsrc/i2c-qcom-cci.c")
if printf '%s\n' "$helper" | grep -Eq '\<(readl|writel|ioread|iowrite|ioremap)\>'; then
    fail "injected CCI rate helper contains prohibited direct MMIO"
fi
if printf '%s\n' "$helper" | grep -Eq 'qcom_ssc_hpd|camera.handshake|INIT 576'; then
    fail "injected CCI rate helper contains an SSC path"
fi
printf '%s\n' 'diagnostic_direct_cpas_mmio=false'
printf '%s\n' 'diagnostic_ssc_contact=false'
printf '%s\n' 'diagnostic_uses_existing_cci_runtime_pm=true'
printf '%s\n' 'diagnostic_restores_original_rate=true'

printf '\n%s\n' '===== BUILD DIAGNOSTIC I2C-QCOM-CCI MODULE ====='
make -C "$headers" M="$modsrc" clean
make -C "$headers" M="$modsrc" W=1 -j"$jobs" modules
cci_ko="$modsrc/i2c-qcom-cci.ko"
[ -s "$cci_ko" ] || fail "diagnostic i2c-qcom-cci.ko was not produced"

vermagic=$(modinfo -F vermagic "$cci_ko")
case "$vermagic" in "$release "*) ;; *) fail "diagnostic CCI vermagic does not match $release" ;; esac
symbols="$work/i2c-qcom-cci.symbols.txt"
readelf -Ws "$cci_ko" > "$symbols"
strings "$cci_ko" > "$work/i2c-qcom-cci.strings.txt"
grep -Fq 'AON-F0-CCI-RATE-DIAG begin' "$work/i2c-qcom-cci.strings.txt" || fail "CCI rate probe implementation is missing from module"
grep -Fq 'a14_f0_cci_rate_probe' "$work/i2c-qcom-cci.strings.txt" || fail "CCI rate sysfs attribute is missing from module"

printf '\n%s\n' '===== STAGE CCI-RATE DIAGNOSTIC ARTIFACTS ====='
rm -rf "$stage"
mkdir -p "$stage"
cp "$cci_ko" "$stage/i2c-qcom-cci.ko"
cp "$symbols" "$stage/i2c-qcom-cci.symbols.txt"
cp "$log" "$stage/build.log"
cat > "$stage/BUILD-INFO.txt" <<EOF_INFO
kernel_release=$release
source_tree=$src
source_mode=stock-ubuntu-temporary-copy
cci_module_vermagic=$vermagic
diagnostic_only=true
diagnostic_generation=platform-power-f0-cci-rate-no-cpas-mmio-v1
diagnostic_trigger=a14_f0_cci_rate_diag/a14_f0_cci_rate_probe
diagnostic_status=a14_f0_cci_rate_diag/a14_f0_cci_rate_status
dtb_changes=false
direct_cpas_mmio_allowed=false
ssc_activation_allowed=false
cci_target_rate=37500000
hold_ms=250
exact_round_rate_required=true
restore_original_rate=true
runtime_pm=existing-i2c-qcom-cci
system_changes=false
EOF_INFO
(
    cd "$stage"
    sha256sum i2c-qcom-cci.ko i2c-qcom-cci.symbols.txt BUILD-INFO.txt build.log > SHA256SUMS
)
printf 'artifact_directory=%s\n' "$stage"
printf '%s\n' 'build_result=success'
