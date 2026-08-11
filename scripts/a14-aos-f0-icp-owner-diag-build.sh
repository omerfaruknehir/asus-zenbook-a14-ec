#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Build/stage the isolated full-F0 ICP ownership diagnostic. No live activation.
set -Eeuo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
release=${A14_KERNEL_RELEASE:-$(uname -r)}
headers="/lib/modules/$release/build"
base_work=${A14_AOS_F0_ICP_OWNER_BASE_WORK:-"$HOME/Downloads/a14-aos-f0-icp-owner-base-$release"}
work=${A14_AOS_F0_ICP_OWNER_WORK:-"$HOME/Downloads/a14-aos-f0-icp-owner-diag-$release"}
cci_modsrc="$work/i2c-qcom-cci-module"
camss_modsrc="$work/qcom-camss-module"
stage="$work/artifacts"
log="$work/build.log"
injector="$repo/scripts/a14-aos-f0-icp-owner-diag-inject.py"
jobs=${JOBS:-$(nproc 2>/dev/null || printf '4')}

mkdir -p "$work"
exec > >(tee "$log") 2>&1

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
on_error() {
    status=$?
    printf '\nF0 ICP owner diagnostic build stopped at line %s with status %s.\n' "$1" "$status" >&2
    printf 'Log: %s\n' "$log" >&2
    exit "$status"
}
trap 'on_error $LINENO' ERR

for tool in bash cp cpp dtc fdtget find grep make modinfo nm python3 readelf \
            rm sha256sum strings tee uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this builder as your normal user, not with sudo"
[ -f "$headers/Makefile" ] || fail "kernel headers are missing: $headers"
[ -r "$headers/Module.symvers" ] || fail "installed Module.symvers is missing"
[ -s "$injector" ] || fail "ICP owner diagnostic injector is missing: $injector"

printf '%s\n' 'A14 full Windows-F0 ICP ownership diagnostic build'
printf '%s\n' '================================================='
printf 'kernel_release=%s\n' "$release"
printf 'base_work=%s\n' "$base_work"
printf 'work=%s\n' "$work"
printf '%s\n' 'operation=build-and-stage-only'
printf '%s\n' 'diagnostic_only=true'
printf '%s\n' 'direct_cpas_mmio_allowed=false'
printf '%s\n' 'ssc_activation_allowed=false'
printf '%s\n' 'icp_activation_during_build=false'
printf '%s\n' 'system_changes=false'

printf '\n%s\n' '===== BUILD FRESH PRODUCTION OWNERSHIP BASE ====='
# A dedicated default work directory prevents the stage builder from seeing an
# older partially patched source cache from earlier AOS experiments.
A14_AOS_WORKDIR="$base_work" bash "$repo/scripts/a14-aos-stage-build.sh"

camss_source=$(find "$base_work/source" -type f \
    -path '*/drivers/media/platform/qcom/camss/camss.c' -print -quit)
[ -n "$camss_source" ] || fail "patched CAMSS source was not found in fresh base work"
src=${camss_source%/drivers/media/platform/qcom/camss/camss.c}
cci_source="$src/drivers/i2c/busses/i2c-qcom-cci.c"
cci_header="$src/include/linux/i2c-qcom-cci.h"
base_stage="$base_work/artifacts"
patched_dtb="$base_stage/x1e80100-asus-zenbook-a14-aos-cpas.dtb"

[ -s "$cci_source" ] || fail "patched Qualcomm CCI source is missing"
[ -s "$cci_header" ] || fail "CCI owner API header is missing"
[ -s "$patched_dtb" ] || fail "patched A14 DTB is missing"
grep -q 'aon_platform_clks\[0\].id = "icp_ahb"' "$camss_source" || \
    fail "Stage A ICP ownership is missing from CAMSS source"
grep -q 'qcom_cci_platform_hold_get' "$cci_source" || \
    fail "Stage B CCI hold API is missing"
grep -q 'platform_hold_faulted' "$cci_source" || \
    fail "fail-closed CCI restore hardening is missing"

read -r -a clock_names <<< "$(fdtget -t s "$patched_dtb" /soc@0/isp@acb7000 clock-names)"
[ "${#clock_names[@]}" -eq 31 ] || \
    fail "patched DTB has ${#clock_names[@]} CAMSS clocks, expected 31"
[ "${clock_names[29]}" = icp_ahb ] || fail "patched DTB clock 29 is not icp_ahb"
[ "${clock_names[30]}" = icp ] || fail "patched DTB clock 30 is not icp"
printf '%s\n' 'production_ownership_base=validated'

printf '\n%s\n' '===== BUILD SYMBOLIC HM1092-SAFE CAMSS OVERLAY ====='
overlay_dts="$work/a14-f0-icp-owner-overlay.dts"
overlay_pp="$work/a14-f0-icp-owner-overlay.pp.dts"
overlay_dtbo="$work/a14-f0-icp-owner-overlay.dtbo"
cat > "$overlay_dts" <<'DTS'
#include <dt-bindings/clock/qcom,x1e80100-camcc.h>
#include <dt-bindings/clock/qcom,x1e80100-gcc.h>
/dts-v1/;
/plugin/;

/ {
    fragment@0 {
        target-path = "/soc@0/isp@acb7000";

        __overlay__ {
            reg = <0 0x0acb7000 0 0x2000>,
                  <0 0x0acb9000 0 0x2000>,
                  <0 0x0acbb000 0 0x2000>,
                  <0 0x0acc6000 0 0x1000>,
                  <0 0x0acca000 0 0x1000>,
                  <0 0x0acb6000 0 0x1000>,
                  <0 0x0ace4000 0 0x1000>,
                  <0 0x0ace6000 0 0x1000>,
                  <0 0x0ace8000 0 0x1000>,
                  <0 0x0acec000 0 0x4000>,
                  <0 0x0acf6000 0 0x1000>,
                  <0 0x0acf7000 0 0x1000>,
                  <0 0x0acf8000 0 0x1000>,
                  <0 0x0ac62000 0 0xf000>,
                  <0 0x0ac71000 0 0xf000>,
                  <0 0x0acc7000 0 0x2000>,
                  <0 0x0accb000 0 0x2000>,
                  <0 0x0ac19000 0 0xc000>;

            reg-names = "csid0", "csid1", "csid2",
                        "csid_lite0", "csid_lite1", "csid_wrapper",
                        "csiphy0", "csiphy1", "csiphy2", "csiphy4",
                        "csitpg0", "csitpg1", "csitpg2",
                        "vfe0", "vfe1", "vfe_lite0", "vfe_lite1",
                        "cpas-top";

            clocks = <&camcc CAM_CC_CAMNOC_AXI_NRT_CLK>,
                     <&camcc CAM_CC_CAMNOC_AXI_RT_CLK>,
                     <&camcc CAM_CC_CORE_AHB_CLK>,
                     <&camcc CAM_CC_CPAS_AHB_CLK>,
                     <&camcc CAM_CC_CPAS_FAST_AHB_CLK>,
                     <&camcc CAM_CC_CPAS_IFE_0_CLK>,
                     <&camcc CAM_CC_CPAS_IFE_1_CLK>,
                     <&camcc CAM_CC_CPAS_IFE_LITE_CLK>,
                     <&camcc CAM_CC_CPHY_RX_CLK_SRC>,
                     <&camcc CAM_CC_CSID_CLK>,
                     <&camcc CAM_CC_CSID_CSIPHY_RX_CLK>,
                     <&camcc CAM_CC_CSIPHY0_CLK>,
                     <&camcc CAM_CC_CSI0PHYTIMER_CLK>,
                     <&camcc CAM_CC_CSIPHY1_CLK>,
                     <&camcc CAM_CC_CSI1PHYTIMER_CLK>,
                     <&camcc CAM_CC_CSIPHY2_CLK>,
                     <&camcc CAM_CC_CSI2PHYTIMER_CLK>,
                     <&camcc CAM_CC_CSIPHY4_CLK>,
                     <&camcc CAM_CC_CSI4PHYTIMER_CLK>,
                     <&gcc GCC_CAMERA_HF_AXI_CLK>,
                     <&gcc GCC_CAMERA_SF_AXI_CLK>,
                     <&camcc CAM_CC_IFE_0_CLK>,
                     <&camcc CAM_CC_IFE_0_FAST_AHB_CLK>,
                     <&camcc CAM_CC_IFE_1_CLK>,
                     <&camcc CAM_CC_IFE_1_FAST_AHB_CLK>,
                     <&camcc CAM_CC_IFE_LITE_CLK>,
                     <&camcc CAM_CC_IFE_LITE_AHB_CLK>,
                     <&camcc CAM_CC_IFE_LITE_CPHY_RX_CLK>,
                     <&camcc CAM_CC_IFE_LITE_CSID_CLK>,
                     <&camcc CAM_CC_ICP_AHB_CLK>,
                     <&camcc CAM_CC_ICP_CLK>;

            clock-names = "camnoc_nrt_axi", "camnoc_rt_axi", "core_ahb",
                          "cpas_ahb", "cpas_fast_ahb", "cpas_vfe0",
                          "cpas_vfe1", "cpas_vfe_lite", "cphy_rx_clk_src",
                          "csid", "csid_csiphy_rx", "csiphy0", "csiphy0_timer",
                          "csiphy1", "csiphy1_timer", "csiphy2", "csiphy2_timer",
                          "csiphy4", "csiphy4_timer", "gcc_axi_hf", "gcc_axi_sf",
                          "vfe0", "vfe0_fast_ahb", "vfe1", "vfe1_fast_ahb",
                          "vfe_lite", "vfe_lite_ahb", "vfe_lite_cphy_rx",
                          "vfe_lite_csid", "icp_ahb", "icp";
        };
    };
};
DTS
cpp -nostdinc -undef -x assembler-with-cpp -I "$src/include" \
    "$overlay_dts" > "$overlay_pp"
dtc -@ -I dts -O dtb -o "$overlay_dtbo" "$overlay_pp"
[ -s "$overlay_dtbo" ] || fail "symbolic CAMSS overlay was not produced"
fdtget -t s "$overlay_dtbo" /__fixups__ camcc >/dev/null || \
    fail "overlay lacks camcc symbol fixups"
fdtget -t s "$overlay_dtbo" /__fixups__ gcc >/dev/null || \
    fail "overlay lacks gcc symbol fixups"
printf '%s\n' 'hm1092_safe_overlay=validated-symbolic-fixups'

printf '\n%s\n' '===== BUILD PATCHED CCI OWNER MODULE ====='
rm -rf "$cci_modsrc"
mkdir -p "$cci_modsrc/include/linux"
cp "$cci_source" "$cci_modsrc/i2c-qcom-cci.c"
cp "$cci_header" "$cci_modsrc/include/linux/i2c-qcom-cci.h"
cat > "$cci_modsrc/Makefile" <<'MAKE'
obj-m += i2c-qcom-cci.o
ccflags-y += -I$(src)/include
MAKE
make -C "$headers" M="$cci_modsrc" clean
make -C "$headers" M="$cci_modsrc" W=1 -j"$jobs" modules
cci_ko="$cci_modsrc/i2c-qcom-cci.ko"
[ -s "$cci_ko" ] || fail "patched i2c-qcom-cci.ko was not produced"
case "$(modinfo -F vermagic "$cci_ko")" in "$release "*) ;; *) fail "CCI vermagic mismatch" ;; esac
cci_symbols="$work/i2c-qcom-cci.symbols.txt"
readelf -Ws "$cci_ko" > "$cci_symbols"
grep -q 'qcom_cci_platform_hold_get' "$cci_symbols" || fail "CCI get symbol missing"
grep -q 'qcom_cci_platform_hold_put' "$cci_symbols" || fail "CCI put symbol missing"
grep -q 'qcom_cci_platform_hold_get' "$cci_modsrc/Module.symvers" || fail "CCI symbol CRC missing"
grep -aFq 'platform clock hold' "$cci_ko" || fail "CCI owner module lacks hold implementation"
printf '%s\n' 'cci_owner_module=validated'

printf '\n%s\n' '===== BUILD DIAGNOSTIC CAMSS OWNER MODULE ====='
rm -rf "$camss_modsrc"
mkdir -p "$camss_modsrc/include/media" "$camss_modsrc/include/linux"
cp -a "$src/drivers/media/platform/qcom/camss/." "$camss_modsrc/"
cp "$src/include/media/qcom_camss.h" "$camss_modsrc/include/media/"
cp "$cci_header" "$camss_modsrc/include/linux/i2c-qcom-cci.h"
printf '\nccflags-y += -I$(src)/include\n' >> "$camss_modsrc/Makefile"
python3 "$injector" "$camss_modsrc/camss.c"

grep -Fq 'AON-F0-ICP-OWNER-DIAG begin' "$camss_modsrc/camss.c" || \
    fail "ICP owner diagnostic marker is missing"
grep -Fq 'qcom_cci_platform_hold_get' "$camss_modsrc/camss.c" || \
    fail "diagnostic does not use the CCI owner API"
grep -Fq 'camss->aon_platform_clks' "$camss_modsrc/camss.c" || \
    fail "diagnostic does not use production ICP handles"
helper=$(sed -n \
    '/static int a14_camss_f0_icp_owner_probe/,/static DEVICE_ATTR_WO(a14_f0_icp_owner_probe)/p' \
    "$camss_modsrc/camss.c")
if grep -Eq '\<(readl|writel|ioread|iowrite|ioremap)\>' <<< "$helper"; then
    fail "ICP owner diagnostic contains prohibited direct MMIO"
fi
if grep -Eq 'qcom_ssc_hpd|camera.handshake|INIT 576' <<< "$helper"; then
    fail "ICP owner diagnostic contains an SSC path"
fi

make -C "$headers" M="$camss_modsrc" clean
make -C "$headers" M="$camss_modsrc" W=1 \
    KBUILD_EXTRA_SYMBOLS="$cci_modsrc/Module.symvers" -j"$jobs" modules
camss_ko="$camss_modsrc/qcom-camss.ko"
[ -s "$camss_ko" ] || fail "diagnostic qcom-camss.ko was not produced"
case "$(modinfo -F vermagic "$camss_ko")" in "$release "*) ;; *) fail "CAMSS vermagic mismatch" ;; esac
camss_undef="$work/qcom-camss.undefined.txt"
nm -u "$camss_ko" > "$camss_undef"
grep -q 'qcom_cci_platform_hold_get' "$camss_undef" || fail "CAMSS lacks CCI get dependency"
grep -q 'qcom_cci_platform_hold_put' "$camss_undef" || fail "CAMSS lacks CCI put dependency"
grep -aFq 'AON-F0-ICP-OWNER-DIAG targets-ok' "$camss_ko" || \
    fail "diagnostic target-hold implementation is missing"
camss_strings="$work/qcom-camss.strings.txt"
strings "$camss_ko" > "$camss_strings"
if grep -Eq 'AON-DIAG stage=3|ap-write-no-read|aon-switch-restore-no-read' "$camss_strings"; then
    fail "CAMSS diagnostic contains a retired direct-access test marker"
fi
printf '%s\n' 'camss_icp_owner_module=validated'

printf '\n%s\n' '===== STAGE ICP OWNER DIAGNOSTIC ====='
rm -rf "$stage"
mkdir -p "$stage"
cp "$camss_ko" "$stage/qcom-camss.ko"
cp "$cci_ko" "$stage/i2c-qcom-cci.ko"
cp "$overlay_dtbo" "$stage/a14-f0-icp-owner-overlay.dtbo"
cp "$patched_dtb" "$stage/reference-patched-a14.dtb"
cp "$log" "$stage/build.log"
cat > "$stage/BUILD-INFO.txt" <<EOF_INFO
kernel_release=$release
diagnostic_only=true
diagnostic_generation=platform-power-f0-icp-real-owners-no-mmio-v1
source_tree=$src
production_patch_series=0001-0008
uses_production_icp_handles=true
uses_production_cci_hold_api=true
cci0_target=37500000
cci1_target=37500000
camnoc_rt_target=300000000
camnoc_nrt_target=300000000
cpas_ahb_target=80000000
core_ahb_target=80000000
cpas_fast_ahb_target=100000000
icp_ahb_target=80000000
icp_target=400000000
hold_ms=250
direct_cpas_mmio_allowed=false
ssc_activation_allowed=false
isolated_boot_required=true
hm1092_base_overlay_required=true
icp_restore_exact_required=true
cci_restore_exact_required=true
camnoc_restore_limitation=known-19.2-to-240-parking-after-explicit-programming
icp_activation_during_build=false
system_changes=false
EOF_INFO
(
    cd "$stage"
    sha256sum qcom-camss.ko i2c-qcom-cci.ko a14-f0-icp-owner-overlay.dtbo \
        reference-patched-a14.dtb BUILD-INFO.txt build.log > SHA256SUMS
)

printf 'artifact_directory=%s\n' "$stage"
printf '%s\n' 'diagnostic_generation=platform-power-f0-icp-real-owners-no-mmio-v1'
printf '%s\n' 'direct_cpas_mmio_allowed=false'
printf '%s\n' 'ssc_activation_allowed=false'
printf '%s\n' 'icp_activation_during_build=false'
printf '%s\n' 'system_changes=false'
printf '%s\n' 'build_result=success'
