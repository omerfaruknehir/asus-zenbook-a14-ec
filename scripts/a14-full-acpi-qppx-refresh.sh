#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Incrementally add the QPPX ACPI dependency provider to an existing
# 7.1.5-a14-acpi-full0 build. This does not reinstall modules and does not
# create any GRUB entry.
set -euo pipefail

ACTION="${1:-build}"
KREL="7.1.5-a14-acpi-full0"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="${A14_FULL_ACPI_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="$WORK/linux-7.1.5"
OUT="$WORK/build"
BACKUP="$WORK/qppx-backup"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
check_tree(){
    [[ -f "$SRC/Makefile" && -f "$OUT/.config" ]] || die "existing full-ACPI build tree not found under $WORK"
    [[ -f "$SRC/include/linux/a14_full_acpi.h" ]] || die "source tree is not the previously transformed A14 full-ACPI tree"
}

build_qppx(){
    [[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as your normal user, not root"
    case "$(uname -m)" in aarch64|arm64) ;; *) die "AArch64 host required";; esac
    for c in python3 make gcc; do need "$c"; done
    check_tree

    python3 "$ROOT/scripts/apply-a14-full-acpi-qppx.py" "$SRC"
    "$SRC/scripts/config" --file "$OUT/.config" --enable QCOM_WOA_QPPX_COMPAT
    export LOCALVERSION=
    make -C "$SRC" O="$OUT" olddefconfig
    grep -q '^CONFIG_QCOM_WOA_QPPX_COMPAT=y$' "$OUT/.config" || die "CONFIG_QCOM_WOA_QPPX_COMPAT is not built-in"
    [[ "$(make -s -C "$SRC" O="$OUT" kernelrelease)" == "$KREL" ]] || die "kernelrelease changed unexpectedly"

    # QPPX is built-in; relinking Image is sufficient. Kbuild will rebuild only
    # objects affected by the new Kconfig/Makefile/source change.
    make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" Image
    [[ -s "$OUT/arch/arm64/boot/Image" ]] || die "rebuilt Image missing"

    say "A14_FULL_ACPI_QPPX_BUILD=COMPLETE"
    say "kernelrelease=$KREL"
    say "image=$OUT/arch/arm64/boot/Image"
    say "image_sha256=$(sha256sum "$OUT/arch/arm64/boot/Image" | awk '{print $1}')"
}

install_qppx(){
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "install requires sudo/root"
    [[ "$(uname -r)" != "$KREL" ]] || die "boot a non-experimental kernel before replacing $KREL"
    need install; need update-grub; need sha256sum
    check_tree
    grep -q '^CONFIG_QCOM_WOA_QPPX_COMPAT=y$' "$OUT/.config" || die "QPPX build is not ready"
    [[ -s "$OUT/arch/arm64/boot/Image" ]] || die "rebuilt Image missing"
    [[ -f "/boot/vmlinuz-$KREL" ]] || die "installed experimental kernel missing"

    mkdir -p "$BACKUP"
    if [[ ! -f "$BACKUP/vmlinuz-$KREL.pre-qppx" ]]; then
        cp -a "/boot/vmlinuz-$KREL" "$BACKUP/vmlinuz-$KREL.pre-qppx"
        sha256sum "$BACKUP/vmlinuz-$KREL.pre-qppx" > "$BACKUP/vmlinuz-$KREL.pre-qppx.sha256"
    fi

    command install -m0644 "$OUT/arch/arm64/boot/Image" "/boot/vmlinuz-$KREL"
    command install -m0644 "$OUT/.config" "/boot/config-$KREL"
    [[ ! -s "$OUT/System.map" ]] || command install -m0644 "$OUT/System.map" "/boot/System.map-$KREL"
    sync "/boot/vmlinuz-$KREL"
    update-grub

    say "A14_FULL_ACPI_QPPX_INSTALL=COMPLETE"
    say "installed=/boot/vmlinuz-$KREL"
    say "installed_sha256=$(sha256sum "/boot/vmlinuz-$KREL" | awk '{print $1}')"
    say "backup=$BACKUP/vmlinuz-$KREL.pre-qppx"
    say "grub_custom_entries_created=0"
    say "initramfs_rebuilt=no (QPPX is built-in; existing initramfs retained)"
}

rollback_qppx(){
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "rollback requires sudo/root"
    [[ "$(uname -r)" != "$KREL" ]] || die "boot a non-experimental kernel before restoring $KREL"
    need install; need update-grub; need sha256sum
    old="$BACKUP/vmlinuz-$KREL.pre-qppx"
    [[ -s "$old" ]] || die "pre-QPPX backup missing: $old"
    if [[ -f "$BACKUP/vmlinuz-$KREL.pre-qppx.sha256" ]]; then
        (cd "$BACKUP" && sha256sum -c "vmlinuz-$KREL.pre-qppx.sha256") || die "pre-QPPX backup checksum failed"
    fi
    command install -m0644 "$old" "/boot/vmlinuz-$KREL"
    sync "/boot/vmlinuz-$KREL"
    update-grub
    say "A14_FULL_ACPI_QPPX_ROLLBACK=COMPLETE"
    say "restored=/boot/vmlinuz-$KREL"
    say "restored_sha256=$(sha256sum "/boot/vmlinuz-$KREL" | awk '{print $1}')"
}

case "$ACTION" in
    build) build_qppx ;;
    install) install_qppx ;;
    rollback) rollback_qppx ;;
    *) die "usage: $0 {build|install|rollback}" ;;
esac
