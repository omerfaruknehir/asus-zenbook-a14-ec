#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Build/install the A14 Named-Component multi-ID IORT init-once fix.
# Image-only: msm/i2c-hid/other modules, initramfs and GRUB remain untouched.
set -euo pipefail

ACTION="${1:-status}"
KREL="7.1.5-a14-acpi-full0"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="${A14_74C9_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="$WORK/linux-7.1.5"
OUT="$WORK/build"
TRANSFORM="$ROOT/scripts/apply-a14-full-acpi-gpu0-iort-multi-id-v1.py"
IMAGE="$OUT/arch/arm64/boot/Image"
IORT_OBJ="$OUT/drivers/acpi/arm64/iort.o"
SCAN_OBJ="$OUT/drivers/acpi/scan.o"
STAMP="$WORK/gpu0-iort-multi-id-v1.ready"
KERNEL="/boot/vmlinuz-$KREL"
CONFIG="/boot/config-$KREL"
SYSTEM_MAP="/boot/System.map-$KREL"
BACKUP_KERNEL="/boot/vmlinuz-$KREL.pre-gpu0-iort-multi-id-v1"
BACKUP_CONFIG="/boot/config-$KREL.pre-gpu0-iort-multi-id-v1"
BACKUP_MAP="/boot/System.map-$KREL.pre-gpu0-iort-multi-id-v1"

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
    grep -q '^CONFIG_I2C_HID_CORE=m$' "$OUT/.config" || die "expected current I2C-HID module configuration"
    grep -q '^CONFIG_MODULE_ALLOW_BTF_MISMATCH=y$' "$OUT/.config" || die "BTF compatibility missing"

    # Require every working/proven prerequisite. Do not regress them.
    grep -q 'A14_GIO0_SAFE_REGISTRATION_V1' "$SRC/drivers/pinctrl/qcom/pinctrl-msm.c" || die "working GIO0 fix missing"
    grep -q 'A14_QCOM_WOA_ACPI_GPIO_XLATE' "$SRC/drivers/gpio/gpiolib-acpi-core.c" || die "working keyboard GPIO translator missing"
    grep -q 'A14_QCOM_SCM_ACPI_QCOM04DD' "$SRC/drivers/firmware/qcom/qcom_scm.c" || die "working SCM ACPI fix missing"
    grep -q 'A14_QCOM0C36_PLATFORM_ENUM_V1' "$SRC/drivers/acpi/scan.c" || die "GPU platform enumeration missing"
    grep -q 'A14_ACPI_DMA_IORT_IDS_V1' "$SRC/drivers/acpi/scan.c" || die "strict ACPI multi-ID helper missing"
    grep -q 'A14_IORT_NCOMP_NO_TRAILING_V1' "$SRC/drivers/acpi/arm64/iort.c" || die "proven IORT pathname fix missing"
    grep -q 'A14_QCOM0C36_TOPOLOGY_V1' "$SRC/drivers/gpu/drm/msm/msm_drv.c" || die "proven GPU topology bridge missing"
    grep -q 'A14_QTEC0001_HID_DESC_RETRY_V1' "$SRC/drivers/hid/i2c-hid/i2c-hid-core.c" || die "QTEC descriptor retry source missing"
}

verify_source(){
    local iort="$SRC/drivers/acpi/arm64/iort.c"
    local hdr="$SRC/include/linux/acpi_iort.h"
    local scan="$SRC/drivers/acpi/scan.c"
    grep -q 'A14_IORT_NCOMP_MULTI_ID_INIT_ONCE_V1' "$iort" || die "IORT multi-ID init-once marker missing"
    grep -q 'int iort_iommu_configure_ids(struct device \*dev, const u32 \*ids' "$iort" || die "IORT multi-ID implementation missing"
    [[ "$(grep -c 'iort_iommu_configure_ids' "$hdr")" -eq 2 ]] || die "IORT header real/stub declaration mismatch"
    grep -q 'ret = iort_iommu_configure_ids(dev, input_ids, num_ids);' "$scan" || die "ACPI helper not routed through multi-ID primitive"
    ! grep -q 'for (i = 0; i < num_ids; i++)' "$scan" || die "old repeated IORT single-ID loop remains"
    ! grep -q 'EXPORT_SYMBOL_GPL(iort_iommu_configure_ids)' "$iort" || die "IORT primitive unexpectedly exported"
}

build_fix(){
    need_user
    for c in python3 make sha256sum grep nproc nm awk; do need "$c"; done
    verify_tree
    [[ -f "$TRANSFORM" ]] || die "missing transform: $TRANSFORM"

    say "A14_GPU0_IORT_MULTI_ID_V1_BUILD=START"
    say "problem=duplicate_managed_software_node_on_second_GPU_IORT_ID"
    say "fix=named_component_scan_once_map_all_ids_init_once"
    say "gpu_iort_inputs=0x03030000,0x03030020"
    say "gmu_iort_input=0x03030060"
    say "all_ids_before_dma_ops=preserved"
    say "build=Image_only"
    say "msm_module_rebuild=false"
    say "i2c_hid_module_rebuild=false"
    say "gpu_mmio_access=false"
    say "gpu_power_change=false"
    say "initramfs_unchanged=true"
    say "grub_unchanged=true"

    rm -f "$STAMP"
    python3 "$TRANSFORM" "$SRC"
    python3 "$TRANSFORM" "$SRC"
    verify_source

    export LOCALVERSION=
    rm -f "$IORT_OBJ" "$OUT/drivers/acpi/arm64/.iort.o.cmd" \
          "$SCAN_OBJ" "$OUT/drivers/acpi/.scan.o.cmd"
    make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" Image

    [[ -s "$IMAGE" && -s "$IORT_OBJ" && -s "$SCAN_OBJ" && -s "$OUT/vmlinux" ]] || die "rebuilt Image/IORT/scan outputs missing"
    nm "$IORT_OBJ" | grep -Eq '[[:space:]]T[[:space:]]+iort_iommu_configure_ids$' || die "compiled IORT multi-ID primitive missing"
    nm -u "$SCAN_OBJ" | grep -Eq '[[:space:]]U[[:space:]]+iort_iommu_configure_ids$' || die "compiled scan.o does not call multi-ID primitive"
    grep -aFq 'A14IORT: QCOM0C36 normalized path match' "$IORT_OBJ" || die "compiled IORT pathname fallback missing"

    # Relink must preserve already-working built-in prerequisites.
    grep -aFq 'A14 ACPI: QCOM0C36 GPU0 using platform enumeration' "$SCAN_OBJ" || die "compiled GPU enumeration missing"
    grep -aFq 'A14GIO0FIX: suppressing registration-time eager direction scan' "$OUT/drivers/pinctrl/qcom/pinctrl-msm.o" || die "compiled GIO0 fix missing"
    grep -aFq 'QCOM WoA GPIO: virtual' "$OUT/drivers/gpio/gpiolib-acpi-core.o" || die "compiled keyboard GPIO translator missing"
    grep -aFq 'A14 ACPI: SCM0 QCOM04DD, DT-only resources skipped' "$OUT/drivers/firmware/qcom/qcom_scm.o" || die "compiled SCM fix missing"

    local sha
    sha="$(sha256sum "$IMAGE" | awk '{print $1}')"
    cat >"$STAMP" <<EOF
kernelrelease=$KREL
image_sha256=$sha
fix=named_component_multi_id_init_once
gpu_iort_inputs=0x03030000,0x03030020
gmu_iort_input=0x03030060
all_ids_before_dma_ops=yes
msm_module_rebuild=no
i2c_hid_module_rebuild=no
gpu_mmio_access=no
gpu_power_change=no
EOF

    say "A14_GPU0_IORT_MULTI_ID_V1_BUILD=COMPLETE"
    say "image_sha256=$sha"
    say "compiled_multi_id_primitive=VERIFIED"
    say "compiled_scan_call=VERIFIED"
    say "working_prerequisites=VERIFIED_PRESERVED"
    say "module_rebuild=false"
}

install_fix(){
    need_root
    for c in install sha256sum cmp awk cp; do need "$c"; done
    [[ "$(uname -r)" != "$KREL" ]] || die "boot normal DT kernel before replacing ACPI Image"
    verify_tree
    verify_source
    [[ -r "$STAMP" ]] || die "successful IORT multi-ID build stamp missing"

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

    say "A14_GPU0_IORT_MULTI_ID_V1_INSTALL=COMPLETE"
    say "installed_image_sha256=$expected"
    say "previous_image=$BACKUP_KERNEL"
    say "msm_module_unchanged=true"
    say "i2c_hid_module_unchanged=true"
    say "other_modules_unchanged=true"
    say "initramfs_unchanged=true"
    say "grub_unchanged=true"
}

restore_fix(){
    need_root
    [[ "$(uname -r)" != "$KREL" ]] || die "boot normal DT kernel before restore"
    [[ -s "$BACKUP_KERNEL" ]] || die "pre-multi-ID Image backup missing"
    cp -a "$BACKUP_KERNEL" "$KERNEL"
    [[ ! -s "$BACKUP_CONFIG" ]] || cp -a "$BACKUP_CONFIG" "$CONFIG"
    [[ ! -s "$BACKUP_MAP" ]] || cp -a "$BACKUP_MAP" "$SYSTEM_MAP"
    say "A14_GPU0_IORT_MULTI_ID_V1_RESTORE=COMPLETE"
    say "modules_unchanged=true"
}

status_fix(){
    say "running_kernel=$(uname -r)"
    say "work=$WORK"
    [[ -r "$STAMP" ]] && { say "--- IORT multi-ID stamp ---"; cat "$STAMP"; }
    [[ -s "$BACKUP_KERNEL" ]] && say "pre_multi_id_backup=$BACKUP_KERNEL"
}

case "$ACTION" in
    build) build_fix ;;
    install) install_fix ;;
    restore) restore_fix ;;
    status) status_fix ;;
    *) die "usage: $0 {build|install|restore|status}" ;;
esac
