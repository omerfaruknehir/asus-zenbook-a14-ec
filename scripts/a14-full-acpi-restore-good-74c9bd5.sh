#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Reproduce the known-good A14 full-ACPI Image and boot command line from
# repository commit 74c9bd5, without creating a second Linux source/build tree
# and without rebuilding thousands of unchanged generic modules.
set -euo pipefail

ACTION="${1:-status}"
GOOD_COMMIT="74c9bd5ebc77e2563b8be50d8cb4af67202c71fe"
KREL="7.1.5-a14-acpi-full0"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
HIST_REPO="${A14_74C9_REPO:-$OWNER_HOME/Downloads/asus-zenbook-a14-ec-74c9bd5}"
# IMPORTANT: reuse the existing Linux work area. Historical prepare() already
# resets the source and recreates build/, so a second 40+ GiB tree is pointless.
HIST_WORK="${A14_74C9_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
FAILED_DUP="$OWNER_HOME/Downloads/a14-full-acpi-kernel-74c9bd5"
STAMP="$HIST_WORK/74c9bd5-build.ready"
BUILD_LOG="$HIST_WORK/a14-74c9-image-build.log"
KERNEL="/boot/vmlinuz-$KREL"
INITRD="/boot/initrd.img-$KREL"
CONFIG="/boot/config-$KREL"
SYSTEM_MAP="/boot/System.map-$KREL"
BACKUP="/boot/vmlinuz-$KREL.pre-74c9bd5-restore"
HIST_BASE="$HIST_REPO/scripts/a14-full-acpi-kernel.sh"
HIST_FINAL="$HIST_REPO/scripts/a14-full-acpi-geni-wrapperless-refresh.sh"
HIST_ENTRY="$HIST_REPO/scripts/a14-full-acpi-unrestricted-entry.sh"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_user(){ [[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as normal user, not root"; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "install/cleanup requires sudo/root"; }

ensure_historical_worktree(){
    need git
    if ! git -C "$ROOT" cat-file -e "$GOOD_COMMIT^{commit}" 2>/dev/null; then
        git -C "$ROOT" fetch origin "$GOOD_COMMIT"
    fi
    [[ "$(git -C "$ROOT" rev-parse "$GOOD_COMMIT^{commit}")" == "$GOOD_COMMIT" ]] || die "cannot resolve pinned commit"

    if [[ -e "$HIST_REPO/.git" || -f "$HIST_REPO/.git" ]]; then
        actual="$(git -C "$HIST_REPO" rev-parse HEAD 2>/dev/null || true)"
        [[ "$actual" == "$GOOD_COMMIT" ]] || die "historical worktree is at ${actual:-unknown}, expected $GOOD_COMMIT"
    else
        [[ ! -e "$HIST_REPO" || -z "$(ls -A "$HIST_REPO" 2>/dev/null || true)" ]] || die "historical worktree path occupied: $HIST_REPO"
        git -C "$ROOT" worktree add --detach "$HIST_REPO" "$GOOD_COMMIT"
    fi
    for f in "$HIST_BASE" "$HIST_FINAL" "$HIST_ENTRY"; do [[ -f "$f" ]] || die "historical script missing: $f"; done
    say "historical_repo_commit=$GOOD_COMMIT"
}

verify_historical_cmdline_script(){
    grep -Fq 'BOOT_UI_ARGS="earlycon=efifb,ram console=tty0 loglevel=8 ignore_loglevel printk.time=1"' "$HIST_ENTRY" || die "74c9 verbose cmdline mismatch"
    grep -Fq 'cmdline="${args[*]} $BOOT_UI_ARGS acpi=force"' "$HIST_ENTRY" || die "74c9 acpi=force construction mismatch"
    say "historical_cmdline=VERIFIED"
    say "historical_boot_ui_args=earlycon=efifb,ram console=tty0 loglevel=8 ignore_loglevel printk.time=1"
    say "historical_acpi_force=true"
}

space_report(){
    say "===== disk preflight ====="
    df -h "$OWNER_HOME" || true
    [[ -d "$HIST_WORK" ]] && du -sh "$HIST_WORK" 2>/dev/null || true
    [[ -d "$FAILED_DUP" ]] && {
        du -sh "$FAILED_DUP" 2>/dev/null || true
        die "failed duplicate build still exists at $FAILED_DUP; remove it before continuing"
    }
    say "storage_mode=in-place"
    say "kernel_work=$HIST_WORK"
    say "full_module_rebuild=false"
}

verify_final_source(){
    local src="$HIST_WORK/linux-7.1.5"
    grep -q 'A14 ACPI: wrapperless GENI SE, TX FIFO depth' "$src/drivers/i2c/busses/i2c-qcom-geni.c" || die "historical wrapperless GENI marker missing"
    grep -q 'a14_iort_pcie_smmuv3_firmware_owned' "$src/drivers/acpi/arm64/iort.c" || die "historical PCIe SMMUv3 patch missing"
    grep -q 'a14_acpi_trace_delay_ms' "$src/drivers/acpi/bus.c" || die "historical trace-delay patch missing"
    grep -q 'smmu-reset-after-scr0-write' "$src/drivers/iommu/arm/arm-smmu/arm-smmu.c" || die "historical SMMU reset checkpoints missing"
    ! grep -q 'A14_QCOM_WOA_ACPI_GPIO_XLATE' "$src/drivers/gpio/gpiolib-acpi-core.c" || die "later WoA GPIO translation contaminated source"
    ! grep -q 'A14_ACPI_SCAN_TRACE_V' "$src/drivers/acpi/scan.c" || die "later scan trace contaminated source"
}

build_good(){
    need_user
    ensure_historical_worktree
    verify_historical_cmdline_script
    space_report
    rm -f "$STAMP"

    say "A14_74C9_BUILD_STAGE=1/2 exact-historical-prepare"
    say "note=prepare resets existing source/build in-place; no duplicate Linux tree"
    A14_FULL_ACPI_WORK="$HIST_WORK" bash "$HIST_BASE" prepare

    say "A14_74C9_BUILD_STAGE=2/2 exact-historical-final-Image"
    say "note=no generic modules build; final historical chain builds Image only"
    set +e
    A14_FULL_ACPI_WORK="$HIST_WORK" bash "$HIST_FINAL" build 2>&1 | tee "$BUILD_LOG"
    rc=${PIPESTATUS[0]}
    set -e
    (( rc == 0 )) || { tail -n 150 "$BUILD_LOG" >&2 || true; die "74c9 final Image build failed rc=$rc"; }

    verify_final_source
    image="$HIST_WORK/build/arch/arm64/boot/Image"
    [[ -s "$image" ]] || die "final historical Image missing"
    [[ -s "$HIST_WORK/build/vmlinux" ]] || die "final historical vmlinux missing"
    [[ "$(make -s -C "$HIST_WORK/linux-7.1.5" O="$HIST_WORK/build" kernelrelease)" == "$KREL" ]] || die "kernelrelease mismatch"

    sha="$(sha256sum "$image" | awk '{print $1}')"
    cat >"$STAMP" <<EOF
repo_commit=$GOOD_COMMIT
kernelrelease=$KREL
image_sha256=$sha
build_mode=in-place-image-only
historical_cmdline=earlycon=efifb,ram console=tty0 loglevel=8 ignore_loglevel printk.time=1 acpi=force
EOF
    say "A14_74C9_BUILD=COMPLETE"
    say "image=$image"
    say "sha256=$sha"
    say "full_module_rebuild=false"
    say "stamp=$STAMP"
}

cleanup_a14_grub(){
    need_root
    local f removed=0 next
    shopt -s nullglob
    for f in /etc/grub.d/*a14_full_acpi*; do
        [[ -f "$f" || -L "$f" ]] || continue
        say "removing_grub_snippet=$f"
        rm -f -- "$f"
        removed=$((removed + 1))
    done
    shopt -u nullglob
    if command -v grub-editenv >/dev/null 2>&1 && [[ -f /boot/grub/grubenv ]]; then
        next="$(grub-editenv /boot/grub/grubenv list 2>/dev/null | sed -n 's/^next_entry=//p' | head -n1 || true)"
        case "$next" in a14-*|*a14-full-acpi*|*ACPI-ONLY*) grub-editenv /boot/grub/grubenv unset next_entry || true; say "cleared_grub_next_entry=$next";; esac
    fi
    say "A14_GRUB_POLLUTION_REMOVED=$removed"
}

verify_existing_modules(){
    local moddir="/lib/modules/$KREL" sample vermagic
    [[ -d "$moddir" ]] || die "existing module tree missing: $moddir"
    sample="$(find "$moddir/kernel" -type f \( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' -o -name '*.ko.gz' \) -print -quit 2>/dev/null || true)"
    [[ -n "$sample" ]] || die "no existing kernel modules found under $moddir/kernel"
    if command -v modinfo >/dev/null 2>&1; then
        vermagic="$(modinfo -F vermagic "$sample" 2>/dev/null || true)"
        [[ -z "$vermagic" || "$vermagic" == "$KREL"* ]] || die "existing modules have incompatible vermagic: $vermagic"
        say "existing_module_vermagic=${vermagic:-unavailable}"
    fi
    say "existing_modules=preserved"
}

install_good(){
    need_root
    for c in install depmod update-initramfs update-grub sha256sum; do need "$c"; done
    ensure_historical_worktree
    verify_historical_cmdline_script
    [[ "$(uname -r)" != "$KREL" ]] || die "boot normal DT kernel before replacing $KREL"
    [[ -r "$STAMP" ]] || die "successful pinned build stamp missing; run build first"
    verify_existing_modules

    stamp_commit="$(sed -n 's/^repo_commit=//p' "$STAMP")"
    stamp_krel="$(sed -n 's/^kernelrelease=//p' "$STAMP")"
    expected_sha="$(sed -n 's/^image_sha256=//p' "$STAMP")"
    image="$HIST_WORK/build/arch/arm64/boot/Image"
    actual_sha="$(sha256sum "$image" | awk '{print $1}')"
    [[ "$stamp_commit" == "$GOOD_COMMIT" ]] || die "build stamp commit mismatch"
    [[ "$stamp_krel" == "$KREL" ]] || die "build stamp kernelrelease mismatch"
    [[ -n "$expected_sha" && "$expected_sha" == "$actual_sha" ]] || die "Image changed since successful build"
    verify_final_source

    [[ ! -e "$BACKUP" && -s "$KERNEL" ]] && { cp -a "$KERNEL" "$BACKUP"; say "backup_created=$BACKUP"; }

    say "A14_74C9_INSTALL_STAGE=1/4 kernel-artifacts"
    install -m0644 "$image" "$KERNEL"
    install -m0644 "$HIST_WORK/build/.config" "$CONFIG"
    [[ ! -s "$HIST_WORK/build/System.map" ]] || install -m0644 "$HIST_WORK/build/System.map" "$SYSTEM_MAP"
    cmp -s "$image" "$KERNEL" || die "installed Image mismatch"

    say "A14_74C9_INSTALL_STAGE=2/4 depmod-initramfs"
    depmod -a "$KREL"
    if [[ -s "$INITRD" ]]; then update-initramfs -u -k "$KREL"; else update-initramfs -c -k "$KREL"; fi

    say "A14_74C9_INSTALL_STAGE=3/4 grub-cleanup"
    cleanup_a14_grub

    say "A14_74C9_INSTALL_STAGE=4/4 exact-74c9-commandline"
    A14_ACPI_SPLASH=0 bash "$HIST_ENTRY"

    installed_sha="$(sha256sum "$KERNEL" | awk '{print $1}')"
    [[ "$installed_sha" == "$expected_sha" ]] || die "installed kernel hash mismatch"
    snippet="/etc/grub.d/41_a14_full_acpi_checkpoint"
    [[ -f "$snippet" ]] || die "historical unrestricted GRUB entry missing"
    linux_line="$(awk '/^menuentry .*ACPI-ONLY UNRESTRICTED/{seen=1} seen && /^[[:space:]]*linux[[:space:]]/{print; exit}' "$snippet")"
    [[ -n "$linux_line" ]] || die "historical linux line missing"
    for required in 'earlycon=efifb,ram' 'console=tty0' 'loglevel=8' 'ignore_loglevel' 'printk.time=1' 'acpi=force'; do grep -Fq "$required" <<<"$linux_line" || die "GRUB line lacks $required"; done
    for forbidden in 'keep_bootcon' 'initcall_debug' 'a14_acpi_halt=' 'a14_acpi_reboot_delay_ms=' 'a14_acpi_trace_delay_ms=' 'a14_device_halt_after=' 'initcall_blacklist=' 'ramoops.' 'reserve_mem='; do ! grep -Fq "$forbidden" <<<"$linux_line" || die "GRUB line contains forbidden $forbidden"; done
    ! grep -qE '^[[:space:]]*devicetree[[:space:]]' "$snippet" || die "GRUB entry unexpectedly loads DTB"
    count="$(find /etc/grub.d -maxdepth 1 \( -type f -o -type l \) -name '*a14_full_acpi*' | wc -l)"
    [[ "$count" -eq 1 ]] || die "expected exactly one A14 full-ACPI GRUB snippet; found $count"

    say "A14_74C9_INSTALL=COMPLETE"
    say "repo_commit=$GOOD_COMMIT"
    say "kernel=$KERNEL"
    say "installed_sha256=$installed_sha"
    say "modules=reused-existing-same-kernelrelease"
    say "custom_A14_GRUB_entries=1"
    say "hardware_dtb_loaded=false"
    say "boot_ui_args=earlycon=efifb,ram console=tty0 loglevel=8 ignore_loglevel printk.time=1"
    say "acpi_force=true"
}

status(){
    say "pinned_commit=$GOOD_COMMIT"
    say "historical_repo=$HIST_REPO"
    say "kernel_work=$HIST_WORK"
    say "failed_duplicate_path=$FAILED_DUP"
    say "running_kernel=$(uname -r)"
    [[ -r "$STAMP" ]] && { say "--- build stamp ---"; cat "$STAMP"; }
    say "--- disk ---"
    df -h "$OWNER_HOME" 2>/dev/null || true
    [[ -d "$HIST_WORK" ]] && du -sh "$HIST_WORK" 2>/dev/null || true
    say "--- installed A14 GRUB snippets ---"
    find /etc/grub.d -maxdepth 1 \( -type f -o -type l \) -name '*a14_full_acpi*' -printf '%f\n' 2>/dev/null | sort || true
}

case "$ACTION" in
    build) build_good ;;
    install) install_good ;;
    cleanup-grub) need_root; cleanup_a14_grub; update-grub ;;
    status) status ;;
    *) die "usage: $0 {build|install|cleanup-grub|status}" ;;
esac
