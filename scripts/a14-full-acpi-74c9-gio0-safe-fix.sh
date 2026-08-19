#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Actual UX3407RA GIO0/keyboard fix candidate on the recovered 74c9+BTF tree:
#   1. firmware-derived WoA GpioInt virtual-pin -> TLMM translation;
#   2. suppress only gpiolib's proven-fatal eager get_direction scan while
#      QCOM0C0C:00 is registered, restoring the callback immediately after.
# No module rebuild, no initramfs change, no GRUB change.
set -euo pipefail

ACTION="${1:-status}"
KREL="7.1.5-a14-acpi-full0"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="${A14_74C9_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="$WORK/linux-7.1.5"
OUT="$WORK/build"
IMAGE="$OUT/arch/arm64/boot/Image"
STAMP="$WORK/74c9-gio0-safe-fix.ready"
XLATE="$ROOT/scripts/apply-a14-full-acpi-woa-gpio-xlate.py"
SAFE="$ROOT/scripts/apply-a14-74c9-gio0-safe-registration.py"
KERNEL="/boot/vmlinuz-$KREL"
CONFIG="/boot/config-$KREL"
SYSTEM_MAP="/boot/System.map-$KREL"
BACKUP_KERNEL="/boot/vmlinuz-$KREL.pre-gio0-safe-fix"
BACKUP_CONFIG="/boot/config-$KREL.pre-gio0-safe-fix"
BACKUP_MAP="/boot/System.map-$KREL.pre-gio0-safe-fix"
GRUB_SNIPPET="/etc/grub.d/41_a14_full_acpi_checkpoint"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_user(){ [[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as normal user, not root"; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "install/restore requires sudo/root"; }

verify_base(){
    [[ -f "$SRC/Makefile" && -f "$OUT/.config" && -s "$OUT/vmlinux" ]] || die "A14 build tree missing"
    grep -q '^CONFIG_MODULE_ALLOW_BTF_MISMATCH=y$' "$OUT/.config" || die "BTF mismatch compatibility is not enabled"
    grep -q 'A14 ACPI: wrapperless GENI SE, TX FIFO depth' "$SRC/drivers/i2c/busses/i2c-qcom-geni.c" || die "74c9 wrapperless GENI marker missing"
    grep -q 'A14_GIO0_PROBE_TRACE_V1' "$SRC/drivers/pinctrl/qcom/pinctrl-msm.c" || die "proven GIO0 V1 source state missing"
    grep -q 'A14_GIO0_PROBE_TRACE_V2' "$SRC/drivers/pinctrl/qcom/pinctrl-msm.c" || die "GPIO44 V2 proof source state missing"
    ! grep -q 'A14_ACPI_SCAN_TRACE_V' "$SRC/drivers/acpi/scan.c" || die "namespace flood trace contamination detected"
}

verify_grub(){
    [[ -f "$GRUB_SNIPPET" ]] || die "74c9 GRUB snippet missing"
    line="$(awk '/^menuentry .*ACPI-ONLY UNRESTRICTED/{seen=1} seen && /^[[:space:]]*linux[[:space:]]/{print; exit}' "$GRUB_SNIPPET")"
    [[ -n "$line" ]] || die "74c9 GRUB linux line missing"
    for x in 'earlycon=efifb,ram' 'console=tty0' 'loglevel=8' 'ignore_loglevel' 'printk.time=1' 'acpi=force'; do
        grep -Fq "$x" <<<"$line" || die "GRUB line lacks $x"
    done
    for x in 'keep_bootcon' 'initcall_debug' 'a14_acpi_halt=' 'a14_device_halt_after='; do
        ! grep -Fq "$x" <<<"$line" || die "persistent GRUB contains diagnostic arg $x"
    done
    ! grep -qE '^[[:space:]]*devicetree[[:space:]]' "$GRUB_SNIPPET" || die "ACPI-only entry unexpectedly loads DTB"
    say "A14_74C9_COMMANDLINE=VERIFIED"
}

verify_fix_source(){
    x1="$SRC/drivers/pinctrl/qcom/pinctrl-x1e80100.c"
    msm="$SRC/drivers/pinctrl/qcom/pinctrl-msm.c"
    acpi_gpio="$SRC/drivers/gpio/gpiolib-acpi-core.c"
    table="$(awk '/x1e80100_pinctrl_acpi_match\[\]/{f=1} f{print} f && /^};/{exit}' "$x1")"
    grep -Fq 'QCOM0C0C' <<<"$table" || die "GIO0 HID missing"
    grep -Fq 'QCOMFFEB' <<<"$table" || die "GIO0 CID missing"
    ! grep -Fq 'QCOM0C0D' <<<"$table" || die "IPC0 still matches TLMM"

    grep -Fq 'A14_GIO0_SAFE_REGISTRATION_V1' "$msm" || die "safe-registration marker missing"
    grep -Fq 'pctrl->chip.get_direction = NULL' "$msm" || die "registration scan suppression missing"
    grep -Fq 'pctrl->chip.get_direction = a14_saved_get_direction' "$msm" || die "runtime callback restore missing"

    grep -Fq 'A14_QCOM_WOA_ACPI_GPIO_XLATE' "$acpi_gpio" || die "WoA GpioInt translator missing"
    grep -Fq 'qcom_woa_pdc_dsm_guid' "$acpi_gpio" || die "PDC DSM mapping source missing"
    grep -Fq '921b0fd4' "$acpi_gpio" || die "audited Qualcomm PDC DSM UUID missing"
    grep -Fq 'pin_table[pin_index], gpioint' "$acpi_gpio" || die "GpioInt translation hook missing"
}

build_fix(){
    need_user
    for c in python3 make sha256sum grep; do need "$c"; done
    verify_base
    [[ -f "$XLATE" ]] || die "missing audited WoA translator: $XLATE"
    [[ -f "$SAFE" ]] || die "missing safe-registration transform: $SAFE"

    say "A14_74C9_GIO0_SAFE_FIX_BUILD=START"
    say "failure_proof=gpio44_ctl_read_phys_0x0f12c000"
    say "fix1=disable_eager_get_direction_only_during_QCOM0C0C_registration"
    say "fix2=firmware_PDC_DSM_virtual_GpioInt_translation"
    say "keyboard_mapping=0x0180->CRS_IRQ_index_6->GSI_0x253->TLMM_67"
    say "native_gpio_blacklist=none"
    say "full_module_rebuild=false"
    say "initramfs_unchanged=true"
    say "grub_unchanged=true"

    # The translator is idempotent and accepts the already-correct GIO0 ID table.
    python3 "$XLATE" "$SRC"
    python3 "$XLATE" "$SRC"
    python3 "$SAFE" "$SRC"
    python3 "$SAFE" "$SRC"
    verify_fix_source

    # Only these built-in sources change in this fix layer.  Remove their
    # objects/command files so no stale object can survive into the Image.
    rm -f \
      "$OUT/drivers/pinctrl/qcom/pinctrl-msm.o" \
      "$OUT/drivers/pinctrl/qcom/.pinctrl-msm.o.cmd" \
      "$OUT/drivers/gpio/gpiolib-acpi-core.o" \
      "$OUT/drivers/gpio/.gpiolib-acpi-core.o.cmd"

    export LOCALVERSION=
    actual_krel="$(make -s -C "$SRC" O="$OUT" kernelrelease)"
    [[ "$actual_krel" == "$KREL" ]] || die "kernelrelease mismatch: $actual_krel"
    make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" Image

    obj_msm="$OUT/drivers/pinctrl/qcom/pinctrl-msm.o"
    obj_acpi="$OUT/drivers/gpio/gpiolib-acpi-core.o"
    [[ -s "$IMAGE" && -s "$OUT/vmlinux" && -s "$obj_msm" && -s "$obj_acpi" ]] || die "rebuilt Image/fix objects missing"
    grep -aFq 'A14GIO0FIX: suppressing registration-time eager direction scan' "$obj_msm" || die "compiled pinctrl object lacks safe-registration fix"
    grep -aFq 'A14GIO0FIX: restored runtime get_direction callback' "$obj_msm" || die "compiled pinctrl object lacks callback restore"
    grep -aFq 'QCOM WoA GPIO: virtual' "$obj_acpi" || die "compiled ACPI GPIO object lacks virtual-pin translator"
    grep -q '^CONFIG_MODULE_ALLOW_BTF_MISMATCH=y$' "$OUT/.config" || die "BTF compatibility was lost"

    sha="$(sha256sum "$IMAGE" | awk '{print $1}')"
    cat >"$STAMP" <<EOF
kernelrelease=$KREL
image_sha256=$sha
failure_proof=gpio44_ctl_read_phys_0x0f12c000
safe_registration=yes
runtime_get_direction_restored=yes
virtual_gpio_xlate=QCOM-PDC-DSM-CIPR
keyboard_virtual_pin=0x0180
keyboard_gsi=0x253
keyboard_native_gpio=67
module_allow_btf_mismatch=yes
EOF

    say "A14_74C9_GIO0_SAFE_FIX_BUILD=COMPLETE"
    say "image=$IMAGE"
    say "sha256=$sha"
    say "compiled_safe_registration=VERIFIED"
    say "compiled_woa_gpio_xlate=VERIFIED"
    say "full_module_rebuild=false"
}

install_fix(){
    need_root
    for c in install sha256sum; do need "$c"; done
    [[ "$(uname -r)" != "$KREL" ]] || die "boot the normal DT kernel before replacing the experimental Image"
    verify_base
    verify_fix_source
    verify_grub
    [[ -r "$STAMP" ]] || die "successful safe-fix build stamp missing"

    expected="$(awk -F= '$1=="image_sha256"{print $2}' "$STAMP")"
    actual="$(sha256sum "$IMAGE" | awk '{print $1}')"
    [[ -n "$expected" && "$expected" == "$actual" ]] || die "Image changed since verified safe-fix build"

    [[ -e "$BACKUP_KERNEL" ]] || cp -a "$KERNEL" "$BACKUP_KERNEL"
    [[ ! -s "$CONFIG" || -e "$BACKUP_CONFIG" ]] || cp -a "$CONFIG" "$BACKUP_CONFIG"
    [[ ! -s "$SYSTEM_MAP" || -e "$BACKUP_MAP" ]] || cp -a "$SYSTEM_MAP" "$BACKUP_MAP"

    install -m0644 "$IMAGE" "$KERNEL"
    install -m0644 "$OUT/.config" "$CONFIG"
    [[ ! -s "$OUT/System.map" ]] || install -m0644 "$OUT/System.map" "$SYSTEM_MAP"
    cmp -s "$IMAGE" "$KERNEL" || die "installed Image mismatch"
    verify_grub

    say "A14_74C9_GIO0_SAFE_FIX_INSTALL=COMPLETE"
    say "installed_sha256=$expected"
    say "safe_registration=true"
    say "keyboard_virtual_gpio_translation=true"
    say "modules_unchanged=true"
    say "initramfs_unchanged=true"
    say "grub_unchanged=true"
}

restore_previous(){
    need_root
    [[ "$(uname -r)" != "$KREL" ]] || die "boot normal DT kernel before restoring"
    [[ -s "$BACKUP_KERNEL" ]] || die "pre-fix Image backup missing: $BACKUP_KERNEL"
    cp -a "$BACKUP_KERNEL" "$KERNEL"
    [[ ! -s "$BACKUP_CONFIG" ]] || cp -a "$BACKUP_CONFIG" "$CONFIG"
    [[ ! -s "$BACKUP_MAP" ]] || cp -a "$BACKUP_MAP" "$SYSTEM_MAP"
    verify_grub
    say "A14_74C9_GIO0_SAFE_FIX_RESTORE=COMPLETE"
    say "previous_image_restored=$KERNEL"
}

status(){
    say "running_kernel=$(uname -r)"
    say "work=$WORK"
    [[ -r "$STAMP" ]] && { say "--- safe-fix stamp ---"; cat "$STAMP"; }
    [[ -s "$BACKUP_KERNEL" ]] && say "pre_fix_backup=$BACKUP_KERNEL"
    df -h "$OWNER_HOME" 2>/dev/null || true
}

case "$ACTION" in
    build) build_fix ;;
    install) install_fix ;;
    restore) restore_previous ;;
    status) status ;;
    *) die "usage: $0 {build|install|restore|status}" ;;
esac
