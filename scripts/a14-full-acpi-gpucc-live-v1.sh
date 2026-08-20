#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# First live GPUCC stage for ASUS Zenbook A14 QCOM0C36 ACPI on Linux 7.1.5.
#
# Rebuilds only what this stage changes:
#   * Image, because qcom/common.c + gdsc.c are built in on this config
#   * msm.ko, because QCOM0C36 topology creates the GPUCC child/proxy parents
#   * gpucc-x1e80100.ko, because it gains non-DT parent fallback + MMIO gate
#
# The full module tree is NOT rebuilt. Instead, Kbuild's normal full modpost
# pass regenerates Module.symvers from already-built module objects, then the
# two changed modules are finalized individually against that symbol table.
# GPU and GMU remain deliberately unbound.
set -euo pipefail

ACTION="${1:-status}"
KREL="7.1.5-a14-acpi-full0"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="${A14_74C9_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="$WORK/linux-7.1.5"
OUT="$WORK/build"

IMAGE="$OUT/arch/arm64/boot/Image"
MSM_OBJ="$OUT/drivers/gpu/drm/msm/msm_drv.o"
MSM_LINK_OBJ="$OUT/drivers/gpu/drm/msm/msm.o"
MSM_KO="$OUT/drivers/gpu/drm/msm/msm.ko"
GPUCC_OBJ="$OUT/drivers/clk/qcom/gpucc-x1e80100.o"
GPUCC_KO="$OUT/drivers/clk/qcom/gpucc-x1e80100.ko"
COMMON_OBJ="$OUT/drivers/clk/qcom/common.o"
GDSC_OBJ="$OUT/drivers/clk/qcom/gdsc.o"
MODULE_SYMVERS="$OUT/Module.symvers"
MODULES_ORDER="$OUT/modules.order"

TRANSFORM="$ROOT/scripts/apply-a14-full-acpi-gpucc-live-v1.py"
AUDIT="$ROOT/scripts/a14-acpi-gpucc-live-v1-audit.sh"
PROGRESS="$ROOT/scripts/a14-kbuild-progress.py"
LOGDIR="$WORK/gpucc-live-v1-build-logs"
STAMP="$WORK/gpucc-live-v1.ready"

KERNEL="/boot/vmlinuz-$KREL"
CONFIG="/boot/config-$KREL"
SYSTEM_MAP="/boot/System.map-$KREL"
BACKUP_KERNEL="/boot/vmlinuz-$KREL.pre-gpucc-live-v1"
BACKUP_CONFIG="/boot/config-$KREL.pre-gpucc-live-v1"
BACKUP_MAP="/boot/System.map-$KREL.pre-gpucc-live-v1"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_user(){ [[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as normal user"; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "install/restore requires sudo/root"; }

run_kbuild(){
    local label="$1" logfile="$2"; shift 2
    local -a ps
    local rc_cmd rc_tee rc_progress

    mkdir -p "$LOGDIR"
    say "===== $label ====="
    set +e
    "$@" 2>&1 | tee "$logfile" | python3 "$PROGRESS" --label "$label" --logfile "$logfile"
    ps=("${PIPESTATUS[@]}")
    set -e

    rc_cmd="${ps[0]:-1}"
    rc_tee="${ps[1]:-1}"
    rc_progress="${ps[2]:-1}"
    if (( rc_cmd != 0 || rc_tee != 0 || rc_progress != 0 )); then
        say "ERROR: build phase failed: $label" >&2
        say "command_rc=$rc_cmd tee_rc=$rc_tee progress_rc=$rc_progress" >&2
        say "raw_log=$logfile" >&2
        tail -n 120 "$logfile" >&2 || true
        return 1
    fi
    say "A14_BUILD_PHASE_COMPLETE=$label"
}

verify_tree(){
    [[ -f "$SRC/Makefile" && -f "$OUT/.config" && -s "$OUT/vmlinux" ]] || die "A14 build tree missing"
    export LOCALVERSION=
    actual="$(make -s -C "$SRC" O="$OUT" kernelrelease)"
    [[ "$actual" == "$KREL" ]] || die "kernelrelease mismatch: $actual"

    grep -q '^CONFIG_ACPI=y$' "$OUT/.config" || die "CONFIG_ACPI=y required"
    grep -q '^CONFIG_ACPI_IORT=y$' "$OUT/.config" || die "CONFIG_ACPI_IORT=y required"
    grep -q '^CONFIG_ARM_SMMU=y$' "$OUT/.config" || die "CONFIG_ARM_SMMU=y required"
    grep -q '^CONFIG_DRM_MSM=m$' "$OUT/.config" || die "expected CONFIG_DRM_MSM=m"
    grep -q '^CONFIG_CLK_X1E80100_GPUCC=m$' "$OUT/.config" || die "expected CONFIG_CLK_X1E80100_GPUCC=m"
    grep -q '^CONFIG_COMMON_CLK_QCOM=y$' "$OUT/.config" || die "expected built-in CONFIG_COMMON_CLK_QCOM=y"
    grep -q '^CONFIG_QCOM_GDSC=y$' "$OUT/.config" || die "expected built-in CONFIG_QCOM_GDSC=y"
    grep -q '^CONFIG_QCOM_SCM=y$' "$OUT/.config" || die "SCM fix config missing"
    grep -q '^CONFIG_MODULE_ALLOW_BTF_MISMATCH=y$' "$OUT/.config" || die "BTF compatibility missing"

    grep -q 'A14_QCOM0C36_PLATFORM_ENUM_V1' "$SRC/drivers/acpi/scan.c" || die "QCOM0C36 enumeration prerequisite missing"
    grep -q 'A14_ACPI_DMA_IORT_IDS_V1' "$SRC/drivers/acpi/scan.c" || die "topology V3 IORT helper missing"
    grep -q 'A14_QCOM0C36_TOPOLOGY_V1' "$SRC/drivers/gpu/drm/msm/msm_drv.c" || die "GPU topology prerequisite missing"
    [[ -s "$MODULES_ORDER" ]] || die "full modules.order missing; baseline module build is required"
}

verify_source(){
    local msm="$SRC/drivers/gpu/drm/msm/msm_drv.c"
    local gpucc="$SRC/drivers/clk/qcom/gpucc-x1e80100.c"
    local common="$SRC/drivers/clk/qcom/common.c"
    local gdsc="$SRC/drivers/clk/qcom/gdsc.c"

    grep -q 'A14_GPUCC_LIVE_V1' "$msm" || die "MSM live-GPUCC bridge missing"
    grep -q 'a14-adreno-x185-acpi-topology' "$msm" || die "GPU staging child missing"
    grep -q 'a14-gmu-x185-acpi-topology' "$msm" || die "GMU staging child missing"
    grep -q 'a14_gpu0_add_child(pdev, "gpucc-x1e80100"' "$msm" || die "real GPUCC child missing"
    grep -q 'gpucc_live=true' "$msm" || die "GPUCC-live ready marker missing"
    grep -q 'gpu_gmu_unbound=true' "$msm" || die "GPU/GMU safety marker missing"

    ! grep -q 'a14_gpu0_add_child(pdev, "adreno"' "$msm" || die "SAFETY: real Adreno child unexpectedly enabled"
    ! grep -q 'a14_gpu0_add_child(pdev, "adreno-gmu"' "$msm" || die "SAFETY: real GMU child unexpectedly enabled"

    grep -q 'A14_GPUCC_LIVE_V1' "$gpucc" || die "GPUCC live patch missing"
    grep -q 'res->start != 0x03d90000' "$gpucc" || die "GPUCC MMIO base guard missing"
    grep -q 'resource_size(res) != 0x0000a000' "$gpucc" || die "GPUCC MMIO size guard missing"
    grep -q 'MODULE_ALIAS("platform:gpucc-x1e80100")' "$gpucc" || die "GPUCC platform alias missing"
    grep -q 'gcc_gpu_gpll0_cph_clk_src' "$gpucc" || die "GPUCC GPLL0 parent fallback missing"
    grep -q 'gcc_gpu_gpll0_div_cph_clk_src' "$gpucc" || die "GPUCC GPLL0-div parent fallback missing"

    grep -q 'A14_QCOM_CC_NON_OF_PROVIDER_V1' "$common" || die "non-OF qcom-cc guard missing"
    grep -q 'A14_GDSC_NON_OF_PROVIDER_V1' "$gdsc" || die "non-OF GDSC guard missing"
}

verify_full_module_objects(){
    local obj missing=0 shown=0
    while IFS= read -r obj; do
        [[ -n "$obj" ]] || continue
        if [[ ! -s "$OUT/$obj" ]]; then
            ((missing += 1))
            if (( shown < 20 )); then
                say "missing_module_object=$obj" >&2
                ((shown += 1))
            fi
        fi
    done < "$MODULES_ORDER"
    if (( missing != 0 )); then
        die "modules.order references $missing missing module object(s); stop here rather than falling back to a full module rebuild"
    fi
    say "full_module_object_graph=VERIFIED"
}

verify_symvers(){
    [[ -s "$MODULE_SYMVERS" ]] || die "Module.symvers missing after full modpost"
    local sym
    for sym in drm_dp_clock_recovery_ok drm_sched_entity_push_job drm_dsc_setup_rc_params drm_gpuvm_bo_put of_get_ocmem; do
        grep -qw "$sym" "$MODULE_SYMVERS" || die "Module.symvers still lacks required export: $sym"
    done
    say "module_symvers_dependency_graph=VERIFIED"
}

installed_module_path(){
    local module="$1" p
    p="$(modinfo -k "$KREL" -n "$module" 2>/dev/null || true)"
    [[ -n "$p" && "$p" != builtin ]] || return 1
    readlink -f "$p"
}

pack_like(){
    local target="$1" src="$2" dest="$3"
    case "$target" in
        *.ko) cp -f "$src" "$dest" ;;
        *.ko.zst) need zstd; zstd -q -f -19 "$src" -o "$dest" ;;
        *.ko.xz) need xz; xz -c -f "$src" >"$dest" ;;
        *.ko.gz) need gzip; gzip -c -f "$src" >"$dest" ;;
        *) die "unsupported module compression: $target" ;;
    esac
}

build_fix(){
    need_user
    for c in python3 make sha256sum grep modinfo nproc awk tee tail; do need "$c"; done
    verify_tree
    [[ -f "$TRANSFORM" ]] || die "missing transform: $TRANSFORM"
    [[ -f "$PROGRESS" ]] || die "missing progress helper: $PROGRESS"

    say "A14_GPUCC_LIVE_V1_BUILD=START"
    say "kernelrelease=$KREL"
    say "gpucc_mmio=0x03d90000+0xa000_firmware_validated"
    say "gpu_parent_proxy=bi-tcxo-div2-clk:19200000"
    say "gpu_parent_proxy=gcc_gpu_gpll0_cph_clk_src:600000000"
    say "gpu_parent_proxy=gcc_gpu_gpll0_div_cph_clk_src:300000000"
    say "gpu_live=false"
    say "gmu_live=false"
    say "gcc_live=false"
    say "rpmh_synthesized=false"
    say "full_module_rebuild=false"
    say "progress_bar=true"
    say "modules_rebuilt=msm.ko,gpucc-x1e80100.ko_only"

    rm -f "$STAMP"
    mkdir -p "$LOGDIR"
    python3 "$TRANSFORM" "$SRC"
    python3 "$TRANSFORM" "$SRC"
    verify_source

    export LOCALVERSION=
    jobs="${A14_BUILD_JOBS:-$(nproc)}"

    # Phase 1: common.c + gdsc.c are built into the Image. Force only these
    # objects stale, then let Kbuild relink the Image normally.
    rm -f "$COMMON_OBJ" "$OUT/drivers/clk/qcom/.common.o.cmd"
    rm -f "$GDSC_OBJ" "$OUT/drivers/clk/qcom/.gdsc.o.cmd"
    run_kbuild \
        "1/5 Image + non-OF qcom clock core" \
        "$LOGDIR/1-image.log" \
        make -C "$SRC" O="$OUT" -j"$jobs" Image
    [[ -s "$IMAGE" && -s "$COMMON_OBJ" && -s "$GDSC_OBJ" ]] || die "rebuilt Image/qcom objects missing"

    # Phase 2: rebuild the two changed module objects only. Building .o targets
    # does not invoke module modpost, so it is safe even though Image generation
    # has just refreshed vmlinux.symvers.
    rm -f "$MSM_OBJ" "$OUT/drivers/gpu/drm/msm/.msm_drv.o.cmd" "$MSM_LINK_OBJ"
    rm -f "$GPUCC_OBJ" "$OUT/drivers/clk/qcom/.gpucc-x1e80100.o.cmd"
    run_kbuild \
        "2/5 Changed GPUCC/MSM module objects" \
        "$LOGDIR/2-module-objects.log" \
        make -C "$SRC" O="$OUT" -j"$jobs" \
            drivers/gpu/drm/msm/msm.o \
            drivers/clk/qcom/gpucc-x1e80100.o
    [[ -s "$MSM_OBJ" && -s "$MSM_LINK_OBJ" && -s "$GPUCC_OBJ" ]] || die "target module objects missing after rebuild"

    # Phase 3: regenerate the normal in-tree Module.symvers from the already
    # built module object graph. This is a MODPOST pass only: no full 'modules'
    # target, no all-module compile/final-link loop.
    verify_full_module_objects
    run_kbuild \
        "3/5 Refresh full Module.symvers (modpost only)" \
        "$LOGDIR/3-modpost.log" \
        make -C "$SRC" O="$OUT" KBUILD_MODULES=1 modpost
    verify_symvers

    # Phases 4-5: finalize each changed module individually. M= builds import
    # the freshly regenerated top-level Module.symvers, which supplies the DRM
    # and other module exports that the old V1 isolated build was missing.
    rm -f "$MSM_KO"
    run_kbuild \
        "4/5 Finalize msm.ko" \
        "$LOGDIR/4-msm-ko.log" \
        make -C "$SRC" O="$OUT" -j"$jobs" M=drivers/gpu/drm/msm msm.ko
    [[ -s "$MSM_KO" ]] || die "targeted msm.ko build missing"
    grep -aFq 'A14GPUCC-LIVE: parent proxy' "$MSM_KO" || die "compiled msm.ko lacks parent proxies"
    grep -aFq 'gpucc_live=true' "$MSM_KO" || die "compiled msm.ko lacks live marker"
    modinfo -F alias "$MSM_KO" | grep -Fq 'QCOM0C36' || die "compiled msm.ko lacks QCOM0C36 alias"

    rm -f "$GPUCC_KO"
    run_kbuild \
        "5/5 Finalize gpucc-x1e80100.ko" \
        "$LOGDIR/5-gpucc-ko.log" \
        make -C "$SRC" O="$OUT" -j"$jobs" M=drivers/clk/qcom gpucc-x1e80100.ko
    [[ -s "$GPUCC_KO" ]] || die "gpucc-x1e80100.ko build missing"
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
full_module_rebuild=no
module_symvers_refresh=modpost-only
progress_bar=yes
EOSTAMP

    say "A14_GPUCC_LIVE_V1_BUILD=COMPLETE"
    say "image_sha256=$image_sha"
    say "msm_ko_sha256=$msm_sha"
    say "gpucc_ko_sha256=$gpucc_sha"
    say "module_symvers=FULL_GRAPH_REFRESHED_WITHOUT_FULL_MODULE_BUILD"
    say "gpucc_platform_alias=VERIFIED"
    say "gpu_gmu_unbound=VERIFIED"
    say "build_logs=$LOGDIR"
}

install_fix(){
    need_root
    for c in install sha256sum cmp awk cp modinfo depmod readlink; do need "$c"; done
    [[ "$(uname -r)" != "$KREL" ]] || die "boot the normal DT kernel before replacing the ACPI Image/modules"
    verify_tree
    verify_source
    [[ -r "$STAMP" ]] || die "successful GPUCC-live V1 build stamp missing"

    expected_image="$(awk -F= '$1=="image_sha256"{print $2}' "$STAMP")"
    expected_msm="$(awk -F= '$1=="msm_ko_sha256"{print $2}' "$STAMP")"
    expected_gpucc="$(awk -F= '$1=="gpucc_ko_sha256"{print $2}' "$STAMP")"

    [[ "$(sha256sum "$IMAGE" | awk '{print $1}')" == "$expected_image" ]] || die "Image changed since build"
    [[ "$(sha256sum "$MSM_KO" | awk '{print $1}')" == "$expected_msm" ]] || die "msm.ko changed since build"
    [[ "$(sha256sum "$GPUCC_KO" | awk '{print $1}')" == "$expected_gpucc" ]] || die "gpucc.ko changed since build"

    msm_target="$(installed_module_path msm)" || die "cannot locate installed msm module for $KREL"
    gpucc_target="$(installed_module_path gpucc_x1e80100)" || die "cannot locate installed gpucc_x1e80100 module for $KREL"

    case "$msm_target" in /lib/modules/$KREL/*) ;; *) die "unexpected msm path: $msm_target" ;; esac
    case "$gpucc_target" in /lib/modules/$KREL/*) ;; *) die "unexpected gpucc path: $gpucc_target" ;; esac

    msm_backup="$msm_target.pre-gpucc-live-v1"
    gpucc_backup="$gpucc_target.pre-gpucc-live-v1"

    [[ -e "$BACKUP_KERNEL" ]] || cp -a "$KERNEL" "$BACKUP_KERNEL"
    [[ ! -s "$CONFIG" || -e "$BACKUP_CONFIG" ]] || cp -a "$CONFIG" "$BACKUP_CONFIG"
    [[ ! -s "$SYSTEM_MAP" || -e "$BACKUP_MAP" ]] || cp -a "$SYSTEM_MAP" "$BACKUP_MAP"
    [[ -e "$msm_backup" ]] || cp -a "$msm_target" "$msm_backup"
    [[ -e "$gpucc_backup" ]] || cp -a "$gpucc_target" "$gpucc_backup"

    install -m0644 "$IMAGE" "$KERNEL"
    install -m0644 "$OUT/.config" "$CONFIG"
    [[ ! -s "$OUT/System.map" ]] || install -m0644 "$OUT/System.map" "$SYSTEM_MAP"
    cmp -s "$IMAGE" "$KERNEL" || die "installed Image mismatch"

    msm_suffix="${msm_target##*msm.ko}"
    msm_packed="$WORK/msm.ko.gpucc-live-v1.install${msm_suffix}"
    rm -f "$msm_packed"
    pack_like "$msm_target" "$MSM_KO" "$msm_packed"
    install -m0644 "$msm_packed" "$msm_target"
    rm -f "$msm_packed"

    gpucc_suffix="${gpucc_target##*gpucc-x1e80100.ko}"
    gpucc_packed="$WORK/gpucc-x1e80100.ko.gpucc-live-v1.install${gpucc_suffix}"
    rm -f "$gpucc_packed"
    pack_like "$gpucc_target" "$GPUCC_KO" "$gpucc_packed"
    install -m0644 "$gpucc_packed" "$gpucc_target"
    rm -f "$gpucc_packed"

    depmod -a "$KREL"

    modinfo -k "$KREL" -F alias msm | grep -Fq 'QCOM0C36' || die "installed MSM alias database lacks QCOM0C36"
    modinfo -k "$KREL" -F alias gpucc_x1e80100 | grep -Fq 'platform:gpucc-x1e80100' || die "installed GPUCC alias database lacks platform alias"

    say "A14_GPUCC_LIVE_V1_INSTALL=COMPLETE"
    say "installed_image_sha256=$expected_image"
    say "installed_msm_source_sha256=$expected_msm"
    say "installed_gpucc_source_sha256=$expected_gpucc"
    say "installed_msm_path=$msm_target"
    say "installed_gpucc_path=$gpucc_target"
    say "previous_image=$BACKUP_KERNEL"
    say "previous_msm=$msm_backup"
    say "previous_gpucc=$gpucc_backup"
    say "initramfs_unchanged=true"
    say "grub_unchanged=true"
}

restore_previous(){
    need_root
    for c in cp depmod modinfo readlink; do need "$c"; done
    [[ "$(uname -r)" != "$KREL" ]] || die "boot the normal DT kernel before restore"
    [[ -s "$BACKUP_KERNEL" ]] || die "pre-GPUCC-live Image backup missing"

    msm_target="$(installed_module_path msm)" || die "cannot locate installed msm module"
    gpucc_target="$(installed_module_path gpucc_x1e80100)" || die "cannot locate installed gpucc module"
    msm_backup="$msm_target.pre-gpucc-live-v1"
    gpucc_backup="$gpucc_target.pre-gpucc-live-v1"

    [[ -s "$msm_backup" ]] || die "pre-GPUCC-live msm backup missing"
    [[ -s "$gpucc_backup" ]] || die "pre-GPUCC-live gpucc backup missing"

    cp -a "$BACKUP_KERNEL" "$KERNEL"
    [[ ! -s "$BACKUP_CONFIG" ]] || cp -a "$BACKUP_CONFIG" "$CONFIG"
    [[ ! -s "$BACKUP_MAP" ]] || cp -a "$BACKUP_MAP" "$SYSTEM_MAP"
    cp -a "$msm_backup" "$msm_target"
    cp -a "$gpucc_backup" "$gpucc_target"
    depmod -a "$KREL"

    say "A14_GPUCC_LIVE_V1_RESTORE=COMPLETE"
}

status_fix(){
    say "running_kernel=$(uname -r)"
    say "work=$WORK"
    if msm_target="$(installed_module_path msm 2>/dev/null)"; then
        say "installed_msm=$msm_target"
    fi
    if gpucc_target="$(installed_module_path gpucc_x1e80100 2>/dev/null)"; then
        say "installed_gpucc=$gpucc_target"
        modinfo -k "$KREL" -F alias gpucc_x1e80100 2>/dev/null | grep -E 'platform:gpucc-x1e80100|qcom,x1e80100-gpucc' || true
    fi
    [[ -r "$STAMP" ]] && { say "--- GPUCC-live V1 stamp ---"; cat "$STAMP"; }
}

audit_fix(){
    [[ -f "$AUDIT" ]] || die "missing audit script: $AUDIT"
    exec bash "$AUDIT"
}

case "$ACTION" in
    build) build_fix ;;
    install) install_fix ;;
    restore) restore_previous ;;
    status) status_fix ;;
    audit) audit_fix ;;
    *) die "usage: $0 {build|install|restore|status|audit}" ;;
esac
