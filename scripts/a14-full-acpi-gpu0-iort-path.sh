#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Narrow QCOM0C36 IORT Named Component pathname fallback for A14 full ACPI.
# Image-only: no module rebuild/install, no GPU MMIO/power, no GRUB/initramfs.
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
TRANSFORM="$ROOT/scripts/apply-a14-full-acpi-gpu0-iort-path.py"
STAMP="$WORK/gpu0-iort-path.ready"
KERNEL="/boot/vmlinuz-$KREL"
CONFIG="/boot/config-$KREL"
SYSTEM_MAP="/boot/System.map-$KREL"
BACKUP_KERNEL="/boot/vmlinuz-$KREL.pre-gpu0-iort-path-v1"
BACKUP_CONFIG="/boot/config-$KREL.pre-gpu0-iort-path-v1"
BACKUP_MAP="/boot/System.map-$KREL.pre-gpu0-iort-path-v1"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_user(){ [[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as normal user"; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "install/restore requires sudo/root"; }

verify_tree(){
    [[ -f "$SRC/Makefile" && -f "$OUT/.config" && -s "$OUT/vmlinux" ]] || die "A14 build tree missing"
    export LOCALVERSION=
    local actual
    actual="$(make -s -C "$SRC" O="$OUT" kernelrelease)"
    [[ "$actual" == "$KREL" ]] || die "kernelrelease mismatch: $actual"
    grep -q '^CONFIG_ACPI=y$' "$OUT/.config" || die "CONFIG_ACPI=y required"
    grep -q '^CONFIG_ACPI_IORT=y$' "$OUT/.config" || die "CONFIG_ACPI_IORT=y required"
    grep -q '^CONFIG_ARM_SMMU=y$' "$OUT/.config" || die "CONFIG_ARM_SMMU=y required"
    grep -q '^CONFIG_DRM_MSM=m$' "$OUT/.config" || die "expected CONFIG_DRM_MSM=m"
    grep -q '^CONFIG_QCOM_SCM=y$' "$OUT/.config" || die "SCM config missing"
    grep -q '^CONFIG_MODULE_ALLOW_BTF_MISMATCH=y$' "$OUT/.config" || die "BTF compatibility missing"

    # Keep every already-proven prerequisite in place.
    grep -q 'A14_QCOM0C36_PLATFORM_ENUM_V1' "$SRC/drivers/acpi/scan.c" || die "QCOM0C36 platform enumeration missing"
    grep -q 'A14_ACPI_DMA_IORT_IDS_V1' "$SRC/drivers/acpi/scan.c" || die "ordered multi-ID IORT helper missing"
    grep -q 'A14_QCOM0C36_TOPOLOGY_V1' "$SRC/drivers/gpu/drm/msm/msm_drv.c" || die "GPU topology bridge missing"
    grep -q 'A14_GIO0_SAFE_REGISTRATION_V1' "$SRC/drivers/pinctrl/qcom/pinctrl-msm.c" || die "working GIO0 fix missing"
    grep -q 'A14_QCOM_WOA_ACPI_GPIO_XLATE' "$SRC/drivers/gpio/gpiolib-acpi-core.c" || die "working keyboard translator missing"
    grep -q 'A14_QCOM_SCM_ACPI_QCOM04DD' "$SRC/drivers/firmware/qcom/qcom_scm.c" || die "working SCM ACPI fix missing"
}

verify_source(){
    local iort="$SRC/drivers/acpi/arm64/iort.c"
    grep -q 'A14_IORT_NCOMP_NO_TRAILING_V1' "$iort" || die "QCOM0C36 IORT path fallback marker missing"
    grep -q 'ACPI_FULL_PATHNAME_NO_TRAILING' "$iort" || die "normalized ACPICA pathname call missing"
    grep -q 'acpi_dev_hid_uid_match(adev, "QCOM0C36", NULL)' "$iort" || die "QCOM0C36-only fallback guard missing"
    grep -q 'A14IORT: QCOM0C36 normalized path match' "$iort" || die "runtime proof log missing"
}

build_fix(){
    need_user
    for c in python3 make sha256sum grep nproc; do need "$c"; done
    verify_tree
    [[ -f "$TRANSFORM" ]] || die "missing transform: $TRANSFORM"

    say "A14_GPU0_IORT_PATH_BUILD=START"
    say "problem=IORT_Named_Component_path_normalization"
    say "firmware_component=\\_SB.GPU0"
    say "normal_exact_match=preserved"
    say "fallback_scope=QCOM0C36_only"
    say "build=Image_only"
    say "module_rebuild=false"
    say "module_install=false"
    say "gpu_mmio_access=false"
    say "gpu_power_change=false"
    say "initramfs_unchanged=true"
    say "grub_unchanged=true"

    rm -f "$STAMP"
    python3 "$TRANSFORM" "$SRC"
    python3 "$TRANSFORM" "$SRC"
    verify_source

    rm -f "$IORT_OBJ" "$OUT/drivers/acpi/arm64/.iort.o.cmd"
    export LOCALVERSION=
    make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" Image

    [[ -s "$IMAGE" && -s "$IORT_OBJ" && -s "$OUT/vmlinux" ]] || die "rebuilt Image/iort.o/vmlinux missing"
    grep -aFq 'A14IORT: QCOM0C36 normalized path match' "$IORT_OBJ" || die "compiled iort.o lacks fallback proof log"

    # Verify existing compiled prerequisites survived the relink.
    grep -aFq 'A14 ACPI: QCOM0C36 GPU0 using platform enumeration' "$OUT/drivers/acpi/scan.o" || die "compiled GPU0 enumeration missing"
    grep -aFq 'acpi_dma_configure_iort_ids' "$OUT/drivers/acpi/scan.o" || die "compiled ordered-IORT helper missing"
    grep -aFq 'A14GIO0FIX: suppressing registration-time eager direction scan' "$OUT/drivers/pinctrl/qcom/pinctrl-msm.o" || die "compiled GIO0 fix missing"
    grep -aFq 'QCOM WoA GPIO: virtual' "$OUT/drivers/gpio/gpiolib-acpi-core.o" || die "compiled keyboard translator missing"
    grep -aFq 'A14 ACPI: SCM0 QCOM04DD, DT-only resources skipped' "$OUT/drivers/firmware/qcom/qcom_scm.o" || die "compiled SCM fix missing"

    local sha
    sha="$(sha256sum "$IMAGE" | awk '{print $1}')"
    cat >"$STAMP" <<EOF
kernelrelease=$KREL
image_sha256=$sha
iort_path_fallback=QCOM0C36_only
exact_iort_match_preserved=yes
module_rebuild=no
module_install=no
gpu_mmio_access=no
gpu_power_change=no
keyboard_gio0_fix_preserved=yes
scm_acpi_fix_preserved=yes
EOF

    say "A14_GPU0_IORT_PATH_BUILD=COMPLETE"
    say "image_sha256=$sha"
    say "compiled_iort_fallback=VERIFIED"
    say "working_prerequisites=VERIFIED_PRESERVED"
    say "module_rebuild=false"
}

install_fix(){
    need_root
    for c in install sha256sum cmp awk cp; do need "$c"; done
    [[ "$(uname -r)" != "$KREL" ]] || die "boot normal DT kernel before replacing ACPI Image"
    verify_tree
    verify_source
    [[ -r "$STAMP" ]] || die "successful IORT-path build stamp missing"

    local expected actual
    expected="$(awk -F= '$1=="image_sha256"{print $2}' "$STAMP")"
    actual="$(sha256sum "$IMAGE" | awk '{print $1}')"
    [[ -n "$expected" && "$expected" == "$actual" ]] || die "Image changed since verified build"
    [[ -s "$KERNEL" ]] || die "experimental kernel missing: $KERNEL"

    [[ -e "$BACKUP_KERNEL" ]] || cp -a "$KERNEL" "$BACKUP_KERNEL"
    [[ ! -s "$CONFIG" || -e "$BACKUP_CONFIG" ]] || cp -a "$CONFIG" "$BACKUP_CONFIG"
    [[ ! -s "$SYSTEM_MAP" || -e "$BACKUP_MAP" ]] || cp -a "$SYSTEM_MAP" "$BACKUP_MAP"

    install -m0644 "$IMAGE" "$KERNEL"
    install -m0644 "$OUT/.config" "$CONFIG"
    [[ ! -s "$OUT/System.map" ]] || install -m0644 "$OUT/System.map" "$SYSTEM_MAP"
    cmp -s "$IMAGE" "$KERNEL" || die "installed Image mismatch"

    say "A14_GPU0_IORT_PATH_INSTALL=COMPLETE"
    say "installed_image_sha256=$expected"
    say "previous_image=$BACKUP_KERNEL"
    say "modules_unchanged=true"
    say "initramfs_unchanged=true"
    say "grub_unchanged=true"
}

restore_fix(){
    need_root
    [[ "$(uname -r)" != "$KREL" ]] || die "boot normal DT kernel before restore"
    [[ -s "$BACKUP_KERNEL" ]] || die "pre-IORT-path Image backup missing"
    cp -a "$BACKUP_KERNEL" "$KERNEL"
    [[ ! -s "$BACKUP_CONFIG" ]] || cp -a "$BACKUP_CONFIG" "$CONFIG"
    [[ ! -s "$BACKUP_MAP" ]] || cp -a "$BACKUP_MAP" "$SYSTEM_MAP"
    say "A14_GPU0_IORT_PATH_RESTORE=COMPLETE"
    say "modules_unchanged=true"
}

status_fix(){
    say "running_kernel=$(uname -r)"
    say "work=$WORK"
    [[ -r "$STAMP" ]] && { say "--- IORT path stamp ---"; cat "$STAMP"; }
    [[ -s "$BACKUP_KERNEL" ]] && say "pre_iort_path_backup=$BACKUP_KERNEL"
}

case "$ACTION" in
    build) build_fix ;;
    install) install_fix ;;
    restore) restore_fix ;;
    status) status_fix ;;
    *) die "usage: $0 {build|install|restore|status}" ;;
esac
