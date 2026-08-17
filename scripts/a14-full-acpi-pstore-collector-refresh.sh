#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Incrementally add the A14 early ramoops collector to the existing experimental
# Linux 7.1.5 build. This touches only the experimental Image.
set -euo pipefail

ACTION="${1:-build}"
KREL="7.1.5-a14-acpi-full0"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="${A14_FULL_ACPI_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="$WORK/linux-7.1.5"
OUT="$WORK/build"
STAMP="$WORK/pstore-collector-build.ready"
BACKUP="$WORK/checkpoint-backup"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
check_tree(){
    [[ -f "$SRC/Makefile" && -f "$OUT/.config" ]] || die "existing full-ACPI build tree not found under $WORK"
    [[ -f "$SRC/include/linux/a14_full_acpi.h" ]] || die "source tree is not the transformed A14 full-ACPI tree"
}

build_collector(){
    [[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as your normal user, not root"
    case "$(uname -m)" in aarch64|arm64) ;; *) die "AArch64 host required";; esac
    for c in python3 make gcc sha256sum; do need "$c"; done
    check_tree
    rm -f "$STAMP"

    python3 "$ROOT/scripts/apply-a14-full-acpi-pstore-collector.py" "$SRC"

    C="$SRC/scripts/config"
    "$C" --file "$OUT/.config" --enable PSTORE
    "$C" --file "$OUT/.config" --enable PSTORE_RAM
    "$C" --file "$OUT/.config" --enable PSTORE_CONSOLE
    "$C" --file "$OUT/.config" --enable SERIAL_EARLYCON

    export LOCALVERSION=
    make -C "$SRC" O="$OUT" olddefconfig
    grep -q '^CONFIG_PSTORE=y$' "$OUT/.config" || die "PSTORE is not built-in"
    grep -q '^CONFIG_PSTORE_RAM=y$' "$OUT/.config" || die "PSTORE_RAM is not built-in"
    grep -q '^CONFIG_PSTORE_CONSOLE=y$' "$OUT/.config" || die "PSTORE_CONSOLE is not built-in"
    grep -q '^CONFIG_EFI_EARLYCON=y$' "$OUT/.config" || die "EFI_EARLYCON is not built-in"
    [[ "$(make -s -C "$SRC" O="$OUT" kernelrelease)" == "$KREL" ]] || die "kernelrelease changed unexpectedly"

    make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" Image
    [[ -s "$OUT/arch/arm64/boot/Image" ]] || die "rebuilt Image missing"
    [[ -s "$OUT/vmlinux" ]] || die "rebuilt vmlinux missing"
    grep -q 'A14 PSTORE EARLY COLLECTOR' "$SRC/fs/pstore/ram.c" || die "early collector source patch missing"
    grep -q 'persistent_ram_old_size(cxt->cprz)' "$SRC/fs/pstore/ram.c" || die "collector does not read previous console"
    grep -q 'ramoops_a14_echo_previous_console(cxt);' "$SRC/fs/pstore/ram.c" || die "collector probe hook missing"

    image_sha="$(sha256sum "$OUT/arch/arm64/boot/Image" | awk '{print $1}')"
    {
        printf 'kernelrelease=%s\n' "$KREL"
        printf 'image_sha256=%s\n' "$image_sha"
        printf 'early_pstore_collector=yes\n'
    } > "$STAMP"

    say "A14_FULL_ACPI_PSTORE_COLLECTOR_BUILD=COMPLETE"
    say "kernelrelease=$KREL"
    say "early_pstore_collector=yes"
    say "collector_phase=postcore-ramoops-probe"
    say "default_collector_delay_ms=12000"
    say "image=$OUT/arch/arm64/boot/Image"
    say "image_sha256=$image_sha"
    say "build_stamp=$STAMP"
}

install_collector(){
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "install requires sudo/root"
    [[ "$(uname -r)" != "$KREL" ]] || die "boot the normal kernel before replacing $KREL"
    for c in install update-grub sha256sum awk; do need "$c"; done
    check_tree
    [[ -r "$STAMP" ]] || die "no successful collector build stamp; run build first"
    [[ -s "$OUT/arch/arm64/boot/Image" ]] || die "rebuilt Image missing"

    stamp_krel="$(awk -F= '$1 == "kernelrelease" {print $2}' "$STAMP")"
    expected_sha="$(awk -F= '$1 == "image_sha256" {print $2}' "$STAMP")"
    actual_sha="$(sha256sum "$OUT/arch/arm64/boot/Image" | awk '{print $1}')"
    [[ "$stamp_krel" == "$KREL" ]] || die "build stamp kernelrelease mismatch"
    [[ -n "$expected_sha" && "$expected_sha" == "$actual_sha" ]] || die "Image does not match successful collector build stamp"
    grep -q '^early_pstore_collector=yes$' "$STAMP" || die "collector build validation missing"
    grep -q 'A14 PSTORE EARLY COLLECTOR' "$SRC/fs/pstore/ram.c" || die "collector source patch missing"

    mkdir -p "$BACKUP"
    if [[ ! -f "$BACKUP/vmlinuz-$KREL.pre-early-pstore-collector" ]]; then
        cp -a "/boot/vmlinuz-$KREL" "$BACKUP/vmlinuz-$KREL.pre-early-pstore-collector"
        sha256sum "$BACKUP/vmlinuz-$KREL.pre-early-pstore-collector" > "$BACKUP/vmlinuz-$KREL.pre-early-pstore-collector.sha256"
    fi

    command install -m0644 "$OUT/arch/arm64/boot/Image" "/boot/vmlinuz-$KREL"
    command install -m0644 "$OUT/.config" "/boot/config-$KREL"
    [[ ! -s "$OUT/System.map" ]] || command install -m0644 "$OUT/System.map" "/boot/System.map-$KREL"
    sync "/boot/vmlinuz-$KREL"
    update-grub

    say "A14_FULL_ACPI_PSTORE_COLLECTOR_INSTALL=COMPLETE"
    say "installed=/boot/vmlinuz-$KREL"
    say "installed_sha256=$(sha256sum "/boot/vmlinuz-$KREL" | awk '{print $1}')"
    say "validated_build_stamp=$STAMP"
    say "normal_kernel_untouched=7.1.5-070105-generic"
    say "initramfs_rebuilt=no"
}

case "$ACTION" in
    build) build_collector ;;
    install) install_collector ;;
    *) die "usage: $0 {build|install}" ;;
esac
