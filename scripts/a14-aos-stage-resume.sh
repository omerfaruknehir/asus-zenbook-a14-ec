#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Resume a staged A14 CAMSS AOS build after the DTB and CAMSS module exist.
set -Eeuo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
release=${A14_KERNEL_RELEASE:-$(uname -r)}
headers="/lib/modules/$release/build"
work=${A14_AOS_WORKDIR:-"$HOME/Downloads/a14-aos-stage-$release"}
camss_modsrc="$work/qcom-camss-module"
dtb_obj="$work/dtb-object"
stage="$work/artifacts"
log="$work/build.log"
jobs=${JOBS:-$(nproc 2>/dev/null || printf '4')}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this as your normal user, not with sudo"
[ -f "$headers/Makefile" ] || fail "kernel headers are missing: $headers"

camss_ko="$camss_modsrc/qcom-camss.ko"
camss_symvers="$camss_modsrc/Module.symvers"
camss_include="$camss_modsrc/include"
patched_dtb="$dtb_obj/arch/arm64/boot/dts/qcom/x1e80100-asus-zenbook-a14.dtb"

[ -s "$camss_ko" ] || fail "staged qcom-camss.ko is missing: $camss_ko"
[ -s "$camss_symvers" ] || fail "staged CAMSS Module.symvers is missing: $camss_symvers"
[ -s "$camss_include/media/qcom_camss.h" ] || fail "staged CAMSS public header is missing"
[ -s "$patched_dtb" ] || fail "staged patched DTB is missing: $patched_dtb"

exec > >(tee -a "$log") 2>&1

printf '%s\n' 'A14 CAMSS AOS staged build resume'
printf '%s\n' '================================='
printf 'kernel_release=%s\n' "$release"
printf 'work=%s\n' "$work"
printf 'system_changes=false\n'

printf '\n%s\n' '===== REVALIDATE PATCHED DTB ====='
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

printf '\n%s\n' '===== REVALIDATE QCOM-CAMSS MODULE ====='
camss_vermagic=$(modinfo -F vermagic "$camss_ko")
case "$camss_vermagic" in
    "$release "*) ;;
    *) fail "CAMSS module vermagic does not match $release: $camss_vermagic" ;;
esac

camss_symbols="$work/qcom-camss.symbols.txt"
readelf -Ws "$camss_ko" > "$camss_symbols"
grep -Fq 'qcom_camss_aon_acquire' "$camss_symbols" || fail "CAMSS acquire symbol is missing"
grep -Fq 'qcom_camss_aon_release' "$camss_symbols" || fail "CAMSS release symbol is missing"
grep -Fq 'qcom_camss_aon_acquire' "$camss_symvers" || fail "CAMSS acquire symbol CRC is missing"
grep -Fq 'qcom_camss_aon_release' "$camss_symvers" || fail "CAMSS release symbol CRC is missing"
printf '%s\n' 'qcom_camss_module=validated'

grep -F 'qcom_camss_aon_' "$camss_symbols" || true
grep -F 'qcom_camss_aon_' "$camss_symvers" || true

printf '\n%s\n' '===== HANDOFF-ENABLED SSC MODULE ====='
make -C "$repo/kernel/aos" clean KDIR="$headers"
make -C "$repo/kernel/aos" \
    KDIR="$headers" \
    W=1 \
    AOS_CAMSS_HANDOFF=1 \
    AOS_CAMSS_INCLUDE="$camss_include" \
    KBUILD_EXTRA_SYMBOLS="$camss_symvers" \
    -j"$jobs"

ssc_ko="$repo/kernel/aos/qcom_ssc_hpd.ko"
[ -s "$ssc_ko" ] || fail "handoff-enabled qcom_ssc_hpd.ko was not produced"
ssc_vermagic=$(modinfo -F vermagic "$ssc_ko")
case "$ssc_vermagic" in
    "$release "*) ;;
    *) fail "SSC module vermagic does not match $release: $ssc_vermagic" ;;
esac
ssc_depends=$(modinfo -F depends "$ssc_ko")
printf 'ssc_depends=%s\n' "$ssc_depends"
case ",$ssc_depends," in
    *,qcom-camss,*) ;;
    *) fail "SSC module does not declare its qcom-camss dependency" ;;
esac
printf '%s\n' 'qcom_ssc_hpd_module=validated'

printf '\n%s\n' '===== STAGED ARTIFACTS ====='
rm -rf "$stage"
mkdir -p "$stage"
cp "$camss_ko" "$stage/qcom-camss.ko"
cp "$ssc_ko" "$stage/qcom_ssc_hpd.ko"
cp "$patched_dtb" "$stage/x1e80100-asus-zenbook-a14-aos-cpas.dtb"
[ -s "$work/preflight.txt" ] && cp "$work/preflight.txt" "$stage/preflight.txt"
cp "$log" "$stage/build.log"
cp "$camss_symbols" "$stage/qcom-camss.symbols.txt"
cat > "$stage/BUILD-INFO.txt" <<EOF
kernel_release=$release
camss_module_vermagic=$camss_vermagic
ssc_module_vermagic=$ssc_vermagic
ssc_module_depends=$ssc_depends
camss_resource_count=18
camss_resource_17=cpas-top,0x0ac19000,0x0c000
system_changes=false
EOF
(
    cd "$stage"
    files=(qcom-camss.ko qcom_ssc_hpd.ko \
        x1e80100-asus-zenbook-a14-aos-cpas.dtb BUILD-INFO.txt \
        qcom-camss.symbols.txt build.log)
    [ -s preflight.txt ] && files+=(preflight.txt)
    sha256sum "${files[@]}" > SHA256SUMS
)

printf 'artifact_directory=%s\n' "$stage"
printf '%s\n' 'system_changes=false'
printf '%s\n' 'build_result=success'
