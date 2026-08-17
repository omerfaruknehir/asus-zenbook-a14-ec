#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Build/install a Linux 7.1.5 ARM64 kernel with the A14 ACPI DT-sidecar mode.
# The normal kernel and its GRUB entries are never replaced.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ACTION="${1:-status}"
BASE_KVER="${A14_HYBRID_BASE_KVER:-7.1.5-070105-generic}"
BASE_TAG="v7.1.5"
BASE_COMMIT="155b42bec9cbb6b8cdc47dd9bd09503a81fbe493"
LOCALVERSION="-a14-acpi-hybrid0"
EXPECTED_KREL="7.1.5${LOCALVERSION}"

owner_home() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then
        getent passwd "$SUDO_USER" | cut -d: -f6
    else
        printf '%s\n' "$HOME"
    fi
}

OWNER_HOME="$(owner_home)"
WORK="${A14_HYBRID_WORK:-$OWNER_HOME/Downloads/a14-acpi-hybrid-kernel}"
SRC="$WORK/linux-7.1.5"
OUT="$WORK/build"
META="$WORK/meta.env"
GRUB_SNIPPET="/etc/grub.d/41_a14_acpi_hybrid"
DTB_INSTALL_DIR="/boot/a14-acpi-hybrid"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "this action requires sudo/root"; }
need_user() { [[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as the normal user, not root"; }

kernel_config_source() {
    if [[ -r "/boot/config-$BASE_KVER" ]]; then
        printf '%s\n' "/boot/config-$BASE_KVER"
    elif [[ "$(uname -r)" == "$BASE_KVER" && -r /proc/config.gz ]]; then
        printf '%s\n' /proc/config.gz
    else
        return 1
    fi
}

check_arch() {
    case "$(uname -m)" in
        aarch64|arm64) ;;
        *) die "native AArch64 build required; found $(uname -m)" ;;
    esac
}

check_build_deps() {
    local missing=()
    local c
    for c in git python3 make gcc bc bison flex perl rsync pahole openssl cpio; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if ((${#missing[@]})); then
        printf 'Missing build tools: %s\n' "${missing[*]}" >&2
        printf 'Ubuntu package baseline: sudo apt install build-essential bc bison flex libssl-dev libelf-dev dwarves rsync cpio git python3\n' >&2
        exit 1
    fi
}

prepare_source() {
    need_user
    check_arch
    check_build_deps
    need git

    mkdir -p "$WORK"
    if [[ ! -d "$SRC/.git" ]]; then
        say "Cloning exact stable Linux $BASE_TAG..."
        git clone --filter=blob:none --no-checkout https://github.com/gregkh/linux.git "$SRC"
    fi

    git -C "$SRC" fetch --force --depth=1 origin "refs/tags/$BASE_TAG:refs/tags/$BASE_TAG"
    git -C "$SRC" checkout --detach "$BASE_TAG"
    local head
    head="$(git -C "$SRC" rev-parse HEAD)"
    [[ "$head" == "$BASE_COMMIT" ]] || die "$BASE_TAG resolved to unexpected commit $head"

    # Start every build from the signed stable tag, never a previously patched tree.
    git -C "$SRC" reset --hard "$BASE_COMMIT"
    git -C "$SRC" clean -fdx

    python3 "$ROOT/scripts/apply-a14-acpi-hybrid-v0.py" "$SRC"

    rm -rf "$OUT"
    mkdir -p "$OUT"

    local cfg
    cfg="$(kernel_config_source)" || die "cannot find config for $BASE_KVER"
    if [[ "$cfg" == *.gz ]]; then
        zcat "$cfg" > "$OUT/.config"
    else
        cp "$cfg" "$OUT/.config"
    fi

    "$SRC/scripts/config" --file "$OUT/.config" --set-str LOCALVERSION "$LOCALVERSION"
    "$SRC/scripts/config" --file "$OUT/.config" --disable LOCALVERSION_AUTO
    "$SRC/scripts/config" --file "$OUT/.config" --enable ACPI
    "$SRC/scripts/config" --file "$OUT/.config" --enable EFI
    "$SRC/scripts/config" --file "$OUT/.config" --enable OF
    # Ubuntu configs can refer to distro-only certificate files that are absent
    # from an unmodified stable source checkout.
    "$SRC/scripts/config" --file "$OUT/.config" --set-str SYSTEM_TRUSTED_KEYS ""
    "$SRC/scripts/config" --file "$OUT/.config" --set-str SYSTEM_REVOCATION_KEYS ""

    # The source tree is intentionally modified by the hybrid transform. Linux
    # otherwise appends '+' to the release when LOCALVERSION is unset and the
    # Git tree is dirty. Export an explicitly empty Kbuild LOCALVERSION while
    # keeping the requested suffix in CONFIG_LOCALVERSION above.
    export LOCALVERSION=

    make -C "$SRC" O="$OUT" olddefconfig

    local krel
    krel="$(make -s -C "$SRC" O="$OUT" kernelrelease)"
    [[ "$krel" == "$EXPECTED_KREL" ]] || die "unexpected kernelrelease: $krel"

    cat > "$META" <<EOF
BASE_TAG='$BASE_TAG'
BASE_COMMIT='$BASE_COMMIT'
BASE_KVER='$BASE_KVER'
KREL='$krel'
SRC='$SRC'
OUT='$OUT'
LOCALVERSION='-a14-acpi-hybrid0'
EOF

    say "A14_ACPI_HYBRID_PREPARED=1"
    say "source_commit=$head"
    say "kernelrelease=$krel"
    say "source=$SRC"
    say "build_dir=$OUT"
}

build_kernel() {
    prepare_source
    local jobs="${A14_BUILD_JOBS:-$(nproc)}"
    say "Building $EXPECTED_KREL with $jobs jobs..."
    make -C "$SRC" O="$OUT" -j"$jobs" Image modules

    [[ -s "$OUT/arch/arm64/boot/Image" ]] || die "kernel Image was not produced"
    local built_rel
    built_rel="$(make -s -C "$SRC" O="$OUT" kernelrelease)"
    [[ "$built_rel" == "$EXPECTED_KREL" ]] || die "post-build kernelrelease changed: $built_rel"

    say "A14_ACPI_HYBRID_BUILD=COMPLETE"
    say "kernelrelease=$built_rel"
    say "image=$OUT/arch/arm64/boot/Image"
    say "image_sha256=$(sha256sum "$OUT/arch/arm64/boot/Image" | awk '{print $1}')"
}

load_meta() {
    [[ -r "$META" ]] || die "missing $META; run '$0 build' as your normal user first"
    # shellcheck disable=SC1090
    source "$META"
    [[ "${KREL:-}" == "$EXPECTED_KREL" ]] || die "metadata kernelrelease mismatch: ${KREL:-missing}"
    [[ "${BASE_COMMIT:-}" == "155b42bec9cbb6b8cdc47dd9bd09503a81fbe493" ]] || die "metadata source commit mismatch"
    [[ -s "$OUT/arch/arm64/boot/Image" ]] || die "built Image missing"
}

find_live_dtb() {
    # Best source is the exact FDT that booted the known-good running kernel.
    if [[ -r /sys/firmware/fdt ]]; then
        printf '%s\n' /sys/firmware/fdt
        return 0
    fi

    local candidate
    for candidate in \
        "/boot/dtb-$BASE_KVER/qcom/x1e80100-asus-zenbook-a14.dtb" \
        "/usr/lib/linux-image-$BASE_KVER/qcom/x1e80100-asus-zenbook-a14.dtb" \
        "/boot/dtbs/$BASE_KVER/qcom/x1e80100-asus-zenbook-a14.dtb"; do
        [[ -r "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
    done
    return 1
}

build_a14_modules_for_kernel() {
    # Compose the current EC implementation in a disposable copy, then restore
    # the committed known-good HID source before compiling. This prevents the
    # experimental Fn-lock generator from re-breaking keyboard-backlight init.
    local modwork="$WORK/a14-modules-$KREL"
    local jobs="${A14_BUILD_JOBS:-$(nproc)}"
    rm -rf "$modwork"
    mkdir -p "$modwork"
    git -C "$ROOT" archive HEAD | tar -x -C "$modwork"

    (
        cd "$modwork"
        python3 scripts/prepare-a14-ec.py
        git --version >/dev/null 2>&1 || true
    )

    # archive has no .git, so overwrite the generated HID using the trusted
    # committed base from the real checkout.
    git -C "$ROOT" show HEAD:hid_asus_ec.c > "$modwork/hid_asus_ec.c"
    grep -Fq 'static int asus_hid_initialise' "$modwork/hid_asus_ec.c" || die "known-good HID recovery source missing"
    ! grep -Fq 'A14_HID_FNLOCK_WINDOWS_FULL_FEATURE_REPORT' "$modwork/hid_asus_ec.c" || die "Fn-lock transform leaked into hybrid HID module"

    A14_MODULE_DIR="$modwork" \
    A14_BUILD_JOBS="$jobs" \
    KDIR="$OUT" \
        sh "$modwork/scripts/a14-kbuild-compat.sh" "$KREL"

    [[ -s "$modwork/asus_zenbook_a14_ec.ko" ]] || die "A14 EC module build failed"
    [[ -s "$modwork/hid_asus_ec.ko" ]] || die "A14 HID module build failed"

    mkdir -p "/lib/modules/$KREL/updates/a14"
    install -m 0644 "$modwork/asus_zenbook_a14_ec.ko" "/lib/modules/$KREL/updates/a14/"
    install -m 0644 "$modwork/hid_asus_ec.ko" "/lib/modules/$KREL/updates/a14/"
    depmod -a "$KREL"

    say "a14_ec_module=$(modinfo -k "$KREL" -n asus_zenbook_a14_ec 2>/dev/null || true)"
    say "a14_hid_module=$(modinfo -k "$KREL" -n hid_asus_ec 2>/dev/null || true)"
}

write_grub_entry() {
    need grub-probe
    need grub-mkrelpath
    need update-grub

    local kernel="/boot/vmlinuz-$KREL"
    local initrd="/boot/initrd.img-$KREL"
    local dtb="$DTB_INSTALL_DIR/$KREL.dtb"
    local boot_uuid kernel_path initrd_path dtb_path
    boot_uuid="$(grub-probe --target=fs_uuid "$kernel")"
    kernel_path="$(grub-mkrelpath "$kernel")"
    initrd_path="$(grub-mkrelpath "$initrd")"
    dtb_path="$(grub-mkrelpath "$dtb")"

    local -a args=()
    local arg
    for arg in $(cat /proc/cmdline); do
        case "$arg" in
            BOOT_IMAGE=*|initrd=*|acpi=*) continue ;;
            *) args+=("$arg") ;;
        esac
    done
    local cmdline="${args[*]} acpi=hybrid"

    cat > "$GRUB_SNIPPET" <<EOF
#!/bin/sh
exec tail -n +3 \$0
# Dedicated UX3407RA ACPI+DT sidecar test. Generated by a14-acpi-hybrid-kernel.sh.
menuentry 'ASUS Zenbook A14 — ACPI+DT Hybrid v0 ($KREL)' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root $boot_uuid
    linux $kernel_path $cmdline
    devicetree $dtb_path
    initrd $initrd_path
}
EOF
    chmod 0755 "$GRUB_SNIPPET"
    update-grub
}

install_kernel() {
    need_root
    check_arch
    load_meta
    [[ "$(uname -r)" != "$KREL" ]] || die "refusing to reinstall the currently running experimental kernel"

    need depmod
    need update-initramfs
    need sha256sum

    # Keep the same explicit empty Kbuild LOCALVERSION used by the build.
    export LOCALVERSION=

    say "Installing modules for $KREL..."
    make -C "$SRC" O="$OUT" modules_install

    # Ensure external-module builds can target the exact configured output tree.
    ln -sfn "$OUT" "/lib/modules/$KREL/build"
    ln -sfn "$SRC" "/lib/modules/$KREL/source"

    install -m 0644 "$OUT/arch/arm64/boot/Image" "/boot/vmlinuz-$KREL"
    [[ -s "$OUT/System.map" ]] && install -m 0644 "$OUT/System.map" "/boot/System.map-$KREL"
    install -m 0644 "$OUT/.config" "/boot/config-$KREL"

    mkdir -p "$DTB_INSTALL_DIR"
    local live_dtb
    live_dtb="$(find_live_dtb)" || die "cannot locate the known-good live A14 DTB"
    cp "$live_dtb" "$DTB_INSTALL_DIR/$KREL.dtb"
    chmod 0644 "$DTB_INSTALL_DIR/$KREL.dtb"
    say "dtb_source=$live_dtb"
    say "dtb_sha256=$(sha256sum "$DTB_INSTALL_DIR/$KREL.dtb" | awk '{print $1}')"

    build_a14_modules_for_kernel

    # Build a fresh initramfs only for the experimental release.
    rm -f "/boot/initrd.img-$KREL"
    update-initramfs -c -k "$KREL"
    write_grub_entry

    say "A14_ACPI_HYBRID_INSTALL=COMPLETE"
    say "kernelrelease=$KREL"
    say "kernel=/boot/vmlinuz-$KREL"
    say "initrd=/boot/initrd.img-$KREL"
    say "dtb=$DTB_INSTALL_DIR/$KREL.dtb"
    say "grub_entry=ASUS Zenbook A14 — ACPI+DT Hybrid v0 ($KREL)"
    say "The existing $BASE_KVER kernel and normal GRUB entries were not replaced."
}

status_kernel() {
    say "===== A14 ACPI+DT HYBRID STATUS ====="
    say "running_kernel=$(uname -r)"
    say "expected_kernel=$EXPECTED_KREL"
    say "cmdline=$(cat /proc/cmdline)"
    say "hybrid_cmdline=$(grep -qw 'acpi=hybrid' /proc/cmdline && echo yes || echo no)"
    say "device_tree=$([[ -d /proc/device-tree ]] && echo present || echo absent)"
    say "kernel_image=$([[ -f /boot/vmlinuz-$EXPECTED_KREL ]] && echo present || echo absent)"
    say "initramfs=$([[ -f /boot/initrd.img-$EXPECTED_KREL ]] && echo present || echo absent)"
    say "hybrid_dtb=$([[ -f "$DTB_INSTALL_DIR/$EXPECTED_KREL.dtb" ]] && echo present || echo absent)"
    say "grub_snippet=$([[ -f "$GRUB_SNIPPET" ]] && echo present || echo absent)"
    if [[ "$(uname -r)" == "$EXPECTED_KREL" ]]; then
        say "----- hybrid dmesg -----"
        dmesg 2>/dev/null | grep -E 'DT-hybrid|ACPI: Core revision|ACPI: Interpreter disabled' | tail -n 120 || true
    fi
}

remove_kernel() {
    need_root
    if [[ "$(uname -r)" == "$EXPECTED_KREL" ]]; then
        die "boot the known-good $BASE_KVER kernel before removing $EXPECTED_KREL"
    fi
    [[ "$EXPECTED_KREL" == *a14-acpi-hybrid0 ]] || die "internal release-name safety check failed"

    rm -f "$GRUB_SNIPPET"
    rm -f "/boot/vmlinuz-$EXPECTED_KREL" "/boot/System.map-$EXPECTED_KREL" "/boot/config-$EXPECTED_KREL"
    rm -f "/boot/initrd.img-$EXPECTED_KREL"
    rm -f "$DTB_INSTALL_DIR/$EXPECTED_KREL.dtb"
    rmdir "$DTB_INSTALL_DIR" 2>/dev/null || true
    rm -rf "/lib/modules/$EXPECTED_KREL"
    command -v update-grub >/dev/null 2>&1 && update-grub
    say "A14_ACPI_HYBRID_REMOVED=1"
    say "Known-good kernel untouched: $BASE_KVER"
}

case "$ACTION" in
    prepare) prepare_source ;;
    build) build_kernel ;;
    install) install_kernel ;;
    status) status_kernel ;;
    remove|uninstall|rollback) remove_kernel ;;
    *)
        cat >&2 <<EOF
Usage:
  bash ${0##*/} build
  sudo bash ${0##*/} install
  bash ${0##*/} status
  sudo bash ${0##*/} remove
EOF
        exit 2
        ;;
esac
