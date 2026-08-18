#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Build and install a module set that matches the currently rebuilt
# 7.1.5-a14-acpi-full0 Image/vmlinux, then regenerate only that kernel's initramfs.
#
# Earlier checkpoint/debug refreshes intentionally rebuilt only Image. With
# CONFIG_DEBUG_INFO_BTF_MODULES, keeping old .ko files can make module BTF
# validation fail against the new kernel BTF and can prevent essential modules
# (e.g. HID or NVMe) from loading.
set -euo pipefail

ACTION="${1:-build}"
KREL="7.1.5-a14-acpi-full0"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
WORK="${A14_FULL_ACPI_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="$WORK/linux-7.1.5"
OUT="$WORK/build"
STAGE="$WORK/module-sync-stage"
BACKUP="$WORK/module-sync-backup"
STAMP="$WORK/module-sync-build.ready"

# Match the original full-ACPI build environment exactly. CONFIG_LOCALVERSION
# already contains -a14-acpi-full0 and CONFIG_LOCALVERSION_AUTO is disabled;
# an inherited make LOCALVERSION must not alter the release used for modules.
export LOCALVERSION=

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

check_tree(){
    [[ -f "$SRC/Makefile" && -f "$OUT/.config" ]] || die "existing A14 full-ACPI build tree not found under $WORK"
    [[ -s "$OUT/vmlinux" ]] || die "current rebuilt vmlinux missing: $OUT/vmlinux"
    [[ -s "$OUT/arch/arm64/boot/Image" ]] || die "current rebuilt Image missing: $OUT/arch/arm64/boot/Image"
    actual_krel="$(make -s -C "$SRC" O="$OUT" kernelrelease)"
    [[ "$actual_krel" == "$KREL" ]] || die "kernelrelease changed unexpectedly: expected $KREL, got $actual_krel"
}

config_value(){
    local sym="$1"
    grep -E "^${sym}=" "$OUT/.config" | tail -n1 | cut -d= -f2- || true
}

require_if_module(){
    local sym="$1" pattern="$2" label="$3"
    local val
    val="$(config_value "$sym")"
    if [[ "$val" == "m" ]]; then
        find "$STAGE/lib/modules/$KREL" -type f -name "$pattern" -print -quit | grep -q . || \
            die "$label is configured as module but no staged $pattern was found"
    fi
}

build_modules(){
    [[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as your normal user, not root"
    case "$(uname -m)" in aarch64|arm64) ;; *) die "AArch64 host required";; esac
    for c in make sha256sum find awk; do need "$c"; done
    check_tree

    rm -f "$STAMP"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"

    # Build against the exact vmlinux/Image already installed by the latest
    # full-ACPI debug refresh. Do not modify or reset the source tree.
    make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" modules
    make -C "$SRC" O="$OUT" INSTALL_MOD_PATH="$STAGE" modules_install

    MODROOT="$STAGE/lib/modules/$KREL"
    [[ -d "$MODROOT" ]] || die "modules_install did not create $MODROOT"
    [[ -f "$MODROOT/modules.order" ]] || die "staged modules.order missing"

    require_if_module CONFIG_BLK_DEV_NVME 'nvme.ko*' "NVMe host driver"
    require_if_module CONFIG_NVME_CORE 'nvme-core.ko*' "NVMe core"
    require_if_module CONFIG_HID 'hid.ko*' "HID core"
    require_if_module CONFIG_I2C_HID_CORE 'i2c-hid.ko*' "I2C HID core"
    require_if_module CONFIG_I2C_HID_ACPI 'i2c-hid-acpi.ko*' "I2C HID ACPI"

    image_sha="$(sha256sum "$OUT/arch/arm64/boot/Image" | awk '{print $1}')"
    vmlinux_sha="$(sha256sum "$OUT/vmlinux" | awk '{print $1}')"
    module_count="$(find "$MODROOT" -type f \( -name '*.ko' -o -name '*.ko.gz' -o -name '*.ko.xz' -o -name '*.ko.zst' \) | wc -l)"
    [[ "$module_count" -gt 0 ]] || die "staged module tree is empty"

    {
        printf 'kernelrelease=%s\n' "$KREL"
        printf 'image_sha256=%s\n' "$image_sha"
        printf 'vmlinux_sha256=%s\n' "$vmlinux_sha"
        printf 'module_count=%s\n' "$module_count"
        printf 'stage=%s\n' "$MODROOT"
    } > "$STAMP"

    say "A14_FULL_ACPI_MODULE_SYNC_BUILD=COMPLETE"
    say "kernelrelease=$KREL"
    say "image_sha256=$image_sha"
    say "vmlinux_sha256=$vmlinux_sha"
    say "module_count=$module_count"
    say "staged_modules=$MODROOT"
    say "nvme_config=$(config_value CONFIG_BLK_DEV_NVME)"
    say "nvme_core_config=$(config_value CONFIG_NVME_CORE)"
    say "hid_config=$(config_value CONFIG_HID)"
    say "i2c_hid_core_config=$(config_value CONFIG_I2C_HID_CORE)"
    say "i2c_hid_acpi_config=$(config_value CONFIG_I2C_HID_ACPI)"
    say "normal_kernel_untouched=true"
}

install_modules(){
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "install requires sudo/root"
    [[ "$(uname -r)" != "$KREL" ]] || die "boot the normal kernel before replacing modules for $KREL"
    for c in sha256sum awk depmod update-grub find cp rm mkdir; do need "$c"; done
    check_tree
    [[ -r "$STAMP" ]] || die "no successful module-sync build stamp; run build first"

    MODROOT="$STAGE/lib/modules/$KREL"
    [[ -d "$MODROOT" ]] || die "staged module tree missing: $MODROOT"
    [[ -f "/boot/vmlinuz-$KREL" ]] || die "installed experimental Image missing"

    stamp_krel="$(awk -F= '$1 == "kernelrelease" {print $2}' "$STAMP")"
    expected_image_sha="$(awk -F= '$1 == "image_sha256" {print $2}' "$STAMP")"
    expected_vmlinux_sha="$(awk -F= '$1 == "vmlinux_sha256" {print $2}' "$STAMP")"
    expected_count="$(awk -F= '$1 == "module_count" {print $2}' "$STAMP")"
    installed_image_sha="$(sha256sum "/boot/vmlinuz-$KREL" | awk '{print $1}')"
    current_image_sha="$(sha256sum "$OUT/arch/arm64/boot/Image" | awk '{print $1}')"
    current_vmlinux_sha="$(sha256sum "$OUT/vmlinux" | awk '{print $1}')"

    [[ "$stamp_krel" == "$KREL" ]] || die "module-sync stamp kernelrelease mismatch"
    [[ -n "$expected_image_sha" && "$expected_image_sha" == "$current_image_sha" ]] || die "Image changed since module build; rebuild modules"
    [[ "$expected_image_sha" == "$installed_image_sha" ]] || die "installed experimental Image does not match module build Image"
    [[ -n "$expected_vmlinux_sha" && "$expected_vmlinux_sha" == "$current_vmlinux_sha" ]] || die "vmlinux changed since module build; rebuild modules"
    [[ "$expected_count" =~ ^[0-9]+$ && "$expected_count" -gt 0 ]] || die "invalid module count in build stamp"

    mkdir -p "$BACKUP"
    if [[ -d "/lib/modules/$KREL" && ! -e "$BACKUP/$KREL.pre-sync" ]]; then
        cp -a "/lib/modules/$KREL" "$BACKUP/$KREL.pre-sync"
    fi

    # Replace only the experimental release's module directory. Keep a backup
    # before deletion so stale modules cannot survive and mismatch the new BTF.
    rm -rf "/lib/modules/$KREL"
    mkdir -p "/lib/modules"
    cp -a "$MODROOT" "/lib/modules/$KREL"
    depmod -a "$KREL"

    # Rebuild only the experimental initramfs. Prefer dracut when present,
    # because this machine's current initramfs visibly runs dracut services.
    if command -v dracut >/dev/null 2>&1; then
        dracut --force "/boot/initrd.img-$KREL" "$KREL"
        initramfs_generator=dracut
    elif command -v update-initramfs >/dev/null 2>&1; then
        update-initramfs -u -k "$KREL"
        initramfs_generator=update-initramfs
    else
        die "neither dracut nor update-initramfs is available"
    fi

    [[ -s "/boot/initrd.img-$KREL" ]] || die "rebuilt experimental initramfs missing"
    update-grub

    installed_count="$(find "/lib/modules/$KREL" -type f \( -name '*.ko' -o -name '*.ko.gz' -o -name '*.ko.xz' -o -name '*.ko.zst' \) | wc -l)"
    [[ "$installed_count" -eq "$expected_count" ]] || die "installed module count differs from staged module count"

    say "A14_FULL_ACPI_MODULE_SYNC_INSTALL=COMPLETE"
    say "kernelrelease=$KREL"
    say "matching_image_sha256=$installed_image_sha"
    say "matching_vmlinux_sha256=$current_vmlinux_sha"
    say "installed_module_count=$installed_count"
    say "initramfs_generator=$initramfs_generator"
    say "initramfs=/boot/initrd.img-$KREL"
    say "backup=$BACKUP/$KREL.pre-sync"
    say "normal_kernel_untouched=true"
}

case "$ACTION" in
    build) build_modules ;;
    install) install_modules ;;
    *) die "usage: $0 {build|install}" ;;
esac
