#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Keep the restored 74c9bd5 ACPI patch state and boot command line, but allow
# existing same-release modules whose split BTF was generated against a
# different vmlinux to load without BTF instead of being rejected.
set -euo pipefail

ACTION="${1:-status}"
KREL="7.1.5-a14-acpi-full0"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
WORK="${A14_74C9_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="$WORK/linux-7.1.5"
OUT="$WORK/build"
IMAGE="$OUT/arch/arm64/boot/Image"
STAMP="$WORK/74c9-btf-compat.ready"
KERNEL="/boot/vmlinuz-$KREL"
INITRD="/boot/initrd.img-$KREL"
CONFIG="/boot/config-$KREL"
SYSTEM_MAP="/boot/System.map-$KREL"
BACKUP="/boot/vmlinuz-$KREL.pre-74c9-btf-compat"
GRUB_SNIPPET="/etc/grub.d/41_a14_full_acpi_checkpoint"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_user(){ [[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as normal user, not root"; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "install requires sudo/root"; }

verify_tree(){
    [[ -f "$SRC/Makefile" && -f "$OUT/.config" ]] || die "restored 74c9 build tree missing under $WORK"
    [[ -s "$OUT/vmlinux" ]] || die "restored 74c9 vmlinux missing"
    grep -q 'A14 ACPI: wrapperless GENI SE, TX FIFO depth' "$SRC/drivers/i2c/busses/i2c-qcom-geni.c" || die "74c9 wrapperless GENI marker missing"
    grep -q 'a14_iort_pcie_smmuv3_firmware_owned' "$SRC/drivers/acpi/arm64/iort.c" || die "74c9 PCIe SMMUv3 ownership patch missing"
    grep -q 'a14_acpi_trace_delay_ms' "$SRC/drivers/acpi/bus.c" || die "74c9 trace-delay patch missing"
    grep -q 'smmu-reset-after-scr0-write' "$SRC/drivers/iommu/arm/arm-smmu/arm-smmu.c" || die "74c9 SMMU reset checkpoints missing"
    ! grep -q 'A14_QCOM_WOA_ACPI_GPIO_XLATE' "$SRC/drivers/gpio/gpiolib-acpi-core.c" || die "later WoA GPIO translation contamination detected"
    ! grep -q 'A14_ACPI_SCAN_TRACE_V' "$SRC/drivers/acpi/scan.c" || die "later ACPI scan trace contamination detected"
}

verify_grub_74c9(){
    [[ -f "$GRUB_SNIPPET" ]] || die "74c9 unrestricted GRUB snippet missing: $GRUB_SNIPPET"
    linux_line="$(awk '/^menuentry .*ACPI-ONLY UNRESTRICTED/{seen=1} seen && /^[[:space:]]*linux[[:space:]]/{print; exit}' "$GRUB_SNIPPET")"
    [[ -n "$linux_line" ]] || die "74c9 unrestricted linux line missing"
    for required in 'earlycon=efifb,ram' 'console=tty0' 'loglevel=8' 'ignore_loglevel' 'printk.time=1' 'acpi=force'; do
        grep -Fq "$required" <<<"$linux_line" || die "74c9 GRUB line lacks $required"
    done
    for forbidden in 'keep_bootcon' 'initcall_debug' 'a14_acpi_halt=' 'a14_acpi_reboot_delay_ms=' 'a14_acpi_trace_delay_ms=' 'a14_device_halt_after=' 'initcall_blacklist=' 'ramoops.' 'reserve_mem='; do
        ! grep -Fq "$forbidden" <<<"$linux_line" || die "74c9 GRUB line contains forbidden $forbidden"
    done
    ! grep -qE '^[[:space:]]*devicetree[[:space:]]' "$GRUB_SNIPPET" || die "74c9 entry unexpectedly loads a DTB"
    say "A14_74C9_COMMANDLINE=VERIFIED"
}

build_image(){
    need_user
    for c in make sha256sum; do need "$c"; done
    verify_tree
    C="$SRC/scripts/config"
    [[ -x "$C" ]] || die "scripts/config missing"

    say "A14_74C9_BTF_COMPAT_BUILD=START"
    say "scope=Kconfig-only compatibility change + Image rebuild"
    say "full_module_rebuild=false"
    say "module_tree=unchanged"

    "$C" --file "$OUT/.config" --enable MODULE_ALLOW_BTF_MISMATCH
    export LOCALVERSION=
    make -C "$SRC" O="$OUT" olddefconfig
    grep -q '^CONFIG_DEBUG_INFO_BTF_MODULES=y$' "$OUT/.config" || die "module BTF is not enabled; mismatch diagnosis no longer fits"
    grep -q '^CONFIG_MODULE_ALLOW_BTF_MISMATCH=y$' "$OUT/.config" || die "MODULE_ALLOW_BTF_MISMATCH did not enable"
    [[ "$(make -s -C "$SRC" O="$OUT" kernelrelease)" == "$KREL" ]] || die "kernelrelease mismatch"

    make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" Image
    [[ -s "$IMAGE" && -s "$OUT/vmlinux" ]] || die "rebuilt Image/vmlinux missing"
    grep -q '^CONFIG_MODULE_ALLOW_BTF_MISMATCH=y$' "$OUT/.config" || die "final config lost MODULE_ALLOW_BTF_MISMATCH"

    sha="$(sha256sum "$IMAGE" | awk '{print $1}')"
    cat >"$STAMP" <<EOF
kernelrelease=$KREL
image_sha256=$sha
module_allow_btf_mismatch=yes
full_module_rebuild=no
EOF
    say "A14_74C9_BTF_COMPAT_BUILD=COMPLETE"
    say "kernelrelease=$KREL"
    say "CONFIG_MODULE_ALLOW_BTF_MISMATCH=y"
    say "image=$IMAGE"
    say "sha256=$sha"
    say "full_module_rebuild=false"
}

install_image(){
    need_root
    for c in install depmod update-initramfs sha256sum; do need "$c"; done
    [[ "$(uname -r)" != "$KREL" ]] || die "boot normal DT kernel before replacing $KREL"
    verify_tree
    verify_grub_74c9
    [[ -r "$STAMP" ]] || die "successful BTF-compat build stamp missing"
    grep -q '^CONFIG_MODULE_ALLOW_BTF_MISMATCH=y$' "$OUT/.config" || die "BTF mismatch compatibility is not enabled"
    [[ -d "/lib/modules/$KREL/kernel" ]] || die "existing same-release module tree missing"

    expected_sha="$(awk -F= '$1 == "image_sha256" {print $2}' "$STAMP")"
    actual_sha="$(sha256sum "$IMAGE" | awk '{print $1}')"
    [[ -n "$expected_sha" && "$expected_sha" == "$actual_sha" ]] || die "Image changed since successful build"

    if [[ ! -e "$BACKUP" && -s "$KERNEL" ]]; then
        cp -a "$KERNEL" "$BACKUP"
        say "backup_created=$BACKUP"
    fi

    say "A14_74C9_BTF_COMPAT_INSTALL_STAGE=1/2 kernel-artifacts"
    install -m0644 "$IMAGE" "$KERNEL"
    install -m0644 "$OUT/.config" "$CONFIG"
    [[ ! -s "$OUT/System.map" ]] || install -m0644 "$OUT/System.map" "$SYSTEM_MAP"
    cmp -s "$IMAGE" "$KERNEL" || die "installed Image mismatch"

    say "A14_74C9_BTF_COMPAT_INSTALL_STAGE=2/2 depmod-initramfs"
    depmod -a "$KREL"
    if [[ -s "$INITRD" ]]; then update-initramfs -u -k "$KREL"; else update-initramfs -c -k "$KREL"; fi

    verify_grub_74c9
    installed_sha="$(sha256sum "$KERNEL" | awk '{print $1}')"
    [[ "$installed_sha" == "$expected_sha" ]] || die "installed kernel hash mismatch"
    say "A14_74C9_BTF_COMPAT_INSTALL=COMPLETE"
    say "installed_sha256=$installed_sha"
    say "modules=reused-with-btf-mismatch-allowed"
    say "grub_commandline=unchanged-exact-74c9"
    say "full_module_rebuild=false"
}

status(){
    say "kernel_work=$WORK"
    say "running_kernel=$(uname -r)"
    [[ -f "$OUT/.config" ]] && grep -E '^CONFIG_(DEBUG_INFO_BTF_MODULES|MODULE_ALLOW_BTF_MISMATCH)=' "$OUT/.config" || true
    [[ -r "$STAMP" ]] && { say "--- build stamp ---"; cat "$STAMP"; }
    df -h "$OWNER_HOME" 2>/dev/null || true
    du -sh "$WORK" 2>/dev/null || true
}

case "$ACTION" in
    build) build_image ;;
    install) install_image ;;
    status) status ;;
    *) die "usage: $0 {build|install|status}" ;;
esac
