#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# No-MMIO QCOM0C36 GPU/GMU topology staging layer for Linux 7.1.5.
#
# Builds only:
#   - Image (IORT configure-id GPL export)
#   - drivers/gpu/drm/msm/msm.ko (ACPI topology bridge)
#
# Does NOT bind Adreno/GPUCC, touch GPU registers, rebuild unrelated modules,
# rebuild initramfs, or modify GRUB.
set -euo pipefail

ACTION="${1:-status}"
KREL="7.1.5-a14-acpi-full0"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="${A14_74C9_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="$WORK/linux-7.1.5"
OUT="$WORK/build"
IMAGE="$OUT/arch/arm64/boot/Image"
IORT_OBJ="$OUT/drivers/acpi/arm64/iort.o"
MSM_OBJ="$OUT/drivers/gpu/drm/msm/msm_drv.o"
MSM_KO="$OUT/drivers/gpu/drm/msm/msm.ko"
TRANSFORM="$ROOT/scripts/apply-a14-full-acpi-gpu0-topology-v2.py"
STAMP="$WORK/gpu0-topology.ready"
KERNEL="/boot/vmlinuz-$KREL"
CONFIG="/boot/config-$KREL"
SYSTEM_MAP="/boot/System.map-$KREL"
BACKUP_KERNEL="/boot/vmlinuz-$KREL.pre-gpu0-topology"
BACKUP_CONFIG="/boot/config-$KREL.pre-gpu0-topology"
BACKUP_MAP="/boot/System.map-$KREL.pre-gpu0-topology"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_user(){ [[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as normal user, not root"; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "install/restore requires sudo/root"; }

verify_tree(){
    [[ -f "$SRC/Makefile" && -f "$OUT/.config" && -s "$OUT/vmlinux" ]] || die "A14 build tree missing under $WORK"
    export LOCALVERSION=
    actual="$(make -s -C "$SRC" O="$OUT" kernelrelease)"
    [[ "$actual" == "$KREL" ]] || die "kernelrelease mismatch: expected $KREL, got $actual"

    grep -q '^CONFIG_ACPI=y$' "$OUT/.config" || die "CONFIG_ACPI=y required"
    grep -q '^CONFIG_ACPI_IORT=y$' "$OUT/.config" || die "CONFIG_ACPI_IORT=y required"
    grep -q '^CONFIG_ARM_SMMU=y$' "$OUT/.config" || die "CONFIG_ARM_SMMU=y required"
    grep -q '^CONFIG_DRM_MSM=m$' "$OUT/.config" || die "this targeted helper expects the proven CONFIG_DRM_MSM=m state"
    grep -q '^CONFIG_QCOM_SCM=y$' "$OUT/.config" || die "working SCM must remain built-in"
    grep -q '^CONFIG_MODULE_ALLOW_BTF_MISMATCH=y$' "$OUT/.config" || die "BTF mismatch compatibility missing"

    # Proven working prerequisites must remain present.
    grep -q 'A14_QCOM0C36_PLATFORM_ENUM_V1' "$SRC/drivers/acpi/scan.c" || die "GPU0 platform enumeration prerequisite missing"
    grep -q 'A14_GIO0_SAFE_REGISTRATION_V1' "$SRC/drivers/pinctrl/qcom/pinctrl-msm.c" || die "working GIO0 safe-registration fix missing"
    grep -q 'A14_QCOM_WOA_ACPI_GPIO_XLATE' "$SRC/drivers/gpio/gpiolib-acpi-core.c" || die "working keyboard GPIO translator missing"
    grep -q 'A14_QCOM_SCM_ACPI_QCOM04DD' "$SRC/drivers/firmware/qcom/qcom_scm.c" || die "working SCM ACPI fix missing"
}

verify_source(){
    local iort="$SRC/drivers/acpi/arm64/iort.c"
    local msm="$SRC/drivers/gpu/drm/msm/msm_drv.c"

    grep -q 'EXPORT_SYMBOL_GPL(iort_iommu_configure_id)' "$iort" || die "IORT explicit-ID export missing"
    grep -q 'A14_QCOM0C36_TOPOLOGY_V1' "$msm" || die "QCOM0C36 topology bridge missing"
    grep -q 'a14-adreno-x185-acpi-topology' "$msm" || die "GPU child definition missing"
    grep -q 'a14-gmu-x185-acpi-topology' "$msm" || die "GMU child definition missing"
    grep -q 'a14-gpucc-x1e80100-acpi-topology' "$msm" || die "GPUCC child definition missing"
    grep -q '0x03030000' "$msm" || die "GPU IORT input 0 missing"
    grep -q '0x03030020' "$msm" || die "GPU IORT input 1 missing"
    grep -q '0x03030060' "$msm" || die "GMU IORT input missing"
    grep -q 'gmu_watchdog_irq=firmware-unexposed' "$msm" || die "missing GMU IRQ limitation marker"
    grep -q 'no_mmio=true' "$msm" || die "no-MMIO safety marker missing"
    ! grep -q 'acpi_get_dma_attr(adev)' "$msm" || die "unexported acpi_get_dma_attr bridge call remains"
    [[ "$(grep -c 'adev->flags.coherent_dma ? DEV_DMA_COHERENT' "$msm")" -eq 2 ]] || die "module-safe ACPI coherency selection missing"
}

installed_msm_path(){
    local p
    p="$(modinfo -k "$KREL" -n msm 2>/dev/null || true)"
    [[ -n "$p" && "$p" != "builtin" ]] || return 1
    readlink -f "$p"
}

build_fix(){
    need_user
    for c in python3 make sha256sum grep strings modinfo nproc; do need "$c"; done
    verify_tree
    [[ -f "$TRANSFORM" ]] || die "missing transform: $TRANSFORM"

    say "A14_GPU0_TOPOLOGY_BUILD=START"
    say "parent=QCOM0C36:00"
    say "gpu_iort_inputs=0x03030000,0x03030020"
    say "gpu_streamids=0,1_firmware_derived"
    say "gmu_iort_input=0x03030060"
    say "gmu_streamid=5_firmware_derived"
    say "gmu_watchdog_irq=firmware_unexposed"
    say "hardware_driver_binding=false"
    say "gpu_mmio_access=false"
    say "gpu_power_change=false"
    say "drm_msm_build=targeted_module_only"
    say "initramfs_unchanged=true"
    say "grub_unchanged=true"

    rm -f "$STAMP"

    # First pass applies; second pass proves V2 idempotence.
    python3 "$TRANSFORM" "$SRC"
    python3 "$TRANSFORM" "$SRC"
    verify_source

    # Built-in IORT export: force only this object stale, then relink Image.
    rm -f "$IORT_OBJ" "$OUT/drivers/acpi/arm64/.iort.o.cmd"
    export LOCALVERSION=
    make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" Image

    [[ -s "$IMAGE" && -s "$IORT_OBJ" ]] || die "rebuilt Image/IORT object missing"
    grep -aFq 'iort_iommu_configure_id' "$IORT_OBJ" || die "compiled IORT object lacks configure-id symbol"

    # Rebuild only MSM DRM module against the just-linked kernel symbols.
    rm -f "$MSM_OBJ" "$OUT/drivers/gpu/drm/msm/.msm_drv.o.cmd" \
          "$OUT/drivers/gpu/drm/msm/msm.o" "$MSM_KO"
    make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" \
         M=drivers/gpu/drm/msm modules

    [[ -s "$MSM_KO" && -s "$MSM_OBJ" ]] || die "targeted msm.ko build missing"
    grep -aFq 'A14GPU-TOPOLOGY: READY' "$MSM_KO" || die "compiled msm.ko lacks topology bridge"
    grep -aFq 'a14-adreno-x185-acpi-topology' "$MSM_KO" || die "compiled msm.ko lacks GPU child"
    grep -aFq 'a14-gmu-x185-acpi-topology' "$MSM_KO" || die "compiled msm.ko lacks GMU child"
    modinfo -F alias "$MSM_KO" | grep -Fq 'QCOM0C36' || die "compiled msm.ko lacks QCOM0C36 ACPI module alias"
    vermagic="$(modinfo -F vermagic "$MSM_KO" | awk '{print $1}')"
    [[ "$vermagic" == "$KREL" ]] || die "msm.ko vermagic mismatch: $vermagic"

    image_sha="$(sha256sum "$IMAGE" | awk '{print $1}')"
    msm_sha="$(sha256sum "$MSM_KO" | awk '{print $1}')"

    cat >"$STAMP" <<EOF
kernelrelease=$KREL
image_sha256=$image_sha
msm_ko_sha256=$msm_sha
qcom0c36_platform_enum_preserved=yes
gpu_iort_inputs=0x03030000,0x03030020
gmu_iort_input=0x03030060
gpu_streamids=0,1
gmu_streamid=5
gmu_watchdog_irq=firmware-unexposed
hardware_driver_binding=no
gpu_mmio_access=no
gpu_power_change=no
EOF

    say "A14_GPU0_TOPOLOGY_BUILD=COMPLETE"
    say "image_sha256=$image_sha"
    say "msm_ko_sha256=$msm_sha"
    say "qcom0c36_alias=VERIFIED"
    say "gpu_iort_split=VERIFIED_SOURCE"
    say "no_mmio_layer=VERIFIED"
    say "targeted_module=msm.ko"
    say "full_module_rebuild=false"
}

pack_module_like_target(){
    local target="$1" src="$2" out="$3"
    case "$target" in
        *.ko)
            cp -f "$src" "$out"
            ;;
        *.ko.zst)
            need zstd
            zstd -q -f -19 "$src" -o "$out"
            ;;
        *.ko.xz)
            need xz
            xz -c -f "$src" >"$out"
            ;;
        *.ko.gz)
            need gzip
            gzip -c -f "$src" >"$out"
            ;;
        *)
            die "unsupported installed msm module compression: $target"
            ;;
    esac
}

install_fix(){
    need_root
    for c in install sha256sum cmp awk cp modinfo depmod readlink; do need "$c"; done
    [[ "$(uname -r)" != "$KREL" ]] || die "boot the normal DT kernel before replacing the running ACPI Image/module"
    verify_tree
    verify_source
    [[ -r "$STAMP" ]] || die "successful GPU topology build stamp missing; run build first"

    expected_image="$(awk -F= '$1=="image_sha256"{print $2}' "$STAMP")"
    expected_msm="$(awk -F= '$1=="msm_ko_sha256"{print $2}' "$STAMP")"
    [[ "$(sha256sum "$IMAGE" | awk '{print $1}')" == "$expected_image" ]] || die "Image changed since verified build"
    [[ "$(sha256sum "$MSM_KO" | awk '{print $1}')" == "$expected_msm" ]] || die "msm.ko changed since verified build"

    msm_target="$(installed_msm_path)" || die "cannot locate installed msm module for $KREL"
    case "$msm_target" in
        /lib/modules/$KREL/*) ;;
        *) die "refusing unexpected msm module path: $msm_target" ;;
    esac
    [[ -s "$msm_target" ]] || die "installed msm module missing: $msm_target"

    msm_backup="$msm_target.pre-gpu0-topology"
    [[ -e "$BACKUP_KERNEL" ]] || cp -a "$KERNEL" "$BACKUP_KERNEL"
    [[ ! -s "$CONFIG" || -e "$BACKUP_CONFIG" ]] || cp -a "$CONFIG" "$BACKUP_CONFIG"
    [[ ! -s "$SYSTEM_MAP" || -e "$BACKUP_MAP" ]] || cp -a "$SYSTEM_MAP" "$BACKUP_MAP"
    [[ -e "$msm_backup" ]] || cp -a "$msm_target" "$msm_backup"

    install -m0644 "$IMAGE" "$KERNEL"
    install -m0644 "$OUT/.config" "$CONFIG"
    [[ ! -s "$OUT/System.map" ]] || install -m0644 "$OUT/System.map" "$SYSTEM_MAP"
    cmp -s "$IMAGE" "$KERNEL" || die "installed Image differs from verified build"

    packed="$WORK/msm.ko.topology.install$(basename "$msm_target" | sed 's/^msm\.ko//')"
    rm -f "$packed"
    pack_module_like_target "$msm_target" "$MSM_KO" "$packed"
    install -m0644 "$packed" "$msm_target"
    rm -f "$packed"

    depmod -a "$KREL"
    modinfo -k "$KREL" -F alias msm | grep -Fq 'QCOM0C36' || die "installed module alias database lacks QCOM0C36"

    say "A14_GPU0_TOPOLOGY_INSTALL=COMPLETE"
    say "installed_image_sha256=$expected_image"
    say "installed_msm_source_sha256=$expected_msm"
    say "installed_msm_path=$msm_target"
    say "previous_image=$BACKUP_KERNEL"
    say "previous_msm=$msm_backup"
    say "depmod_updated=true"
    say "initramfs_unchanged=true"
    say "grub_unchanged=true"
    say "unrelated_modules_unchanged=true"
}

restore_previous(){
    need_root
    for c in cp depmod modinfo readlink; do need "$c"; done
    [[ "$(uname -r)" != "$KREL" ]] || die "boot normal DT kernel before restoring ACPI Image/module"
    [[ -s "$BACKUP_KERNEL" ]] || die "pre-topology Image backup missing"

    msm_target="$(installed_msm_path)" || die "cannot locate installed msm module for $KREL"
    msm_backup="$msm_target.pre-gpu0-topology"
    [[ -s "$msm_backup" ]] || die "pre-topology msm backup missing: $msm_backup"

    cp -a "$BACKUP_KERNEL" "$KERNEL"
    [[ ! -s "$BACKUP_CONFIG" ]] || cp -a "$BACKUP_CONFIG" "$CONFIG"
    [[ ! -s "$BACKUP_MAP" ]] || cp -a "$BACKUP_MAP" "$SYSTEM_MAP"
    cp -a "$msm_backup" "$msm_target"
    depmod -a "$KREL"

    say "A14_GPU0_TOPOLOGY_RESTORE=COMPLETE"
    say "image_restored=$KERNEL"
    say "msm_restored=$msm_target"
    say "initramfs_unchanged=true"
    say "grub_unchanged=true"
}

status_fix(){
    say "running_kernel=$(uname -r)"
    say "work=$WORK"
    if msm_target="$(installed_msm_path 2>/dev/null)"; then
        say "installed_msm=$msm_target"
        modinfo -k "$KREL" -F alias msm 2>/dev/null | grep -F 'QCOM0C36' || true
    fi
    [[ -r "$STAMP" ]] && { say "--- GPU topology stamp ---"; cat "$STAMP"; }
    [[ -s "$BACKUP_KERNEL" ]] && say "pre_topology_image=$BACKUP_KERNEL"
}

case "$ACTION" in
    build) build_fix ;;
    install) install_fix ;;
    restore) restore_previous ;;
    status) status_fix ;;
    *) die "usage: $0 {build|install|restore|status}" ;;
esac
