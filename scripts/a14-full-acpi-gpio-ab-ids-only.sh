#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

ACTION="${1:-status}"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
ROOT="${A14_FULL_ACPI_WORKDIR:-${A14_FULL_ACPI_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}}"
SRC="$ROOT/linux-7.1.5"
OUT="$ROOT/build"
BASE_COMMIT="155b42bec9cbb6b8cdc47dd9bd09503a81fbe493"
KREL="7.1.5-a14-acpi-full0"
KERNEL="/boot/vmlinuz-$KREL"
BACKUP="/boot/vmlinuz-$KREL.pre-gpio-ab-ids-only"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PATCHER="$SCRIPT_DIR/apply-a14-full-acpi-gio0-ids-only.py"
PROGRESS="$SCRIPT_DIR/a14-kbuild-progress.py"
JOBS="${A14_BUILD_JOBS:-$(nproc)}"
LOG="$ROOT/a14-build-gpio-ab-ids-only-Image.log"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_user(){ [[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as normal user, not root"; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "install/restore requires sudo/root"; }

verify_tree(){
    [[ -d "$SRC/.git" ]] || die "missing git kernel source tree: $SRC"
    [[ -f "$OUT/.config" ]] || die "missing build tree: $OUT"
    [[ -f "$PATCHER" ]] || die "missing patcher: $PATCHER"
}

prepare_variant(){
    # Remove the V1/V2 ACPI scan tracing completely. The base A14 transform does
    # not modify these upstream files, so restoring exactly v7.1.5 is safe.
    git -C "$SRC" checkout "$BASE_COMMIT" -- \
        drivers/acpi/bus.c \
        drivers/acpi/scan.c \
        drivers/acpi/power.c \
        drivers/gpio/gpiolib-acpi-core.c

    # Keep the real UX3407RA GIO0 IDs in the TLMM driver, but deliberately do
    # NOT restore the WoA virtual-GPIO translation in gpiolib.
    python3 "$PATCHER" "$SRC"
}

verify_source(){
    local pin="$SRC/drivers/pinctrl/qcom/pinctrl-x1e80100.c"
    local gpio="$SRC/drivers/gpio/gpiolib-acpi-core.c"
    local table

    grep -q 'QCOM0C0C' "$pin" || die "QCOM0C0C missing from TLMM source"
    grep -q 'QCOMFFEB' "$pin" || die "QCOMFFEB missing from TLMM source"
    table="$(sed -n '/x1e80100_pinctrl_acpi_match\[\]/,/};/p' "$pin")"
    ! grep -q 'QCOM0C0D' <<<"$table" || die "IPC0/QCOM0C0D still matches TLMM"

    ! grep -q 'A14_QCOM_WOA_ACPI_GPIO_XLATE' "$gpio" || die "WoA virtual GPIO translation still present"
    ! grep -Rqs 'A14TRACE' "$SRC/drivers/acpi/bus.c" "$SRC/drivers/acpi/scan.c" "$SRC/drivers/acpi/power.c" || die "ACPI trace spam still present"

    say "A14_GPIO_AB_SOURCE=VERIFIED"
    say "variant=A_IDS_ONLY"
    say "gio0_ids=QCOM0C0C,QCOMFFEB"
    say "ipc0_qcom0c0d_match=false"
    say "woa_virtual_gpio_translation=false"
    say "acpi_scan_trace=false"
}

verify_image(){
    local image="$OUT/arch/arm64/boot/Image"
    local obj="$OUT/drivers/pinctrl/qcom/pinctrl-x1e80100.o"
    [[ -s "$image" ]] || die "Image missing: $image"
    [[ -s "$obj" ]] || die "TLMM object missing: $obj"

    grep -aFq 'QCOM0C0C' "$obj" || die "built TLMM object lacks QCOM0C0C"
    grep -aFq 'QCOMFFEB' "$obj" || die "built TLMM object lacks QCOMFFEB"
    ! grep -aFq 'QCOM0C0D' "$obj" || die "built TLMM object still contains IPC0 QCOM0C0D match"
    ! grep -aFq 'ACPI: QCOM WoA GPIO: virtual' "$image" || die "built Image still contains WoA virtual GPIO translation"
    ! grep -aFq 'A14TRACE2' "$image" || die "built Image still contains V2 trace"
    ! grep -aFq 'A14TRACE power' "$image" || die "built Image still contains V1 trace"

    say "A14_GPIO_AB_IMAGE=VERIFIED"
    say "built_gio0_ids=QCOM0C0C,QCOMFFEB"
    say "built_ipc0_qcom0c0d_match=false"
    say "built_woa_virtual_gpio_translation=false"
    say "built_acpi_scan_trace=false"
}

build_variant(){
    need_user
    verify_tree
    prepare_variant
    verify_source
    export LOCALVERSION=

    say "A14_GPIO_AB_BUILD=START"
    say "variant=A_IDS_ONLY"
    say "scope=incremental Image only; modules preserved"
    say "jobs=$JOBS"
    say "raw_log=$LOG"

    set +e
    if [[ -t 1 && -f "$PROGRESS" ]]; then
        make -C "$SRC" O="$OUT" -j"$JOBS" Image 2>&1 \
            | tee "$LOG" \
            | python3 "$PROGRESS" --label "GPIO A/B IDs-only Image" --logfile "$LOG" --module-total 0 --module-built 0
        rc=${PIPESTATUS[0]}
    else
        make -C "$SRC" O="$OUT" -j"$JOBS" Image 2>&1 | tee "$LOG"
        rc=${PIPESTATUS[0]}
    fi
    set -e
    if (( rc != 0 )); then
        echo "ERROR: IDs-only Image build failed rc=$rc" >&2
        tail -n 120 "$LOG" >&2 || true
        exit "$rc"
    fi

    verify_image
    say "A14_GPIO_AB_BUILD=COMPLETE"
    say "variant=A_IDS_ONLY"
    say "image=$OUT/arch/arm64/boot/Image"
    say "sha256=$(sha256sum "$OUT/arch/arm64/boot/Image" | awk '{print $1}')"
}

install_variant(){
    need_root
    verify_tree
    verify_source
    verify_image
    [[ -s "$KERNEL" ]] || die "installed experimental kernel missing: $KERNEL"
    [[ "$(uname -r)" != "$KREL" ]] || die "refusing to replace the running experimental kernel"

    if [[ ! -e "$BACKUP" ]]; then
        cp -a "$KERNEL" "$BACKUP"
        say "backup_created=$BACKUP"
    else
        say "backup_preserved=$BACKUP"
    fi

    install -m0644 "$OUT/arch/arm64/boot/Image" "$KERNEL"
    cmp -s "$OUT/arch/arm64/boot/Image" "$KERNEL" || die "installed Image mismatch"
    say "A14_GPIO_AB_INSTALL=COMPLETE"
    say "variant=A_IDS_ONLY"
    say "kernel=$KERNEL"
    say "installed_sha256=$(sha256sum "$KERNEL" | awk '{print $1}')"
    say "modules_unchanged=true"
    say "initramfs_unchanged=true"
    say "normal_DT_kernel_untouched=true"
}

restore_variant(){
    need_root
    [[ -s "$BACKUP" ]] || die "backup missing: $BACKUP"
    [[ "$(uname -r)" != "$KREL" ]] || die "boot normal DT kernel before restore"
    cp -a "$BACKUP" "$KERNEL"
    say "A14_GPIO_AB_RESTORE=COMPLETE"
    say "kernel=$KERNEL"
    say "sha256=$(sha256sum "$KERNEL" | awk '{print $1}')"
}

status(){
    say "variant=A_IDS_ONLY"
    say "source=$SRC"
    say "build=$OUT"
    say "kernel=$KERNEL"
    say "backup=$BACKUP"
    say "backup_exists=$([[ -s "$BACKUP" ]] && echo yes || echo no)"
}

case "$ACTION" in
    build) build_variant;;
    install) install_variant;;
    restore) restore_variant;;
    status) status;;
    *) die "usage: $0 {build|install|restore|status}";;
esac
