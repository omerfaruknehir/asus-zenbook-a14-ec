#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Corrected coherent full-module build for A14 ACPI GPUCC live V1.
set -euo pipefail

KREL="7.1.5-a14-acpi-full0"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="${A14_74C9_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="$WORK/linux-7.1.5"
OUT="$WORK/build"
TRANSFORM="$ROOT/scripts/apply-a14-full-acpi-gpucc-live-v1.py"
STAMP="$WORK/gpucc-live-v1.ready"

IMAGE="$OUT/arch/arm64/boot/Image"
MSM_OBJ="$OUT/drivers/gpu/drm/msm/msm_drv.o"
MSM_KO="$OUT/drivers/gpu/drm/msm/msm.ko"
GPUCC_OBJ="$OUT/drivers/clk/qcom/gpucc-x1e80100.o"
GPUCC_KO="$OUT/drivers/clk/qcom/gpucc-x1e80100.ko"
COMMON_OBJ="$OUT/drivers/clk/qcom/common.o"
GDSC_OBJ="$OUT/drivers/clk/qcom/gdsc.o"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

[[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as normal user"
for c in python3 make sha256sum grep modinfo nproc awk; do need "$c"; done

[[ -f "$SRC/Makefile" && -f "$OUT/.config" && -s "$OUT/vmlinux" ]] || die "A14 build tree missing"
[[ -f "$TRANSFORM" ]] || die "missing transform: $TRANSFORM"

export LOCALVERSION=
actual="$(make -s -C "$SRC" O="$OUT" kernelrelease)"
[[ "$actual" == "$KREL" ]] || die "kernelrelease mismatch: $actual"

grep -q '^CONFIG_DRM_MSM=m$' "$OUT/.config" || die "expected CONFIG_DRM_MSM=m"
grep -q '^CONFIG_CLK_X1E80100_GPUCC=m$' "$OUT/.config" || die "expected CONFIG_CLK_X1E80100_GPUCC=m"
grep -q '^CONFIG_COMMON_CLK_QCOM=y$' "$OUT/.config" || die "expected CONFIG_COMMON_CLK_QCOM=y"
grep -q '^CONFIG_QCOM_GDSC=y$' "$OUT/.config" || die "expected CONFIG_QCOM_GDSC=y"
grep -q 'A14_ACPI_DMA_IORT_IDS_V1' "$SRC/drivers/acpi/scan.c" || die "topology V3 prerequisite missing"

say "A14_GPUCC_LIVE_V1_BUILD_V2=START"
say "reason=coherent_full_module_modpost"
say "kernelrelease=$KREL"
say "gpucc_mmio=0x03d90000+0xa000_firmware_validated"
say "gpu_live=false"
say "gmu_live=false"
say "gcc_live=false"
say "rpmh_synthesized=false"
say "module_build_scope=full_kernel_modules"

rm -f "$STAMP"
python3 "$TRANSFORM" "$SRC"
python3 "$TRANSFORM" "$SRC"

# Verify the transformed sources before invoking the build.
grep -q 'A14_GPUCC_LIVE_V1' "$SRC/drivers/gpu/drm/msm/msm_drv.c" || die "MSM live stage missing"
grep -q 'A14_GPUCC_LIVE_V1' "$SRC/drivers/clk/qcom/gpucc-x1e80100.c" || die "GPUCC live stage missing"
grep -q 'A14_QCOM_CC_NON_OF_PROVIDER_V1' "$SRC/drivers/clk/qcom/common.c" || die "non-OF qcom-cc guard missing"
grep -q 'A14_GDSC_NON_OF_PROVIDER_V1' "$SRC/drivers/clk/qcom/gdsc.c" || die "non-OF GDSC guard missing"

# Force every source modified by this stage to rebuild. Crucially, do NOT run
# isolated M=... module builds after Image: Image-only modpost does not provide
# the complete modular DRM symbol graph. Build Image + the complete module graph
# coherently so Module.symvers is regenerated with all module exports.
rm -f "$COMMON_OBJ" "$OUT/drivers/clk/qcom/.common.o.cmd"
rm -f "$GDSC_OBJ" "$OUT/drivers/clk/qcom/.gdsc.o.cmd"
rm -f "$MSM_OBJ" "$OUT/drivers/gpu/drm/msm/.msm_drv.o.cmd" \
      "$OUT/drivers/gpu/drm/msm/msm.o" "$MSM_KO"
rm -f "$GPUCC_OBJ" "$OUT/drivers/clk/qcom/.gpucc-x1e80100.o.cmd" "$GPUCC_KO"

make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" Image modules

[[ -s "$IMAGE" && -s "$COMMON_OBJ" && -s "$GDSC_OBJ" ]] || die "rebuilt Image/qcom objects missing"
[[ -s "$MSM_KO" && -s "$MSM_OBJ" ]] || die "rebuilt msm.ko missing"
[[ -s "$GPUCC_KO" && -s "$GPUCC_OBJ" ]] || die "rebuilt gpucc-x1e80100.ko missing"
[[ -s "$OUT/Module.symvers" ]] || die "coherent Module.symvers missing"

grep -aFq 'A14GPUCC-LIVE: parent proxy' "$MSM_KO" || die "compiled msm.ko lacks parent proxies"
grep -aFq 'gpucc_live=true' "$MSM_KO" || die "compiled msm.ko lacks live marker"
modinfo -F alias "$MSM_KO" | grep -Fq 'QCOM0C36' || die "compiled msm.ko lacks QCOM0C36 alias"

grep -aFq 'A14GPUCC-LIVE: validated firmware-derived MMIO' "$GPUCC_KO" || die "compiled GPUCC module lacks MMIO gate"
modinfo -F alias "$GPUCC_KO" | grep -Fq 'platform:gpucc-x1e80100' || die "compiled GPUCC module lacks platform alias"

msm_vermagic="$(modinfo -F vermagic "$MSM_KO" | awk '{print $1}')"
gpucc_vermagic="$(modinfo -F vermagic "$GPUCC_KO" | awk '{print $1}')"
[[ "$msm_vermagic" == "$KREL" ]] || die "msm.ko vermagic mismatch: $msm_vermagic"
[[ "$gpucc_vermagic" == "$KREL" ]] || die "gpucc vermagic mismatch: $gpucc_vermagic"

image_sha="$(sha256sum "$IMAGE" | awk '{print $1}')"
msm_sha="$(sha256sum "$MSM_KO" | awk '{print $1}')"
gpucc_sha="$(sha256sum "$GPUCC_KO" | awk '{print $1}')"

cat >"$STAMP" <<EOSTAMP
kernelrelease=$KREL
image_sha256=$image_sha
msm_ko_sha256=$msm_sha
gpucc_ko_sha256=$gpucc_sha
gpucc_mmio=0x03d90000+0xa000
gpu_live=no
gmu_live=no
gcc_live=no
rpmh_synthesized=no
temporary_parent_proxies=19200000,600000000,300000000
build_scope=full_kernel_modules
EOSTAMP

say "A14_GPUCC_LIVE_V1_BUILD_V2=COMPLETE"
say "image_sha256=$image_sha"
say "msm_ko_sha256=$msm_sha"
say "gpucc_ko_sha256=$gpucc_sha"
say "module_symvers=COHERENT_FULL_GRAPH"
say "next=sudo bash scripts/a14-full-acpi-gpucc-live-v1.sh install"
