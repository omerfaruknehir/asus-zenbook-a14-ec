#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# QCOM0C36 topology V4 runner.
#
# V3's ACPI/GPU source changes are unchanged. V4 fixes only module build
# mechanics. msm.ko is linked with the recursive in-tree module dependency
# closure from the installed same-KREL modules.dep, in one native Kbuild
# single-target MODPOST. Only msm.ko is installed afterwards.
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
MODROOT="/lib/modules/$KREL"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_user(){ [[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as normal user"; }

verify_tree(){
    [[ -f "$SRC/Makefile" && -f "$OUT/.config" && -s "$OUT/vmlinux" ]] || die "A14 build tree missing"
    [[ -d "$MODROOT" ]] || die "installed module tree missing: $MODROOT"
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

# Print the exact native Kbuild .ko targets required by the installed msm
# module's recursive dependency graph. The installed graph is from this exact
# KREL and the topology patch adds no new module-to-module dependency, so this
# is the authoritative closure for MODPOST. Built-in dependencies need no .ko
# target because vmlinux.o is passed by native Kbuild.
dependency_targets(){
    local dep_output path rel
    local msm_target="drivers/gpu/drm/msm/msm.ko"
    declare -A seen=()
    local -a targets=()

    dep_output="$(modprobe --set-version "$KREL" --show-depends msm)" || \
        die "modprobe could not resolve msm dependency closure for $KREL"

    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        case "$path" in
            "$MODROOT"/kernel/*.ko|"$MODROOT"/kernel/*.ko.zst|"$MODROOT"/kernel/*.ko.xz|"$MODROOT"/kernel/*.ko.gz)
                rel="${path#"$MODROOT"/kernel/}"
                case "$rel" in
                    *.ko.zst) rel="${rel%.zst}" ;;
                    *.ko.xz)  rel="${rel%.xz}" ;;
                    *.ko.gz)  rel="${rel%.gz}" ;;
                esac
                [[ "$rel" == *.ko ]] || die "bad module dependency path: $path"
                if [[ -z "${seen[$rel]:-}" ]]; then
                    targets+=("$rel")
                    seen[$rel]=1
                fi
                ;;
            "$MODROOT"/*)
                die "msm dependency is outside the in-tree kernel/ directory: $path"
                ;;
            *)
                die "unexpected msm dependency path: $path"
                ;;
        esac
    done < <(awk '$1 == "insmod" { print $2 }' <<<"$dep_output")

    if [[ -z "${seen[$msm_target]:-}" ]]; then
        targets+=("$msm_target")
        seen[$msm_target]=1
    fi

    ((${#targets[@]} > 1)) || die "msm dependency closure unexpectedly contains no module dependencies"
    printf '%s\n' "${targets[@]}"
}

build_fix(){
    need_user
    for c in python3 make sha256sum grep modinfo modprobe nproc awk mapfile; do
        if [[ "$c" == mapfile ]]; then
            type mapfile >/dev/null 2>&1 || die "bash mapfile builtin unavailable"
        else
            need "$c"
        fi
    done
    [[ -f "$TRANSFORM" ]] || die "missing V3 transform"
    verify_tree

    say "A14_GPU0_TOPOLOGY_V4_BUILD=START"
    say "source_transform=v3_unchanged"
    say "module_build_mode=in_tree_dependency_closure"
    say "module_install=msm.ko_only"
    say "full_module_rebuild=false"
    say "gpu_mmio_access=false"
    say "gpu_power_change=false"

    rm -f "$STAMP"
    python3 "$TRANSFORM" "$SRC"
    python3 "$TRANSFORM" "$SRC"
    verify_source

    export LOCALVERSION=

    # The failed V3/V4 attempts already completed the correct Image. Reuse it
    # when the compiled scan.o proves the strict ACPI helper is present.
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

    [[ -s "$OUT/vmlinux.o" ]] || die "vmlinux.o missing; native MODPOST cannot resolve built-in exports"

    local -a targets
    mapfile -t targets < <(dependency_targets)
    say "dependency_module_targets=${#targets[@]}"
    printf 'dependency_target=%s\n' "${targets[@]}"

    # Do not clean the MSM directory: the previous run already compiled most
    # of its large object set. Only force the one modified translation unit and
    # final MSM link metadata. Dependency modules are rebuilt only if Kbuild
    # determines they are missing or stale.
    rm -f "$MSM_OBJ" "$OUT/drivers/gpu/drm/msm/.msm_drv.o.cmd" \
          "$OUT/drivers/gpu/drm/msm/msm.o" "$MSM_KO" \
          "$OUT/drivers/gpu/drm/msm/msm.mod" \
          "$OUT/drivers/gpu/drm/msm/msm.mod.c" \
          "$OUT/drivers/gpu/drm/msm/msm.mod.o" \
          "$OUT/Module.symvers" "$OUT/modules.order"

    # Multiple native %.ko goals are handled by Kbuild's single-target mode in
    # one modules.order/MODPOST transaction. This exposes vmlinux exports and
    # every selected dependency module's exports/CRCs to msm.ko without a full
    # `make modules` build.
    make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" "${targets[@]}"

    [[ -s "$MSM_KO" && -s "$MSM_OBJ" ]] || die "dependency-closure msm.ko build missing"
    [[ -s "$OUT/Module.symvers" ]] || die "native MODPOST did not generate Module.symvers"
    grep -q $'\tplatform_device_put\t' "$OUT/Module.symvers" || \
        die "Module.symvers lacks vmlinux exports"
    grep -q $'\tdrm_sched_entity_push_job\t' "$OUT/Module.symvers" || \
        die "Module.symvers lacks DRM scheduler dependency exports"
    grep -q $'\tdrm_dp_aux_register\t' "$OUT/Module.symvers" || \
        die "Module.symvers lacks DRM display-helper dependency exports"

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
module_build_mode=in-tree-dependency-closure
dependency_modules_installed=no
EOF

    say "A14_GPU0_TOPOLOGY_V4_BUILD=COMPLETE"
    say "image_sha256=$image_sha"
    say "msm_ko_sha256=$msm_sha"
    say "module_symvers=VERIFIED_KERNEL_AND_MODULE_EXPORTS"
    say "qcom0c36_alias=VERIFIED"
    say "ordered_iort_fwspec=VERIFIED"
    say "dependency_modules_installed=false"
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
