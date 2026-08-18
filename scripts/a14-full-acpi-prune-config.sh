#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Prune graphics drivers that are impossible/irrelevant on the fixed UX3407RA
# Snapdragon X Elite target while preserving the Qualcomm MSM DRM path.
set -euo pipefail

SRC="${1:?usage: $0 <kernel-source> <build-output>}"
OUT="${2:?usage: $0 <kernel-source> <build-output>}"
CFG="$SRC/scripts/config"
CONFIG="$OUT/.config"

[[ -x "$CFG" ]] || { echo "ERROR: missing scripts/config: $CFG" >&2; exit 1; }
[[ -f "$CONFIG" ]] || { echo "ERROR: missing build config: $CONFIG" >&2; exit 1; }

c(){ "$CFG" --file "$CONFIG" "$@"; }

# Keep the only hardware DRM stack relevant to this machine, plus simpledrm as
# the firmware-framebuffer fallback while native Adreno/display ACPI support is
# still under development.
c --enable DRM
c --enable DRM_MSM
c --enable DRM_SIMPLEDRM

# Discrete/virtual PC graphics stacks not present in this Snapdragon laptop.
for sym in \
    DRM_AMDGPU DRM_RADEON DRM_NOUVEAU DRM_I915 DRM_XE \
    DRM_VMWGFX DRM_VIRTIO_GPU DRM_QXL DRM_AST DRM_MGAG200 DRM_BOCHS; do
    c --disable "$sym"
done

# Other SoC GPU/display stacks that cannot drive the X1E80100 Adreno/DPU.
for sym in \
    DRM_PANFROST DRM_PANTHOR DRM_LIMA DRM_ETNAVIV DRM_V3D DRM_VC4 \
    DRM_TEGRA DRM_EXYNOS DRM_ROCKCHIP DRM_SUN4I DRM_HISI_HIBMC \
    DRM_HISI_KIRIN DRM_KOMEDA DRM_MEDIATEK DRM_MESON DRM_OMAP \
    DRM_RCAR_DU DRM_SHMOBILE DRM_TILCDC DRM_MXSFB; do
    c --disable "$sym"
done

export LOCALVERSION=
make -s -C "$SRC" O="$OUT" olddefconfig

# Hard safety checks: Qualcomm DRM stays available and the obviously unrelated
# GPU stacks stay gone after dependency resolution.
grep -Eq '^CONFIG_DRM_MSM=(y|m)$' "$CONFIG" || {
    echo "ERROR: CONFIG_DRM_MSM was lost by olddefconfig" >&2; exit 1;
}
grep -Eq '^CONFIG_DRM_SIMPLEDRM=(y|m)$' "$CONFIG" || {
    echo "ERROR: CONFIG_DRM_SIMPLEDRM was lost by olddefconfig" >&2; exit 1;
}
for sym in DRM_AMDGPU DRM_RADEON DRM_NOUVEAU DRM_I915 DRM_XE; do
    if grep -Eq "^CONFIG_${sym}=(y|m)$" "$CONFIG"; then
        echo "ERROR: irrelevant graphics driver survived pruning: CONFIG_${sym}" >&2
        exit 1
    fi
done

echo "A14_CONFIG_PRUNE=VERIFIED"
echo "kept=DRM_MSM,DRM_SIMPLEDRM"
echo "disabled=AMDGPU,Radeon,Nouveau,i915,Xe,and unrelated SoC DRM stacks"
