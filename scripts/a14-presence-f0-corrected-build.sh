#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# One-shot builder for the A14 corrected-protocol + full-F0/no-mux presence
# discriminator. This performs build-tree reconstruction only; it does not
# install modules, modify boot files, or touch the CPAS ownership mux.
set -Eeuo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo"

release=${A14_KERNEL_RELEASE:-$(uname -r)}
base_work=${A14_AOS_F0_ICP_OWNER_BASE_WORK:-"$HOME/Downloads/a14-aos-f0-icp-owner-base-$release"}
work=${A14_AOS_F0_ICP_OWNER_WORK:-"$HOME/Downloads/a14-aos-f0-icp-owner-diag-$release"}

printf '%s\n' 'A14 corrected SSC + full-F0/no-mux presence build'
printf '%s\n' '================================================='
printf 'kernel_release=%s\n' "$release"
printf '%s\n' 'direct_cpas_mmio=false'
printf '%s\n' 'cpas_ownership_mux_access=false'
printf '%s\n' 'init576=ov02c10,restart_count=0,camera_id=2'

printf '\n%s\n' '===== RECONSTRUCT WINDOWS-CORRECT SSC WIRE FORMAT ====='
bash "$repo/scripts/a14-f0-wirefix-reconstruct.sh"

printf '\n%s\n' '===== NORMALIZE LIVE 7.1.5 CSIPHY WINDOWS ====='
bash "$repo/scripts/a14-fix-7.1.5-csiphy-layout.sh"

# These are generated diagnostic build trees only. A stale source cache may
# contain the retired 0x1000 CSIPHY resources even after the repository inputs
# are corrected, so do not reuse it for a safety-sensitive discriminator.
printf '\n%s\n' '===== DROP GENERATED STALE F0 WORK TREES ====='
printf 'remove_generated=%s\n' "$base_work"
printf 'remove_generated=%s\n' "$work"
rm -rf -- "$base_work" "$work"

printf '\n%s\n' '===== BUILD CORRECTED FULL-F0 DISCRIMINATOR ====='
exec bash "$repo/scripts/a14-aos-f0-ssc-handshake-build.sh"
