#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

ACTION="${1:-status}"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
ROOT="${A14_FULL_ACPI_WORKDIR:-${A14_FULL_ACPI_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}}"
SRC="$ROOT/linux-7.1.5"
OUT="$ROOT/build"
KREL="7.1.5-a14-acpi-full0"
KERNEL="/boot/vmlinuz-$KREL"
BACKUP="/boot/vmlinuz-$KREL.pre-acpi-scan-trace"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PATCHER="$SCRIPT_DIR/apply-a14-full-acpi-scan-trace.py"
PROGRESS="$SCRIPT_DIR/a14-kbuild-progress.py"
JOBS="${A14_BUILD_JOBS:-$(nproc)}"
LOG="$ROOT/a14-build-acpi-scan-trace-Image.log"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_user(){ [[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as normal user, not root"; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "install/restore requires sudo/root"; }

verify_tree(){
    [[ -f "$SRC/Makefile" ]] || die "missing source tree: $SRC"
    [[ -f "$OUT/.config" ]] || die "missing build tree: $OUT"
    [[ -f "$PATCHER" ]] || die "missing trace patcher: $PATCHER"
}

verify_trace_source(){
    grep -q 'A14_ACPI_SCAN_TRACE_V1' "$SRC/drivers/acpi/power.c" || die "trace marker missing from power.c"
    grep -q 'A14TRACE acpi_scan_init before root acpi_bus_scan' "$SRC/drivers/acpi/scan.c" || die "scan trace marker missing"
    grep -q 'A14TRACE acpi_init before acpi_scan_init' "$SRC/drivers/acpi/bus.c" || die "bus trace marker missing"
}

verify_trace_image(){
    local image="$OUT/arch/arm64/boot/Image"
    [[ -s "$image" ]] || die "Image missing: $image"
    for s in \
        'A14TRACE power before tie-acpi-dev' \
        'A14TRACE power after device-finalize; return' \
        'A14TRACE acpi_scan_init before root acpi_bus_scan' \
        'A14TRACE acpi_init before acpi_scan_init'; do
        grep -aFq "$s" "$image" || die "built Image lacks trace string: $s"
    done
    say "A14_ACPI_SCAN_TRACE_IMAGE=VERIFIED"
}

build_trace(){
    need_user
    verify_tree
    python3 "$PATCHER" "$SRC"
    verify_trace_source
    export LOCALVERSION=
    say "A14_ACPI_SCAN_TRACE_BUILD=START"
    say "scope=incremental Image only; existing modules preserved"
    say "jobs=$JOBS"
    say "raw_log=$LOG"

    set +e
    if [[ -t 1 && -f "$PROGRESS" ]]; then
        make -C "$SRC" O="$OUT" -j"$JOBS" Image 2>&1 \
            | tee "$LOG" \
            | python3 "$PROGRESS" --label "ACPI scan trace Image" --logfile "$LOG" --module-total 0 --module-built 0
        rc=${PIPESTATUS[0]}
    else
        make -C "$SRC" O="$OUT" -j"$JOBS" Image 2>&1 | tee "$LOG"
        rc=${PIPESTATUS[0]}
    fi
    set -e
    if (( rc != 0 )); then
        echo "ERROR: trace Image build failed rc=$rc" >&2
        tail -n 120 "$LOG" >&2 || true
        exit "$rc"
    fi

    verify_trace_image
    say "A14_ACPI_SCAN_TRACE_BUILD=COMPLETE"
    say "image=$OUT/arch/arm64/boot/Image"
    say "sha256=$(sha256sum "$OUT/arch/arm64/boot/Image" | awk '{print $1}')"
}

install_trace(){
    need_root
    verify_tree
    verify_trace_source
    verify_trace_image
    [[ -s "$KERNEL" ]] || die "installed experimental kernel missing: $KERNEL"
    [[ "$(uname -r)" != "$KREL" ]] || die "refusing to replace the currently running experimental kernel"

    if [[ ! -e "$BACKUP" ]]; then
        cp -a "$KERNEL" "$BACKUP"
        say "backup_created=$BACKUP"
    else
        say "backup_preserved=$BACKUP"
    fi

    install -m0644 "$OUT/arch/arm64/boot/Image" "$KERNEL"
    cmp -s "$OUT/arch/arm64/boot/Image" "$KERNEL" || die "installed trace Image does not match build"
    say "A14_ACPI_SCAN_TRACE_INSTALL=COMPLETE"
    say "kernel=$KERNEL"
    say "installed_sha256=$(sha256sum "$KERNEL" | awk '{print $1}')"
    say "initramfs_unchanged=true"
    say "modules_unchanged=true"
    say "normal_DT_kernel_untouched=true"
    say "diagnostic_GRUB_entry_reuses_same_kernel_path=true"
}

restore_trace(){
    need_root
    [[ -s "$BACKUP" ]] || die "backup missing: $BACKUP"
    [[ "$(uname -r)" != "$KREL" ]] || die "boot normal DT kernel before restore"
    cp -a "$BACKUP" "$KERNEL"
    say "A14_ACPI_SCAN_TRACE_RESTORE=COMPLETE"
    say "kernel=$KERNEL"
    say "sha256=$(sha256sum "$KERNEL" | awk '{print $1}')"
}

status(){
    say "source=$SRC"
    say "build=$OUT"
    say "kernel=$KERNEL"
    say "backup=$BACKUP"
    say "trace_source=$([[ -f "$SRC/drivers/acpi/power.c" ]] && grep -q A14_ACPI_SCAN_TRACE_V1 "$SRC/drivers/acpi/power.c" && echo yes || echo no)"
    say "backup_exists=$([[ -s "$BACKUP" ]] && echo yes || echo no)"
}

case "$ACTION" in
    build) build_trace;;
    install) install_trace;;
    restore) restore_trace;;
    status) status;;
    *) die "usage: $0 {build|install|restore|status}";;
esac
