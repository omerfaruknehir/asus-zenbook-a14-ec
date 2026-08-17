#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Incrementally add QPPX + selectable ACPI/initcall checkpoints to the existing
# 7.1.5-a14-acpi-full0 build. Only the experimental kernel image is replaced.
set -euo pipefail

ACTION="${1:-build}"
KREL="7.1.5-a14-acpi-full0"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="${A14_FULL_ACPI_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="$WORK/linux-7.1.5"
OUT="$WORK/build"
BACKUP="$WORK/checkpoint-backup"
STAMP="$WORK/checkpoint-build.ready"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
check_tree(){
    [[ -f "$SRC/Makefile" && -f "$OUT/.config" ]] || die "existing full-ACPI build tree not found under $WORK"
    [[ -f "$SRC/include/linux/a14_full_acpi.h" ]] || die "source tree is not the transformed A14 full-ACPI tree"
}

build_checkpoint(){
    [[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as your normal user, not root"
    case "$(uname -m)" in aarch64|arm64) ;; *) die "AArch64 host required";; esac
    for c in python3 make gcc sha256sum; do need "$c"; done
    check_tree

    # Invalidate any previous successful-build stamp before touching the tree.
    # Therefore a failed transform/compile can never be followed by an install
    # of an older Image merely because that file still exists in OUT.
    rm -f "$STAMP"

    # All transforms are idempotent; keep the previously validated QPPX fix in
    # the same diagnostic image while extending checkpoints later into boot.
    python3 "$ROOT/scripts/apply-a14-full-acpi-qppx.py" "$SRC"
    python3 "$ROOT/scripts/apply-a14-full-acpi-checkpoints.py" "$SRC"
    python3 "$ROOT/scripts/apply-a14-full-acpi-late-checkpoints.py" "$SRC"
    python3 "$ROOT/scripts/apply-a14-full-acpi-device-bisect.py" "$SRC"
    python3 "$ROOT/scripts/apply-a14-full-acpi-smmu-checkpoints.py" "$SRC"

    "$SRC/scripts/config" --file "$OUT/.config" --enable QCOM_WOA_QPPX_COMPAT
    export LOCALVERSION=
    make -C "$SRC" O="$OUT" olddefconfig
    grep -q '^CONFIG_QCOM_WOA_QPPX_COMPAT=y$' "$OUT/.config" || die "QPPX provider is not built-in"
    [[ "$(make -s -C "$SRC" O="$OUT" kernelrelease)" == "$KREL" ]] || die "kernelrelease changed unexpectedly"

    make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" Image
    [[ -s "$OUT/arch/arm64/boot/Image" ]] || die "rebuilt Image missing"
    [[ -s "$OUT/vmlinux" ]] || die "rebuilt vmlinux missing"
    grep -q 'smmu-driver-registered' "$SRC/drivers/iommu/arm/arm-smmu/arm-smmu.c" || die "SMMU checkpoint source patch missing after build"
    grep -q 'smmu-probe%d-%s' "$SRC/drivers/iommu/arm/arm-smmu/arm-smmu.c" || die "per-probe SMMU checkpoints missing after build"

    image_sha="$(sha256sum "$OUT/arch/arm64/boot/Image" | awk '{print $1}')"
    {
        printf 'kernelrelease=%s\n' "$KREL"
        printf 'image_sha256=%s\n' "$image_sha"
        printf 'smmu_checkpoints=yes\n'
    } > "$STAMP"

    say "A14_FULL_ACPI_CHECKPOINT_BUILD=COMPLETE"
    say "kernelrelease=$KREL"
    say "late_checkpoints=yes"
    say "device_initcall_bisect=yes"
    say "smmu_checkpoints=yes"
    say "image=$OUT/arch/arm64/boot/Image"
    say "image_sha256=$image_sha"
    say "build_stamp=$STAMP"
}

install_checkpoint(){
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "install requires sudo/root"
    [[ "$(uname -r)" != "$KREL" ]] || die "boot the normal kernel before replacing $KREL"
    for c in install update-grub sha256sum awk; do need "$c"; done
    check_tree
    [[ -s "$OUT/arch/arm64/boot/Image" ]] || die "rebuilt Image missing"
    [[ -r "$STAMP" ]] || die "no successful checkpoint build stamp; run build successfully before install"

    stamp_krel="$(awk -F= '$1 == "kernelrelease" {print $2}' "$STAMP")"
    expected_sha="$(awk -F= '$1 == "image_sha256" {print $2}' "$STAMP")"
    actual_sha="$(sha256sum "$OUT/arch/arm64/boot/Image" | awk '{print $1}')"
    [[ "$stamp_krel" == "$KREL" ]] || die "build stamp kernelrelease mismatch: ${stamp_krel:-missing}"
    [[ -n "$expected_sha" && "$expected_sha" == "$actual_sha" ]] || die "build image does not match successful-build stamp; rebuild before install"

    grep -q 'A14 ACPI CHECKPOINT REACHED' "$SRC/drivers/acpi/bus.c" || die "checkpoint source patch missing"
    grep -q 'initcall-device-after' "$SRC/init/main.c" || die "late checkpoint source patch missing"
    grep -q 'a14_device_halt_after' "$SRC/init/main.c" || die "device bisect source patch missing"
    grep -q 'smmu-driver-registered' "$SRC/drivers/iommu/arm/arm-smmu/arm-smmu.c" || die "SMMU checkpoint source patch missing"
    grep -q 'smmu-probe%d-%s' "$SRC/drivers/iommu/arm/arm-smmu/arm-smmu.c" || die "per-probe SMMU checkpoint source patch missing"
    [[ -f "/boot/vmlinuz-$KREL" ]] || die "installed experimental kernel missing"

    mkdir -p "$BACKUP"
    if [[ ! -f "$BACKUP/vmlinuz-$KREL.pre-checkpoints" ]]; then
        cp -a "/boot/vmlinuz-$KREL" "$BACKUP/vmlinuz-$KREL.pre-checkpoints"
        sha256sum "$BACKUP/vmlinuz-$KREL.pre-checkpoints" > "$BACKUP/vmlinuz-$KREL.pre-checkpoints.sha256"
    fi

    command install -m0644 "$OUT/arch/arm64/boot/Image" "/boot/vmlinuz-$KREL"
    command install -m0644 "$OUT/.config" "/boot/config-$KREL"
    [[ ! -s "$OUT/System.map" ]] || command install -m0644 "$OUT/System.map" "/boot/System.map-$KREL"
    sync "/boot/vmlinuz-$KREL"
    update-grub

    say "A14_FULL_ACPI_CHECKPOINT_INSTALL=COMPLETE"
    say "installed=/boot/vmlinuz-$KREL"
    say "installed_sha256=$(sha256sum "/boot/vmlinuz-$KREL" | awk '{print $1}')"
    say "validated_build_stamp=$STAMP"
    say "backup=$BACKUP/vmlinuz-$KREL.pre-checkpoints"
    say "normal_kernel_untouched=7.1.5-070105-generic"
    say "initramfs_rebuilt=no"
}

rollback_checkpoint(){
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "rollback requires sudo/root"
    [[ "$(uname -r)" != "$KREL" ]] || die "boot the normal kernel before rollback"
    need install; need update-grub
    backup="$BACKUP/vmlinuz-$KREL.pre-checkpoints"
    [[ -s "$backup" ]] || die "checkpoint backup missing: $backup"
    command install -m0644 "$backup" "/boot/vmlinuz-$KREL"
    sync "/boot/vmlinuz-$KREL"
    update-grub
    say "A14_FULL_ACPI_CHECKPOINT_ROLLBACK=COMPLETE"
    say "restored=$backup"
}

case "$ACTION" in
    build) build_checkpoint ;;
    install) install_checkpoint ;;
    rollback) rollback_checkpoint ;;
    *) die "usage: $0 {build|install|rollback}" ;;
esac
