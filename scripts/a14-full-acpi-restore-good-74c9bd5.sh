#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Reproduce the known-good A14 full-ACPI state from repository commit 74c9bd5.
#
# IMPORTANT: this does not reuse the mutable/current kernel source tree. It
# creates a detached worktree at the exact historical repository commit and a
# dedicated Linux build directory, then runs the historical scripts themselves.
set -euo pipefail

ACTION="${1:-status}"
GOOD_COMMIT="74c9bd5ebc77e2563b8be50d8cb4af67202c71fe"
GOOD_SHORT="74c9bd5"
KREL="7.1.5-a14-acpi-full0"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
HIST_REPO="${A14_74C9_REPO:-$OWNER_HOME/Downloads/asus-zenbook-a14-ec-74c9bd5}"
HIST_WORK="${A14_74C9_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel-74c9bd5}"
STAMP="$HIST_WORK/74c9bd5-build.ready"
KERNEL="/boot/vmlinuz-$KREL"
INITRD="/boot/initrd.img-$KREL"
HIST_BASE="$HIST_REPO/scripts/a14-full-acpi-kernel.sh"
HIST_FINAL="$HIST_REPO/scripts/a14-full-acpi-geni-wrapperless-refresh.sh"
HIST_ENTRY="$HIST_REPO/scripts/a14-full-acpi-unrestricted-entry.sh"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_user(){ [[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as your normal user, not root"; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "install/cleanup requires sudo/root"; }

ensure_historical_worktree(){
    need git
    if ! git -C "$ROOT" cat-file -e "$GOOD_COMMIT^{commit}" 2>/dev/null; then
        git -C "$ROOT" fetch origin "$GOOD_COMMIT"
    fi
    [[ "$(git -C "$ROOT" rev-parse "$GOOD_COMMIT^{commit}")" == "$GOOD_COMMIT" ]] || die "cannot resolve pinned commit $GOOD_COMMIT"

    if [[ -e "$HIST_REPO/.git" || -f "$HIST_REPO/.git" ]]; then
        actual="$(git -C "$HIST_REPO" rev-parse HEAD 2>/dev/null || true)"
        [[ "$actual" == "$GOOD_COMMIT" ]] || die "historical worktree exists at wrong commit: ${actual:-unknown}; remove $HIST_REPO and retry"
    else
        [[ ! -e "$HIST_REPO" || -z "$(ls -A "$HIST_REPO" 2>/dev/null || true)" ]] || die "historical worktree path is occupied: $HIST_REPO"
        mkdir -p "$(dirname "$HIST_REPO")"
        git -C "$ROOT" worktree add --detach "$HIST_REPO" "$GOOD_COMMIT"
    fi

    [[ "$(git -C "$HIST_REPO" rev-parse HEAD)" == "$GOOD_COMMIT" ]] || die "historical worktree drifted from $GOOD_COMMIT"
    for f in "$HIST_BASE" "$HIST_FINAL" "$HIST_ENTRY"; do [[ -f "$f" ]] || die "historical script missing: $f"; done
    say "historical_repo_commit=$GOOD_COMMIT"
}

verify_historical_cmdline_script(){
    grep -Fq 'BOOT_UI_ARGS="earlycon=efifb,ram console=tty0 loglevel=8 ignore_loglevel printk.time=1"' "$HIST_ENTRY" \
        || die "74c9bd5 verbose command line no longer matches expected historical script"
    grep -Fq 'cmdline="${args[*]} $BOOT_UI_ARGS acpi=force"' "$HIST_ENTRY" \
        || die "74c9bd5 acpi=force command-line construction mismatch"
    grep -Fq 'SNIPPET="/etc/grub.d/41_a14_full_acpi_checkpoint"' "$HIST_ENTRY" \
        || die "74c9bd5 unrestricted GRUB snippet path mismatch"
    say "historical_cmdline=VERIFIED"
    say "historical_boot_ui_args=earlycon=efifb,ram console=tty0 loglevel=8 ignore_loglevel printk.time=1"
    say "historical_acpi_force=true"
}

build_good(){
    need_user
    ensure_historical_worktree
    verify_historical_cmdline_script

    rm -f "$STAMP"
    mkdir -p "$HIST_WORK"

    say "A14_74C9_BUILD_STAGE=1/2 base-full-build"
    say "historical_repo=$HIST_REPO"
    say "kernel_work=$HIST_WORK"
    A14_FULL_ACPI_WORK="$HIST_WORK" bash "$HIST_BASE" build

    say "A14_74C9_BUILD_STAGE=2/2 historical-final-patch-chain"
    A14_FULL_ACPI_WORK="$HIST_WORK" bash "$HIST_FINAL" build

    image="$HIST_WORK/build/arch/arm64/boot/Image"
    [[ -s "$image" ]] || die "historical final Image missing: $image"
    [[ -s "$HIST_WORK/build/vmlinux" ]] || die "historical vmlinux missing"

    grep -q 'A14 ACPI: wrapperless GENI SE, TX FIFO depth' "$HIST_WORK/linux-7.1.5/drivers/i2c/busses/i2c-qcom-geni.c" \
        || die "historical wrapperless GENI marker missing"
    grep -q 'a14_iort_pcie_smmuv3_firmware_owned' "$HIST_WORK/linux-7.1.5/drivers/acpi/arm64/iort.c" \
        || die "historical PCIe SMMUv3 ownership patch missing"
    grep -q 'a14_acpi_trace_delay_ms' "$HIST_WORK/linux-7.1.5/drivers/acpi/bus.c" \
        || die "historical ACPI trace-delay patch missing"
    ! grep -q 'A14_QCOM_WOA_ACPI_GPIO_XLATE' "$HIST_WORK/linux-7.1.5/drivers/gpio/gpiolib-acpi-core.c" \
        || die "later WoA GPIO translation contaminated historical build"
    ! grep -q 'A14_ACPI_SCAN_TRACE_V' "$HIST_WORK/linux-7.1.5/drivers/acpi/scan.c" \
        || die "later ACPI scan trace contaminated historical build"

    sha="$(sha256sum "$image" | awk '{print $1}')"
    cat >"$STAMP" <<EOF
repo_commit=$GOOD_COMMIT
kernelrelease=$KREL
image_sha256=$sha
historical_cmdline=earlycon=efifb,ram console=tty0 loglevel=8 ignore_loglevel printk.time=1 acpi=force
EOF
    say "A14_74C9_BUILD=COMPLETE"
    say "image=$image"
    say "sha256=$sha"
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
        case "$next" in
            a14-*|*a14-full-acpi*|*ACPI-ONLY*)
                grub-editenv /boot/grub/grubenv unset next_entry || true
                say "cleared_grub_next_entry=$next"
                ;;
        esac
    fi
    say "A14_GRUB_POLLUTION_REMOVED=$removed"
}

install_good(){
    need_root
    ensure_historical_worktree
    verify_historical_cmdline_script
    [[ "$(uname -r)" != "$KREL" ]] || die "boot the normal DT kernel before replacing $KREL"
    [[ -r "$STAMP" ]] || die "successful pinned build stamp missing; run build first"

    stamp_commit="$(sed -n 's/^repo_commit=//p' "$STAMP")"
    stamp_krel="$(sed -n 's/^kernelrelease=//p' "$STAMP")"
    expected_sha="$(sed -n 's/^image_sha256=//p' "$STAMP")"
    image="$HIST_WORK/build/arch/arm64/boot/Image"
    actual_sha="$(sha256sum "$image" | awk '{print $1}')"
    [[ "$stamp_commit" == "$GOOD_COMMIT" ]] || die "build stamp is not from $GOOD_COMMIT"
    [[ "$stamp_krel" == "$KREL" ]] || die "build stamp kernelrelease mismatch"
    [[ -n "$expected_sha" && "$expected_sha" == "$actual_sha" ]] || die "historical Image changed since successful build"

    say "A14_74C9_INSTALL_STAGE=1/3 historical-kernel-install"
    A14_FULL_ACPI_WORK="$HIST_WORK" bash "$HIST_BASE" install

    say "A14_74C9_INSTALL_STAGE=2/3 grub-cleanup"
    cleanup_a14_grub

    say "A14_74C9_INSTALL_STAGE=3/3 exact-74c9-unrestricted-entry"
    A14_ACPI_SPLASH=0 bash "$HIST_ENTRY"

    [[ -s "$KERNEL" ]] || die "installed historical kernel missing: $KERNEL"
    [[ -s "$INITRD" ]] || die "installed historical initramfs missing: $INITRD"
    installed_sha="$(sha256sum "$KERNEL" | awk '{print $1}')"
    [[ "$installed_sha" == "$expected_sha" ]] || die "installed kernel does not match pinned 74c9 build"

    snippet="/etc/grub.d/41_a14_full_acpi_checkpoint"
    [[ -f "$snippet" ]] || die "historical unrestricted entry missing: $snippet"
    linux_line="$(awk '/^menuentry .*ACPI-ONLY UNRESTRICTED/{seen=1} seen && /^[[:space:]]*linux[[:space:]]/{print; exit}' "$snippet")"
    [[ -n "$linux_line" ]] || die "cannot find historical unrestricted linux line"
    for required in 'earlycon=efifb,ram' 'console=tty0' 'loglevel=8' 'ignore_loglevel' 'printk.time=1' 'acpi=force'; do
        grep -Fq "$required" <<<"$linux_line" || die "installed GRUB line lacks historical parameter: $required"
    done
    for forbidden in 'keep_bootcon' 'initcall_debug' 'a14_acpi_halt=' 'a14_acpi_reboot_delay_ms=' 'a14_acpi_trace_delay_ms=' 'a14_device_halt_after=' 'initcall_blacklist=' 'ramoops.' 'reserve_mem='; do
        ! grep -Fq "$forbidden" <<<"$linux_line" || die "installed GRUB line contains non-74c9 diagnostic parameter: $forbidden"
    done
    ! grep -qE '^[[:space:]]*devicetree[[:space:]]' "$snippet" || die "historical unrestricted entry unexpectedly loads DTB"

    count="$(find /etc/grub.d -maxdepth 1 \( -type f -o -type l \) -name '*a14_full_acpi*' | wc -l)"
    [[ "$count" -eq 1 ]] || die "expected exactly one A14 full-ACPI GRUB snippet after cleanup; found $count"

    say "A14_74C9_INSTALL=COMPLETE"
    say "repo_commit=$GOOD_COMMIT"
    say "kernel=$KERNEL"
    say "installed_sha256=$installed_sha"
    say "grub_snippet=$snippet"
    say "custom_A14_GRUB_entries=1"
    say "hardware_dtb_loaded=false"
    say "commandline_source=exact-74c9bd5-unrestricted-script"
    say "boot_ui_args=earlycon=efifb,ram console=tty0 loglevel=8 ignore_loglevel printk.time=1"
    say "acpi_force=true"
}

status(){
    say "pinned_commit=$GOOD_COMMIT"
    say "historical_repo=$HIST_REPO"
    say "historical_kernel_work=$HIST_WORK"
    say "build_stamp=$STAMP"
    [[ -r "$STAMP" ]] && cat "$STAMP" || true
    say "running_kernel=$(uname -r)"
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
