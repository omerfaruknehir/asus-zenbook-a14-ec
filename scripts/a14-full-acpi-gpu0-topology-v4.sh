#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# QCOM0C36 topology V4 runner.
#
# V3's ACPI/GPU source changes are unchanged.  V4 fixes only the msm.ko build
# method: build it as a native in-tree single .ko target so MODPOST consumes
# the current vmlinux.o export table instead of treating DRM/MSM as an external
# module tree that requires a pre-existing Module.symvers.
set -euo pipefail

ACTION="${1:-status}"
KREL="7.1.5-a14-acpi-full0"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
V3="$ROOT/scripts/a14-full-acpi-gpu0-topology-v3.sh"
TRANSFORM="$ROOT/scripts/apply-a14-full-acpi-gpu0-topology-v3.py"
WORK="${A14_74C9_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="$WORK/linux-7.1.5"
OUT="$WORK/build"
IMAGE="$OUT/arch/arm64/boot/Image"
SCAN_OBJ="$OUT/drivers/acpi/scan.o"
MSM_OBJ="$OUT/drivers/gpu/drm/msm/msm_drv.o"
MSM_KO="$OUT/drivers/gpu/drm/msm/msm.ko"
STAMP="$WORK/gpu0-topology-v3.ready"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_user(){ [[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as normal user"; }

verify_tree(){
    [[ -f "$SRC/Makefile" && -f "$OUT/.config" && -s "$OUT/vmlinux" ]] || die "A14 build tree missing"
    export LOCALVERSION=
    local actual
    actual="$(make -s -C "$SRC" O="$OUT" kernelrelease)"
    [[ "$actual" == "$KREL" ]] || die "kernelrelease mismatch: $actual"
    grep -q '^CONFIG_DRM_MSM=m$' "$OUT/.config" || die "expected CONFIG_DRM_MSM=m"
    grep -q '^CONFIG_ACPI=y$' "$OUT/.config" || die "CONFIG_ACPI=y required"
    grep -q '^CONFIG_ACPI_IORT=y$' "$OUT/.config" || die "CONFIG_ACPI_IORT=y required"
    grep -q '^CONFIG_MODULE_ALLOW_BTF_MISMATCH=y$' "$OUT/.config" || die "BTF compatibility missing"
}

verify_source(){
    local scan="$SRC/drivers/acpi/scan.c"
    local hdr="$SRC/include/acpi/acpi_bus.h"
    local iort="$SRC/drivers/acpi/arm64/iort.c"
    local msm="$SRC/drivers/gpu/drm/msm/msm_drv.c"

    grep -q 'A14_QCOM0C36_PLATFORM_ENUM_V1' "$scan" || die "QCOM0C36 enumeration prerequisite missing"
    grep -q 'A14_ACPI_DMA_IORT_IDS_V1' "$scan" || die "strict multi-ID ACPI helper missing"
    grep -q 'EXPORT_SYMBOL_GPL(acpi_dma_configure_iort_ids)' "$scan" || die "strict helper export missing"
    grep -q 'acpi_dma_configure_iort_ids' "$hdr" || die "strict helper declaration missing"
    ! grep -q 'EXPORT_SYMBOL_GPL(iort_iommu_configure_id)' "$iort" || die "temporary direct IORT export remains"
    grep -q 'A14_QCOM0C36_TOPOLOGY_V1' "$msm" || die "GPU topology bridge missing"
    [[ "$(grep -c 'acpi_dma_configure_iort_ids(' "$msm")" -eq 2 ]] || die "GPU/GMU ordered-IORT calls missing"
    grep -q 'a14-adreno-x185-acpi-topology' "$msm" || die "GPU child missing"
    grep -q 'a14-gmu-x185-acpi-topology' "$msm" || die "GMU child missing"
    grep -q 'a14-gpucc-x1e80100-acpi-topology' "$msm" || die "GPUCC child missing"
    grep -q 'no_mmio=true' "$msm" || die "no-MMIO marker missing"
}

build_fix(){
    need_user
    for c in python3 make sha256sum grep modinfo nproc awk; do need "$c"; done
    [[ -f "$TRANSFORM" ]] || die "missing V3 transform"
    verify_tree

    say "A14_GPU0_TOPOLOGY_V4_BUILD=START"
    say "source_transform=v3_unchanged"
    say "module_build_mode=in_tree_single_ko"
    say "module_target=drivers/gpu/drm/msm/msm.ko"
    say "full_module_rebuild=false"
    say "gpu_mmio_access=false"
    say "gpu_power_change=false"

    rm -f "$STAMP"
    python3 "$TRANSFORM" "$SRC"
    python3 "$TRANSFORM" "$SRC"
    verify_source

    export LOCALVERSION=

    # The previous failed V3 run already completed Image successfully.  Reuse
    # it when scan.o proves the strict ACPI helper was compiled; otherwise build
    # Image normally.
    if [[ -s "$IMAGE" && -s "$SCAN_OBJ" ]] && \
       grep -aFq 'acpi_dma_configure_iort_ids' "$SCAN_OBJ"; then
        say "image_rebuild=skipped_already_verified"
    else
        say "image_rebuild=required"
        rm -f "$SCAN_OBJ" "$OUT/drivers/acpi/.scan.o.cmd"
        make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" Image
        [[ -s "$IMAGE" && -s "$SCAN_OBJ" ]] || die "rebuilt Image/scan.o missing"
        grep -aFq 'acpi_dma_configure_iort_ids' "$SCAN_OBJ" || die "compiled scan.o lacks strict helper"
    fi

    [[ -s "$OUT/vmlinux.o" ]] || die "vmlinux.o missing; cannot perform native single-module MODPOST"

    # Clean artifacts left by V3's accidental external-module-style M= build.
    # This only removes generated files for the MSM directory; source files are
    # untouched.  Failure to find anything to clean is harmless.
    make -s -C "$SRC" O="$OUT" M=drivers/gpu/drm/msm clean || true

    # Force the modified MSM translation unit and final module to be rebuilt in
    # the real O= output tree.
    rm -f "$MSM_OBJ" "$OUT/drivers/gpu/drm/msm/.msm_drv.o.cmd" \
          "$OUT/drivers/gpu/drm/msm/msm.o" "$MSM_KO" \
          "$OUT/drivers/gpu/drm/msm/msm.mod" \
          "$OUT/drivers/gpu/drm/msm/msm.mod.c" \
          "$OUT/drivers/gpu/drm/msm/msm.mod.o"

    # Native Kbuild single-target mode.  Unlike `M=... modules`, this keeps
    # KBUILD_EXTMOD empty; scripts/Makefile.modpost therefore reads vmlinux.o
    # directly and resolves normal kernel/DRM exports without requiring an old
    # root Module.symvers.
    make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" \
         drivers/gpu/drm/msm/msm.ko

    [[ -s "$MSM_KO" && -s "$MSM_OBJ" ]] || die "native single-target msm.ko build missing"
    [[ -s "$OUT/Module.symvers" ]] || die "native MODPOST did not generate Module.symvers"
    grep -q $'\tplatform_device_put\t' "$OUT/Module.symvers" || \
        die "Module.symvers lacks normal vmlinux exports"
    grep -aFq 'A14GPU-TOPOLOGY: READY' "$MSM_KO" || die "compiled msm.ko lacks bridge"
    grep -aFq 'configured before DMA ops' "$MSM_KO" || die "compiled msm.ko lacks ordered-IORT path"
    modinfo -F alias "$MSM_KO" | grep -Fq 'QCOM0C36' || die "compiled msm.ko lacks QCOM0C36 alias"

    local vermagic image_sha msm_sha
    vermagic="$(modinfo -F vermagic "$MSM_KO" | awk '{print $1}')"
    [[ "$vermagic" == "$KREL" ]] || die "msm.ko vermagic mismatch: $vermagic"
    image_sha="$(sha256sum "$IMAGE" | awk '{print $1}')"
    msm_sha="$(sha256sum "$MSM_KO" | awk '{print $1}')"

    cat >"$STAMP" <<EOF
kernelrelease=$KREL
image_sha256=$image_sha
msm_ko_sha256=$msm_sha
gpu_iort_inputs=0x03030000,0x03030020
gmu_iort_input=0x03030060
iort_order=all_ids_before_dma_ops
gpu_streamids=0,1
gmu_streamid=5
gmu_watchdog_irq=firmware-unexposed
hardware_driver_binding=no
gpu_mmio_access=no
gpu_power_change=no
module_build_mode=in-tree-single-ko
EOF

    say "A14_GPU0_TOPOLOGY_V4_BUILD=COMPLETE"
    say "image_sha256=$image_sha"
    say "msm_ko_sha256=$msm_sha"
    say "module_symvers=VERIFIED"
    say "qcom0c36_alias=VERIFIED"
    say "ordered_iort_fwspec=VERIFIED"
    say "no_mmio_layer=VERIFIED"
    say "full_module_rebuild=false"
}

case "$ACTION" in
    build) build_fix ;;
    install|restore|status)
        [[ -x "$V3" || -f "$V3" ]] || die "missing V3 helper: $V3"
        exec bash "$V3" "$ACTION"
        ;;
    *) die "usage: $0 {build|install|restore|status}" ;;
esac
