#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# First native GPU bring-up layer for UX3407RA full-ACPI Linux 7.1.5.
#
# This fixes only physical enumeration of firmware GPU0/QCOM0C36. It does not
# bind MSM/Adreno yet and performs no GPU register access. The real ACPI object
# remains the DMA/IORT owner, preserving firmware's \_SB.GPU0 -> GPU SMMU map.
#
# Image-only build/install: modules, initramfs, normal DT kernel and GRUB stay
# untouched.
set -euo pipefail

ACTION="${1:-status}"
KREL="7.1.5-a14-acpi-full0"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="${A14_74C9_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="$WORK/linux-7.1.5"
OUT="$WORK/build"
IMAGE="$OUT/arch/arm64/boot/Image"
SCAN_OBJ="$OUT/drivers/acpi/scan.o"
STAMP="$WORK/gpu0-platform-enum.ready"
TRANSFORM="$ROOT/scripts/apply-a14-full-acpi-gpu0-platform-enum.py"
KERNEL="/boot/vmlinuz-$KREL"
CONFIG="/boot/config-$KREL"
SYSTEM_MAP="/boot/System.map-$KREL"
BACKUP_KERNEL="/boot/vmlinuz-$KREL.pre-gpu0-platform-enum"
BACKUP_CONFIG="/boot/config-$KREL.pre-gpu0-platform-enum"
BACKUP_MAP="/boot/System.map-$KREL.pre-gpu0-platform-enum"

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
    grep -q '^CONFIG_DRM_MSM=y$' "$OUT/.config" || die "CONFIG_DRM_MSM must remain built-in"
    grep -q '^CONFIG_QCOM_SCM=y$' "$OUT/.config" || die "CONFIG_QCOM_SCM=y required"
    grep -q '^CONFIG_MODULE_ALLOW_BTF_MISMATCH=y$' "$OUT/.config" || die "BTF mismatch compatibility missing"

    # Preserve the already proven working layers exactly while changing ACPI
    # enumeration only.
    grep -q 'A14_GIO0_SAFE_REGISTRATION_V1' "$SRC/drivers/pinctrl/qcom/pinctrl-msm.c" || die "working GIO0 safe-registration fix missing"
    grep -q 'A14_QCOM_WOA_ACPI_GPIO_XLATE' "$SRC/drivers/gpio/gpiolib-acpi-core.c" || die "working keyboard GPIO translator missing"
    grep -q 'A14_QCOM_SCM_ACPI_QCOM04DD' "$SRC/drivers/firmware/qcom/qcom_scm.c" || die "working SCM ACPI fix missing"
}

verify_source(){
    local scan="$SRC/drivers/acpi/scan.c"
    grep -q 'A14_QCOM0C36_PLATFORM_ENUM_V1' "$scan" || die "GPU0 platform-enum marker missing"
    grep -q 'A14 ACPI: QCOM0C36 GPU0 using platform enumeration' "$scan" || die "GPU0 platform-enum log marker missing"
    grep -q 'strcmp(acpi_device_hid(device), "QCOM0C36")' "$scan" || die "QCOM0C36 enumeration exception missing"
}

build_fix(){
    need_user
    for c in python3 make sha256sum grep strings; do need "$c"; done
    verify_tree
    [[ -f "$TRANSFORM" ]] || die "missing transform: $TRANSFORM"

    say "A14_GPU0_PLATFORM_ENUM_BUILD=START"
    say "firmware_path=\\_SB.GPU0"
    say "firmware_hid=QCOM0C36"
    say "live_state=ACPI_object_without_physical_node"
    say "live_modalias=LNXVIDEO"
    say "fix=route_QCOM0C36_through_normal_ACPI_platform_enumeration"
    say "iort_identity=preserved"
    say "msm_adreno_binding_change=false"
    say "gpu_mmio_access=false"
    say "gpu_power_change=false"
    say "full_module_rebuild=false"
    say "initramfs_unchanged=true"
    say "grub_unchanged=true"

    rm -f "$STAMP"
    python3 "$TRANSFORM" "$SRC"
    python3 "$TRANSFORM" "$SRC"
    verify_source

    # Only scan.c changes in this layer; force exactly that object stale and
    # let kbuild relink the built-in Image dependency graph.
    rm -f "$SCAN_OBJ" "$OUT/drivers/acpi/.scan.o.cmd"

    export LOCALVERSION=
    make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" Image

    [[ -s "$IMAGE" && -s "$SCAN_OBJ" && -s "$OUT/vmlinux" ]] || die "rebuilt Image/scan.o/vmlinux missing"
    grep -aFq 'A14 ACPI: QCOM0C36 GPU0 using platform enumeration' "$SCAN_OBJ" || die "compiled scan.o lacks QCOM0C36 platform path"

    # Re-check existing compiled objects are still the working variants.
    grep -aFq 'A14GIO0FIX: suppressing registration-time eager direction scan' "$OUT/drivers/pinctrl/qcom/pinctrl-msm.o" || die "compiled GIO0 fix missing"
    grep -aFq 'QCOM WoA GPIO: virtual' "$OUT/drivers/gpio/gpiolib-acpi-core.o" || die "compiled keyboard translator missing"
    grep -aFq 'A14 ACPI: SCM0 QCOM04DD, DT-only resources skipped' "$OUT/drivers/firmware/qcom/qcom_scm.o" || die "compiled SCM ACPI fix missing"

    sha="$(sha256sum "$IMAGE" | awk '{print $1}')"
    cat >"$STAMP" <<EOF
kernelrelease=$KREL
image_sha256=$sha
firmware_gpu_hid=QCOM0C36
platform_enumeration=yes
iort_identity_preserved=yes
msm_adreno_binding_change=no
gpu_mmio_access=no
gpu_power_change=no
keyboard_gio0_fix_preserved=yes
scm_acpi_fix_preserved=yes
EOF

    say "A14_GPU0_PLATFORM_ENUM_BUILD=COMPLETE"
    say "image=$IMAGE"
    say "sha256=$sha"
    say "compiled_gpu0_platform_enum=VERIFIED"
    say "keyboard_gio0_fix=VERIFIED_PRESERVED"
    say "scm_acpi_fix=VERIFIED_PRESERVED"
    say "full_module_rebuild=false"
}

install_fix(){
    need_root
    for c in install sha256sum cmp awk cp; do need "$c"; done
    [[ "$(uname -r)" != "$KREL" ]] || die "boot the normal DT kernel before replacing the running experimental Image"
    verify_tree
    verify_source
    [[ -r "$STAMP" ]] || die "successful GPU0 platform-enum build stamp missing; run build first"

    expected="$(awk -F= '$1=="image_sha256"{print $2}' "$STAMP")"
    actual="$(sha256sum "$IMAGE" | awk '{print $1}')"
    [[ -n "$expected" && "$expected" == "$actual" ]] || die "Image changed since verified GPU0 build"
    [[ -s "$KERNEL" ]] || die "experimental kernel missing: $KERNEL"

    [[ -e "$BACKUP_KERNEL" ]] || cp -a "$KERNEL" "$BACKUP_KERNEL"
    [[ ! -s "$CONFIG" || -e "$BACKUP_CONFIG" ]] || cp -a "$CONFIG" "$BACKUP_CONFIG"
    [[ ! -s "$SYSTEM_MAP" || -e "$BACKUP_MAP" ]] || cp -a "$SYSTEM_MAP" "$BACKUP_MAP"

    install -m0644 "$IMAGE" "$KERNEL"
    install -m0644 "$OUT/.config" "$CONFIG"
    [[ ! -s "$OUT/System.map" ]] || install -m0644 "$OUT/System.map" "$SYSTEM_MAP"
    cmp -s "$IMAGE" "$KERNEL" || die "installed Image differs from verified build"

    say "A14_GPU0_PLATFORM_ENUM_INSTALL=COMPLETE"
    say "installed_sha256=$expected"
    say "previous_working_image=$BACKUP_KERNEL"
    say "modules_unchanged=true"
    say "initramfs_unchanged=true"
    say "grub_unchanged=true"
}

restore_previous(){
    need_root
    [[ "$(uname -r)" != "$KREL" ]] || die "boot normal DT kernel before restoring experimental Image"
    [[ -s "$BACKUP_KERNEL" ]] || die "pre-GPU0 Image backup missing: $BACKUP_KERNEL"
    cp -a "$BACKUP_KERNEL" "$KERNEL"
    [[ ! -s "$BACKUP_CONFIG" ]] || cp -a "$BACKUP_CONFIG" "$CONFIG"
    [[ ! -s "$BACKUP_MAP" ]] || cp -a "$BACKUP_MAP" "$SYSTEM_MAP"
    say "A14_GPU0_PLATFORM_ENUM_RESTORE=COMPLETE"
    say "modules_unchanged=true"
    say "initramfs_unchanged=true"
    say "grub_unchanged=true"
}

status_fix(){
    say "running_kernel=$(uname -r)"
    say "work=$WORK"
    [[ -r "$STAMP" ]] && { say "--- GPU0 platform-enum stamp ---"; cat "$STAMP"; }
    [[ -s "$BACKUP_KERNEL" ]] && say "pre_gpu0_backup=$BACKUP_KERNEL"
}

case "$ACTION" in
    build) build_fix ;;
    install) install_fix ;;
    restore) restore_previous ;;
    status) status_fix ;;
    *) die "usage: $0 {build|install|restore|status}" ;;
esac
