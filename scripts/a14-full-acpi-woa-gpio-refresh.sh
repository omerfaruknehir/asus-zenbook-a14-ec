#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Build/install the Qualcomm WoA ACPI virtual-GPIO fix on the existing
# 7.1.5-a14-acpi-full0 tree while keeping Image/modules/initramfs matched.
set -euo pipefail

ACTION="${1:-build}"
KREL="7.1.5-a14-acpi-full0"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="${A14_FULL_ACPI_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="$WORK/linux-7.1.5"
OUT="$WORK/build"
STAGE="$WORK/module-sync-stage"
MODULE_STAMP="$WORK/module-sync-build.ready"
STAMP="$WORK/woa-gpio-build.ready"
BACKUP="$WORK/woa-gpio-backup"
OLD_BAD_BACKUP="$WORK/module-sync-backup/$KREL.pre-sync"
NEW_MODULE_BACKUP="$BACKUP/modules-$KREL.pre-woa-gpio"
IMAGE_BACKUP="$BACKUP/vmlinuz-$KREL.pre-woa-gpio"
INITRD_BACKUP="$BACKUP/initrd.img-$KREL.pre-woa-gpio"

export LOCALVERSION=

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

check_tree(){
    [[ -f "$SRC/Makefile" && -f "$OUT/.config" ]] || die "existing A14 full-ACPI build tree missing under $WORK"
    actual="$(make -s -C "$SRC" O="$OUT" kernelrelease)"
    [[ "$actual" == "$KREL" ]] || die "kernelrelease mismatch: expected $KREL, got $actual"
}

free_gib(){
    df -Pk "$WORK" | awk 'NR==2 { printf "%.1f", $4 / 1024 / 1024 }'
}

build_all(){
    [[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as your normal user, not root"
    case "$(uname -m)" in aarch64|arm64) ;; *) die "AArch64 host required";; esac
    for c in python3 make sha256sum df awk grep; do need "$c"; done
    check_tree

    if [[ -d "$OLD_BAD_BACKUP" ]]; then
        bad_kb="$(du -sk "$OLD_BAD_BACKUP" | awk '{print $1}')"
        bad_gib="$(awk -v k="$bad_kb" 'BEGIN { printf "%.1f", k / 1024 / 1024 }')"
        die "old pre-sync module backup still occupies ${bad_gib} GiB: $OLD_BAD_BACKUP ; it is the pre-fix/BTF-mismatched rollback. Remove it first to make room for one new staged module tree."
    fi

    avail_kb="$(df -Pk "$WORK" | awk 'NR==2 {print $4}')"
    min_kb=$((14 * 1024 * 1024))
    [[ "$avail_kb" -ge "$min_kb" ]] || die "need at least 14 GiB free before the staged module build; currently $(free_gib) GiB"

    rm -f "$STAMP"

    python3 "$ROOT/scripts/apply-a14-full-acpi-woa-gpio-xlate.py" "$SRC"
    # A second pass is intentional: fail the build if the transform is not idempotent.
    python3 "$ROOT/scripts/apply-a14-full-acpi-woa-gpio-xlate.py" "$SRC"

    grep -q 'QCOM0C0C' "$SRC/drivers/pinctrl/qcom/pinctrl-x1e80100.c" || die "GIO0 QCOM0C0C binding missing"
    grep -q 'QCOMFFEB' "$SRC/drivers/pinctrl/qcom/pinctrl-x1e80100.c" || die "GIO0 QCOMFFEB binding missing"
    grep -q 'A14_QCOM_WOA_ACPI_GPIO_XLATE' "$SRC/drivers/gpio/gpiolib-acpi-core.c" || die "WoA GPIO translator missing"
    grep -q 'qcom_woa_pdc_dsm_guid' "$SRC/drivers/gpio/gpiolib-acpi-core.c" || die "PDC DSM mapping helper missing"

    make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" Image
    [[ -s "$OUT/arch/arm64/boot/Image" && -s "$OUT/vmlinux" ]] || die "rebuilt Image/vmlinux missing"

    # Rebuild and stage the complete module set against this exact vmlinux.
    bash "$ROOT/scripts/a14-full-acpi-module-sync.sh" build

    image_sha="$(sha256sum "$OUT/arch/arm64/boot/Image" | awk '{print $1}')"
    vmlinux_sha="$(sha256sum "$OUT/vmlinux" | awk '{print $1}')"
    staged="$STAGE/lib/modules/$KREL"
    [[ -d "$staged" ]] || die "matching staged modules missing"

    module_image_sha="$(awk -F= '$1 == "image_sha256" {print $2}' "$MODULE_STAMP")"
    module_vmlinux_sha="$(awk -F= '$1 == "vmlinux_sha256" {print $2}' "$MODULE_STAMP")"
    [[ "$module_image_sha" == "$image_sha" ]] || die "module stage was built against a different Image"
    [[ "$module_vmlinux_sha" == "$vmlinux_sha" ]] || die "module stage was built against a different vmlinux"

    {
        printf 'kernelrelease=%s\n' "$KREL"
        printf 'image_sha256=%s\n' "$image_sha"
        printf 'vmlinux_sha256=%s\n' "$vmlinux_sha"
        printf 'module_stage=%s\n' "$staged"
    } > "$STAMP"

    say "A14_FULL_ACPI_WOA_GPIO_BUILD=COMPLETE"
    say "kernelrelease=$KREL"
    say "image_sha256=$image_sha"
    say "vmlinux_sha256=$vmlinux_sha"
    say "gio0_hid=QCOM0C0C"
    say "gio0_cid=QCOMFFEB"
    say "virtual_gpio_xlate=QCOM-PDC-DSM-CIPR"
    say "keyboard_expected=0x0180->GSI-0x253->TLMM-67"
    say "touchpad_expected=0x03c0->GSI-0x242->TLMM-3"
    say "hdtl_expected=0x0400->GSI-0x2f7->TLMM-95"
    say "matching_modules_staged=true"
    say "free_after_build_gib=$(free_gib)"
    say "normal_kernel_untouched=true"
}

rollback_install(){
    set +e
    say "A14_WOA_GPIO_INSTALL_ROLLBACK=START"

    if [[ -d "/lib/modules/$KREL" && -d "$NEW_MODULE_BACKUP" ]]; then
        mkdir -p "$STAGE/lib/modules"
        rm -rf "$STAGE/lib/modules/$KREL.failed"
        mv "/lib/modules/$KREL" "$STAGE/lib/modules/$KREL.failed"
        mv "$NEW_MODULE_BACKUP" "/lib/modules/$KREL"
        depmod -a "$KREL" || true
    fi

    [[ ! -s "$IMAGE_BACKUP" ]] || install -m0644 "$IMAGE_BACKUP" "/boot/vmlinuz-$KREL"
    [[ ! -s "$INITRD_BACKUP" ]] || install -m0644 "$INITRD_BACKUP" "/boot/initrd.img-$KREL"
    update-grub || true
    say "A14_WOA_GPIO_INSTALL_ROLLBACK=DONE"
}

install_all(){
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "install requires sudo/root"
    [[ "$(uname -r)" != "$KREL" ]] || die "boot the normal kernel before replacing the experimental kernel"
    for c in install sha256sum awk stat mv depmod update-grub df; do need "$c"; done
    check_tree

    [[ -r "$STAMP" ]] || die "no successful WoA GPIO build stamp; run build first"
    [[ -r "$MODULE_STAMP" ]] || die "matching module build stamp missing"
    staged="$STAGE/lib/modules/$KREL"
    current="/lib/modules/$KREL"
    [[ -d "$staged" ]] || die "staged matching modules missing: $staged"
    [[ -d "$current" ]] || die "current experimental modules missing: $current"
    [[ -s "/boot/vmlinuz-$KREL" && -s "/boot/initrd.img-$KREL" ]] || die "current experimental boot files missing"

    expected_image="$(awk -F= '$1 == "image_sha256" {print $2}' "$STAMP")"
    expected_vmlinux="$(awk -F= '$1 == "vmlinux_sha256" {print $2}' "$STAMP")"
    actual_image="$(sha256sum "$OUT/arch/arm64/boot/Image" | awk '{print $1}')"
    actual_vmlinux="$(sha256sum "$OUT/vmlinux" | awk '{print $1}')"
    [[ "$expected_image" == "$actual_image" ]] || die "Image changed since successful build"
    [[ "$expected_vmlinux" == "$actual_vmlinux" ]] || die "vmlinux changed since successful build"

    module_image="$(awk -F= '$1 == "image_sha256" {print $2}' "$MODULE_STAMP")"
    module_vmlinux="$(awk -F= '$1 == "vmlinux_sha256" {print $2}' "$MODULE_STAMP")"
    [[ "$module_image" == "$actual_image" && "$module_vmlinux" == "$actual_vmlinux" ]] || die "staged modules do not match current Image/vmlinux"

    # The rename-based swap only has its no-copy space advantage when both live
    # modules and staging are on the same filesystem (true for the A14 setup).
    stage_dev="$(stat -c %d "$staged")"
    live_dev="$(stat -c %d /lib/modules)"
    [[ "$stage_dev" == "$live_dev" ]] || die "module staging and /lib/modules are on different filesystems; refusing a space-expensive copy"

    mkdir -p "$BACKUP"
    [[ ! -e "$NEW_MODULE_BACKUP" ]] || die "rollback module backup already exists: $NEW_MODULE_BACKUP"
    [[ ! -e "$IMAGE_BACKUP" && ! -e "$INITRD_BACKUP" ]] || die "WoA GPIO boot backup already exists; remove/rename it only after reviewing"

    cp -a "/boot/vmlinuz-$KREL" "$IMAGE_BACKUP"
    cp -a "/boot/initrd.img-$KREL" "$INITRD_BACKUP"

    # Install the new Image, then swap module trees with metadata-only renames.
    install -m0644 "$OUT/arch/arm64/boot/Image" "/boot/vmlinuz-$KREL"
    [[ ! -s "$OUT/System.map" ]] || install -m0644 "$OUT/System.map" "/boot/System.map-$KREL"
    install -m0644 "$OUT/.config" "/boot/config-$KREL"

    mv "$current" "$NEW_MODULE_BACKUP"
    mv "$staged" "$current"

    # From this point on, automatically restore the previous known-working
    # experimental Image/modules/initramfs if installation cannot complete.
    trap rollback_install ERR

    depmod -a "$KREL"
    if command -v dracut >/dev/null 2>&1; then
        dracut --force "/boot/initrd.img-$KREL" "$KREL"
        initramfs_generator=dracut
    elif command -v update-initramfs >/dev/null 2>&1; then
        update-initramfs -u -k "$KREL"
        initramfs_generator=update-initramfs
    else
        false
    fi

    [[ -s "/boot/initrd.img-$KREL" ]]

    # The staged module tree was renamed into /lib/modules, so only empty stage
    # scaffolding remains. Never leave another 9.6 GiB copy behind.
    rm -rf "$STAGE"

    # Recreate the unrestricted entry in details-first Plymouth mode.
    bash "$ROOT/scripts/a14-full-acpi-unrestricted-entry.sh"

    trap - ERR
    say "A14_FULL_ACPI_WOA_GPIO_INSTALL=COMPLETE"
    say "installed=/boot/vmlinuz-$KREL"
    say "installed_sha256=$(sha256sum "/boot/vmlinuz-$KREL" | awk '{print $1}')"
    say "matching_modules=/lib/modules/$KREL"
    say "initramfs_generator=$initramfs_generator"
    say "module_swap=rename-no-copy"
    say "staging_cleanup=complete"
    say "rollback_modules=$NEW_MODULE_BACKUP"
    say "rollback_image=$IMAGE_BACKUP"
    say "rollback_initrd=$INITRD_BACKUP"
    say "plymouth_default_view=details"
    say "plymouth_escape_toggle=details<->splash"
    say "normal_kernel_untouched=true"
    say "free_after_install_gib=$(free_gib)"
}

case "$ACTION" in
    build) build_all ;;
    install) install_all ;;
    *) die "usage: $0 {build|install}" ;;
esac
