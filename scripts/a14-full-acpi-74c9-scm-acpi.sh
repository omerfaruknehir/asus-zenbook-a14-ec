#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# UX3407RA full-ACPI SCM prerequisite fix on top of the working 74c9+BTF+GIO0 tree.
#
# Firmware:  \_SB.SCM0 _HID QCOM04DD
# Live failure before this patch:
#   arm-smmu.0.auto: deferred probe pending: arm-smmu: qcom_scm not ready
#   arm-smmu.1.auto: deferred probe pending: arm-smmu: qcom_scm not ready
#
# This helper changes qcom_scm only.  It does not patch SMMU or GPU yet.
# Image-only build/install: modules, initramfs and GRUB remain untouched.
set -euo pipefail

ACTION="${1:-status}"
KREL="7.1.5-a14-acpi-full0"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="${A14_74C9_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="$WORK/linux-7.1.5"
OUT="$WORK/build"
IMAGE="$OUT/arch/arm64/boot/Image"
SCM_OBJ="$OUT/drivers/firmware/qcom/qcom_scm.o"
STAMP="$WORK/74c9-scm-acpi.ready"
TRANSFORM="$ROOT/scripts/apply-a14-full-acpi-scm-acpi.py"
KERNEL="/boot/vmlinuz-$KREL"
CONFIG="/boot/config-$KREL"
SYSTEM_MAP="/boot/System.map-$KREL"
BACKUP_KERNEL="/boot/vmlinuz-$KREL.pre-scm-acpi"
BACKUP_CONFIG="/boot/config-$KREL.pre-scm-acpi"
BACKUP_MAP="/boot/System.map-$KREL.pre-scm-acpi"

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

    grep -q '^CONFIG_ACPI=y$' "$OUT/.config" || die "CONFIG_ACPI=y is required"
    grep -q '^CONFIG_QCOM_SCM=y$' "$OUT/.config" || die "CONFIG_QCOM_SCM must be built-in (=y) for this Image-only fix"
    grep -q '^CONFIG_MODULE_ALLOW_BTF_MISMATCH=y$' "$OUT/.config" || die "BTF mismatch compatibility is not enabled"

    # Never lose the keyboard/GIO0 fix while working on SCM.
    grep -q 'A14_GIO0_SAFE_REGISTRATION_V1' "$SRC/drivers/pinctrl/qcom/pinctrl-msm.c" || die "working GIO0 safe-registration fix missing"
    grep -q 'A14_QCOM_WOA_ACPI_GPIO_XLATE' "$SRC/drivers/gpio/gpiolib-acpi-core.c" || die "working WoA keyboard GPIO translator missing"
    grep -q 'QCOM0C0C' "$SRC/drivers/pinctrl/qcom/pinctrl-x1e80100.c" || die "working GIO0 ACPI binding missing"
}

verify_scm_source(){
    scm="$SRC/drivers/firmware/qcom/qcom_scm.c"
    grep -q 'A14_QCOM_SCM_ACPI_QCOM04DD' "$scm" || die "SCM ACPI marker missing"
    grep -q '"QCOM04DD", 0' "$scm" || die "SCM0 QCOM04DD ACPI match missing"
    grep -q 'MODULE_DEVICE_TABLE(acpi, qcom_scm_acpi_match)' "$scm" || die "SCM ACPI module table missing"
    grep -q 'acpi_match_table = ACPI_PTR(qcom_scm_acpi_match)' "$scm" || die "SCM platform driver ACPI match missing"
    grep -q 'A14 ACPI: SCM0 QCOM04DD, DT-only resources skipped' "$scm" || die "SCM ACPI probe marker missing"
    [[ "$(grep -c 'devm_of_icc_get(&pdev->dev, NULL)' "$scm")" -eq 1 ]] || die "unexpected SCM OF ICC lookup count"
    [[ "$(grep -c 'of_reserved_mem_device_init(scm->dev)' "$scm")" -eq 1 ]] || die "unexpected SCM OF reserved-memory lookup count"
}

build_fix(){
    need_user
    for c in python3 make sha256sum grep; do need "$c"; done
    verify_tree
    [[ -f "$TRANSFORM" ]] || die "missing transform: $TRANSFORM"

    say "A14_74C9_SCM_ACPI_BUILD=START"
    say "prerequisite=working_keyboard_GIO0_safe_fix"
    say "firmware_scm_path=\\_SB.SCM0"
    say "firmware_scm_hid=QCOM04DD"
    say "live_blocker=arm-smmu_qcom_scm_not_ready"
    say "fix=QCOM04DD_ACPI_match_plus_DT_only_resource_guards"
    say "smmu_code_change=false"
    say "gpu_code_change=false"
    say "full_module_rebuild=false"
    say "initramfs_unchanged=true"
    say "grub_unchanged=true"

    rm -f "$STAMP"

    # Two passes deliberately prove the source transform is idempotent.
    python3 "$TRANSFORM" "$SRC"
    python3 "$TRANSFORM" "$SRC"
    verify_scm_source

    # Force recompilation of the only source file changed by this layer.
    rm -f \
      "$OUT/drivers/firmware/qcom/qcom_scm.o" \
      "$OUT/drivers/firmware/qcom/.qcom_scm.o.cmd"

    export LOCALVERSION=
    make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" Image

    [[ -s "$IMAGE" && -s "$OUT/vmlinux" && -s "$SCM_OBJ" ]] || die "rebuilt Image/vmlinux/qcom_scm.o missing"
    grep -aFq 'QCOM04DD' "$SCM_OBJ" || die "compiled qcom_scm.o lacks QCOM04DD"
    grep -aFq 'A14 ACPI: SCM0 QCOM04DD, DT-only resources skipped' "$SCM_OBJ" || die "compiled qcom_scm.o lacks ACPI probe path"

    # Re-verify the already-working keyboard code survived the relink.
    grep -aFq 'A14GIO0FIX: suppressing registration-time eager direction scan' "$OUT/drivers/pinctrl/qcom/pinctrl-msm.o" || die "compiled GIO0 safe-registration object missing"
    grep -aFq 'QCOM WoA GPIO: virtual' "$OUT/drivers/gpio/gpiolib-acpi-core.o" || die "compiled keyboard GPIO translator object missing"

    sha="$(sha256sum "$IMAGE" | awk '{print $1}')"
    cat >"$STAMP" <<EOF
kernelrelease=$KREL
image_sha256=$sha
firmware_scm_hid=QCOM04DD
acpi_match=yes
dt_dload_guard=yes
dt_icc_guard=yes
dt_reserved_mem_guard=yes
smmu_code_change=no
gpu_code_change=no
module_allow_btf_mismatch=yes
keyboard_gio0_fix_preserved=yes
EOF

    say "A14_74C9_SCM_ACPI_BUILD=COMPLETE"
    say "image=$IMAGE"
    say "sha256=$sha"
    say "compiled_scm_acpi=VERIFIED"
    say "keyboard_gio0_fix=VERIFIED_PRESERVED"
    say "full_module_rebuild=false"
}

install_fix(){
    need_root
    for c in install sha256sum cmp; do need "$c"; done
    [[ "$(uname -r)" != "$KREL" ]] || die "boot the normal DT kernel before replacing the running experimental Image"
    verify_tree
    verify_scm_source
    [[ -r "$STAMP" ]] || die "successful SCM ACPI build stamp missing; run build first"

    expected="$(awk -F= '$1=="image_sha256"{print $2}' "$STAMP")"
    actual="$(sha256sum "$IMAGE" | awk '{print $1}')"
    [[ -n "$expected" && "$expected" == "$actual" ]] || die "Image changed since verified SCM build"
    [[ -s "$KERNEL" ]] || die "experimental kernel missing: $KERNEL"

    # Preserve the currently working keyboard-safe Image exactly once.
    [[ -e "$BACKUP_KERNEL" ]] || cp -a "$KERNEL" "$BACKUP_KERNEL"
    [[ ! -s "$CONFIG" || -e "$BACKUP_CONFIG" ]] || cp -a "$CONFIG" "$BACKUP_CONFIG"
    [[ ! -s "$SYSTEM_MAP" || -e "$BACKUP_MAP" ]] || cp -a "$SYSTEM_MAP" "$BACKUP_MAP"

    install -m0644 "$IMAGE" "$KERNEL"
    install -m0644 "$OUT/.config" "$CONFIG"
    [[ ! -s "$OUT/System.map" ]] || install -m0644 "$OUT/System.map" "$SYSTEM_MAP"
    cmp -s "$IMAGE" "$KERNEL" || die "installed Image differs from verified build"

    say "A14_74C9_SCM_ACPI_INSTALL=COMPLETE"
    say "installed_sha256=$expected"
    say "scm_acpi_hid=QCOM04DD"
    say "previous_keyboard_safe_image=$BACKUP_KERNEL"
    say "modules_unchanged=true"
    say "initramfs_unchanged=true"
    say "grub_unchanged=true"
}

restore_previous(){
    need_root
    [[ "$(uname -r)" != "$KREL" ]] || die "boot the normal DT kernel before restoring the experimental Image"
    [[ -s "$BACKUP_KERNEL" ]] || die "pre-SCM keyboard-safe Image backup missing: $BACKUP_KERNEL"

    cp -a "$BACKUP_KERNEL" "$KERNEL"
    [[ ! -s "$BACKUP_CONFIG" ]] || cp -a "$BACKUP_CONFIG" "$CONFIG"
    [[ ! -s "$BACKUP_MAP" ]] || cp -a "$BACKUP_MAP" "$SYSTEM_MAP"

    say "A14_74C9_SCM_ACPI_RESTORE=COMPLETE"
    say "keyboard_safe_image_restored=$KERNEL"
    say "modules_unchanged=true"
    say "initramfs_unchanged=true"
    say "grub_unchanged=true"
}

status(){
    say "running_kernel=$(uname -r)"
    say "work=$WORK"
    [[ -r "$STAMP" ]] && { say "--- SCM ACPI stamp ---"; cat "$STAMP"; }
    [[ -s "$BACKUP_KERNEL" ]] && say "pre_scm_backup=$BACKUP_KERNEL"
}

case "$ACTION" in
    build) build_fix ;;
    install) install_fix ;;
    restore) restore_previous ;;
    status) status ;;
    *) die "usage: $0 {build|install|restore|status}" ;;
esac
