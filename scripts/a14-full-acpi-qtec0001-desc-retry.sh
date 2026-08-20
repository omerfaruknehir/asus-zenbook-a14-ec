#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Build/install only the QTEC0001 HID-descriptor NACK retry for the A14 ACPI
# kernel. Dynamically handles CONFIG_I2C_HID_CORE=y or =m.
set -euo pipefail

ACTION="${1:-status}"
KREL="7.1.5-a14-acpi-full0"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="${A14_74C9_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="$WORK/linux-7.1.5"
OUT="$WORK/build"
TRANSFORM="$ROOT/scripts/apply-a14-full-acpi-qtec0001-desc-retry.py"
CORE_SRC="$SRC/drivers/hid/i2c-hid/i2c-hid-core.c"
CORE_OBJ="$OUT/drivers/hid/i2c-hid/i2c-hid-core.o"
CORE_KO="$OUT/drivers/hid/i2c-hid/i2c-hid.ko"
IMAGE="$OUT/arch/arm64/boot/Image"
STAMP="$WORK/qtec0001-desc-retry.ready"
MODROOT="/lib/modules/$KREL"
KERNEL="/boot/vmlinuz-$KREL"
INITRD="/boot/initrd.img-$KREL"
BACKUP_KERNEL="/boot/vmlinuz-$KREL.pre-qtec0001-desc-retry-v1"
BACKUP_INITRD="/boot/initrd.img-$KREL.pre-qtec0001-desc-retry-v1"
MODE=""

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_user(){ [[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as normal user"; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "install/restore requires sudo/root"; }

get_mode(){
    if grep -q '^CONFIG_I2C_HID_CORE=y$' "$OUT/.config"; then
        MODE=builtin
    elif grep -q '^CONFIG_I2C_HID_CORE=m$' "$OUT/.config"; then
        MODE=module
    else
        die "CONFIG_I2C_HID_CORE is neither y nor m"
    fi
}

verify_tree(){
    [[ -f "$SRC/Makefile" && -f "$OUT/.config" && -s "$OUT/vmlinux" ]] || die "A14 build tree missing"
    export LOCALVERSION=
    local actual
    actual="$(make -s -C "$SRC" O="$OUT" kernelrelease)"
    [[ "$actual" == "$KREL" ]] || die "kernelrelease mismatch: expected $KREL got $actual"
    grep -q '^CONFIG_ACPI=y$' "$OUT/.config" || die "CONFIG_ACPI=y required"
    grep -Eq '^CONFIG_I2C_HID_ACPI=[ym]$' "$OUT/.config" || die "CONFIG_I2C_HID_ACPI required"
    grep -q '^CONFIG_MODULE_ALLOW_BTF_MISMATCH=y$' "$OUT/.config" || die "BTF compatibility missing"
    get_mode

    # Preserve every proven prerequisite and the now-proven GPU topology work.
    grep -q 'A14_GIO0_SAFE_REGISTRATION_V1' "$SRC/drivers/pinctrl/qcom/pinctrl-msm.c" || die "working GIO0 fix missing"
    grep -q 'A14_QCOM_WOA_ACPI_GPIO_XLATE' "$SRC/drivers/gpio/gpiolib-acpi-core.c" || die "working keyboard GPIO translator missing"
    grep -q 'A14_QCOM_SCM_ACPI_QCOM04DD' "$SRC/drivers/firmware/qcom/qcom_scm.c" || die "working SCM ACPI fix missing"
    grep -q 'A14_QCOM0C36_PLATFORM_ENUM_V1' "$SRC/drivers/acpi/scan.c" || die "GPU platform enumeration missing"
    grep -q 'A14_IORT_NCOMP_NO_TRAILING_V1' "$SRC/drivers/acpi/arm64/iort.c" || die "proven QCOM0C36 IORT path fix missing"
    grep -q 'A14_QCOM0C36_TOPOLOGY_V1' "$SRC/drivers/gpu/drm/msm/msm_drv.c" || die "proven GPU topology bridge missing"
}

verify_source(){
    grep -q 'A14_QTEC0001_HID_DESC_RETRY_V1' "$CORE_SRC" || die "QTEC descriptor retry marker missing"
    grep -q 'acpi_dev_hid_uid_match(adev, "QTEC0001", NULL)' "$CORE_SRC" || die "QTEC0001 exact ACPI guard missing"
    grep -q 'error == -ENXIO' "$CORE_SRC" || die "ENXIO-only guard missing"
    grep -q 'attempt < 20' "$CORE_SRC" || die "retry bound missing"
    grep -q 'msleep(50)' "$CORE_SRC" || die "retry interval missing"
    grep -q 'A14QTEC: HID descriptor ACK after' "$CORE_SRC" || die "runtime success marker missing"
}

module_targets(){
    local dep_output path rel
    local self="drivers/hid/i2c-hid/i2c-hid.ko"
    declare -A seen=()
    local -a targets=()

    [[ -d "$MODROOT" ]] || die "installed module tree missing: $MODROOT"
    dep_output="$(modprobe --set-version "$KREL" --show-depends i2c_hid)" || \
        die "modprobe could not resolve i2c_hid dependency closure"

    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        case "$path" in
            "$MODROOT"/kernel/*.ko|"$MODROOT"/kernel/*.ko.zst|"$MODROOT"/kernel/*.ko.xz|"$MODROOT"/kernel/*.ko.gz)
                rel="${path#"$MODROOT"/kernel/}"
                case "$rel" in
                    *.ko.zst) rel="${rel%.zst}" ;;
                    *.ko.xz) rel="${rel%.xz}" ;;
                    *.ko.gz) rel="${rel%.gz}" ;;
                esac
                [[ "$rel" == *.ko ]] || die "bad dependency path: $path"
                if [[ -z "${seen[$rel]:-}" ]]; then
                    targets+=("$rel")
                    seen[$rel]=1
                fi
                ;;
            "$MODROOT"/*) die "i2c_hid dependency outside in-tree kernel/: $path" ;;
            *) die "unexpected i2c_hid dependency path: $path" ;;
        esac
    done < <(awk '$1 == "insmod" { print $2 }' <<<"$dep_output")

    if [[ -z "${seen[$self]:-}" ]]; then
        targets+=("$self")
    fi
    printf '%s\n' "${targets[@]}"
}

build_fix(){
    need_user
    for c in python3 make sha256sum grep nproc awk; do need "$c"; done
    verify_tree
    [[ -f "$TRANSFORM" ]] || die "missing transform: $TRANSFORM"

    say "A14_QTEC0001_DESC_RETRY_BUILD=START"
    say "i2c_hid_core_mode=$MODE"
    say "scope=ACPI_QTEC0001_ENXIO_only"
    say "retry_count=20"
    say "retry_interval_ms=50"
    say "max_retry_window_ms=1000"
    say "gpu_source_change=false"
    say "gpio_source_change=false"

    rm -f "$STAMP"
    python3 "$TRANSFORM" "$SRC"
    python3 "$TRANSFORM" "$SRC"
    verify_source
    export LOCALVERSION=

    if [[ "$MODE" == builtin ]]; then
        rm -f "$CORE_OBJ" "$OUT/drivers/hid/i2c-hid/.i2c-hid-core.o.cmd"
        make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" Image
        [[ -s "$CORE_OBJ" && -s "$IMAGE" ]] || die "rebuilt built-in i2c-hid/Image missing"
        grep -aFq 'A14QTEC: HID descriptor ACK after' "$CORE_OBJ" || die "compiled core lacks retry marker"
        local image_sha
        image_sha="$(sha256sum "$IMAGE" | awk '{print $1}')"
        cat >"$STAMP" <<EOF
kernelrelease=$KREL
mode=builtin
image_sha256=$image_sha
scope=ACPI_QTEC0001_ENXIO_only
retry_count=20
retry_interval_ms=50
EOF
        say "A14_QTEC0001_DESC_RETRY_BUILD=COMPLETE"
        say "mode=builtin"
        say "image_sha256=$image_sha"
        say "compiled_retry=VERIFIED"
        say "module_rebuild=false"
    else
        for c in modprobe modinfo; do need "$c"; done
        type mapfile >/dev/null 2>&1 || die "bash mapfile unavailable"
        [[ -s "$OUT/vmlinux.o" ]] || die "vmlinux.o missing for native MODPOST"

        local target_lines
        local -a targets
        target_lines="$(module_targets)" || die "failed to derive i2c_hid dependency closure"
        mapfile -t targets <<<"$target_lines"
        ((${#targets[@]} >= 1)) || die "empty module dependency closure"
        say "dependency_module_targets=${#targets[@]}"
        printf 'dependency_target=%s\n' "${targets[@]}"

        rm -f "$CORE_OBJ" "$OUT/drivers/hid/i2c-hid/.i2c-hid-core.o.cmd" \
              "$OUT/drivers/hid/i2c-hid/i2c-hid.o" "$CORE_KO" \
              "$OUT/drivers/hid/i2c-hid/i2c-hid.mod" \
              "$OUT/drivers/hid/i2c-hid/i2c-hid.mod.c" \
              "$OUT/drivers/hid/i2c-hid/i2c-hid.mod.o" \
              "$OUT/Module.symvers" "$OUT/modules.order"

        make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" "${targets[@]}"
        [[ -s "$CORE_KO" && -s "$CORE_OBJ" ]] || die "rebuilt i2c-hid.ko missing"
        grep -aFq 'A14QTEC: HID descriptor ACK after' "$CORE_KO" || die "compiled i2c-hid.ko lacks retry marker"
        local vermagic ko_sha
        vermagic="$(modinfo -F vermagic "$CORE_KO" | awk '{print $1}')"
        [[ "$vermagic" == "$KREL" ]] || die "i2c-hid.ko vermagic mismatch: $vermagic"
        ko_sha="$(sha256sum "$CORE_KO" | awk '{print $1}')"
        cat >"$STAMP" <<EOF
kernelrelease=$KREL
mode=module
i2c_hid_ko_sha256=$ko_sha
scope=ACPI_QTEC0001_ENXIO_only
retry_count=20
retry_interval_ms=50
dependency_modules_installed=no
EOF
        say "A14_QTEC0001_DESC_RETRY_BUILD=COMPLETE"
        say "mode=module"
        say "i2c_hid_ko_sha256=$ko_sha"
        say "compiled_retry=VERIFIED"
        say "dependency_modules_installed=false"
        say "full_module_rebuild=false"
    fi
}

installed_module_path(){
    local p
    p="$(modinfo -k "$KREL" -n i2c_hid 2>/dev/null || true)"
    [[ -n "$p" && "$p" != builtin ]] || return 1
    readlink -f "$p"
}

verify_module_target(){
    local target="$1" root
    root="$(readlink -f "/lib/modules/$KREL")"
    [[ -n "$root" && -d "$root" ]] || die "cannot canonicalize module root"
    case "$target" in "$root"/*) ;; *) die "unexpected i2c_hid path: $target" ;; esac
}

pack_like(){
    local target="$1" src="$2" out="$3"
    case "$target" in
        *.ko) cp -f "$src" "$out" ;;
        *.ko.zst) need zstd; zstd -q -f -19 "$src" -o "$out" ;;
        *.ko.xz) need xz; xz -c -f "$src" >"$out" ;;
        *.ko.gz) need gzip; gzip -c -f "$src" >"$out" ;;
        *) die "unsupported i2c_hid compression: $target" ;;
    esac
}

initrd_contains_i2c_hid(){
    [[ -s "$INITRD" ]] || return 1
    command -v lsinitramfs >/dev/null 2>&1 || return 1
    lsinitramfs "$INITRD" 2>/dev/null | grep -Eq '(^|/)i2c-hid\.ko(\.(zst|xz|gz))?$'
}

install_fix(){
    need_root
    for c in sha256sum awk cp install; do need "$c"; done
    [[ "$(uname -r)" != "$KREL" ]] || die "boot normal DT kernel before replacing ACPI kernel artifacts"
    verify_tree
    verify_source
    [[ -r "$STAMP" ]] || die "verified QTEC retry build stamp missing"
    local stamp_mode
    stamp_mode="$(awk -F= '$1=="mode"{print $2}' "$STAMP")"
    [[ "$stamp_mode" == "$MODE" ]] || die "build/install mode mismatch: stamp=$stamp_mode config=$MODE"

    if [[ "$MODE" == builtin ]]; then
        local expected actual
        expected="$(awk -F= '$1=="image_sha256"{print $2}' "$STAMP")"
        actual="$(sha256sum "$IMAGE" | awk '{print $1}')"
        [[ -n "$expected" && "$expected" == "$actual" ]] || die "Image changed since verified build"
        [[ -s "$KERNEL" ]] || die "experimental Image missing"
        [[ -e "$BACKUP_KERNEL" ]] || cp -a "$KERNEL" "$BACKUP_KERNEL"
        install -m0644 "$IMAGE" "$KERNEL"
        say "A14_QTEC0001_DESC_RETRY_INSTALL=COMPLETE"
        say "mode=builtin"
        say "installed_image_sha256=$expected"
        say "previous_image=$BACKUP_KERNEL"
        say "modules_unchanged=true"
        say "initramfs_unchanged=true"
    else
        for c in modinfo readlink depmod; do need "$c"; done
        local expected actual target backup suffix packed initrd_updated
        expected="$(awk -F= '$1=="i2c_hid_ko_sha256"{print $2}' "$STAMP")"
        actual="$(sha256sum "$CORE_KO" | awk '{print $1}')"
        [[ -n "$expected" && "$expected" == "$actual" ]] || die "i2c-hid.ko changed since verified build"
        target="$(installed_module_path)" || die "cannot locate installed i2c_hid for $KREL"
        verify_module_target "$target"
        backup="$target.pre-qtec0001-desc-retry-v1"
        [[ -e "$backup" ]] || cp -a "$target" "$backup"

        suffix="${target##*i2c-hid.ko}"
        packed="$WORK/i2c-hid.ko.qtec-retry.install${suffix}"
        rm -f "$packed"
        pack_like "$target" "$CORE_KO" "$packed"
        install -m0644 "$packed" "$target"
        rm -f "$packed"
        depmod -a "$KREL"

        initrd_updated=false
        if initrd_contains_i2c_hid; then
            need update-initramfs
            [[ -e "$BACKUP_INITRD" ]] || cp -a "$INITRD" "$BACKUP_INITRD"
            update-initramfs -u -k "$KREL"
            initrd_updated=true
        fi

        say "A14_QTEC0001_DESC_RETRY_INSTALL=COMPLETE"
        say "mode=module"
        say "installed_i2c_hid_source_sha256=$expected"
        say "installed_path=$target"
        say "previous_module=$backup"
        say "dependency_modules_unchanged=true"
        say "depmod_updated=true"
        say "initramfs_updated=$initrd_updated"
        [[ "$initrd_updated" == false ]] || say "previous_initramfs=$BACKUP_INITRD"
    fi
}

status_fix(){
    verify_tree
    say "running_kernel=$(uname -r)"
    say "i2c_hid_core_mode=$MODE"
    [[ -r "$STAMP" ]] && { say "--- QTEC retry stamp ---"; cat "$STAMP"; }
    if [[ "$MODE" == module ]]; then
        local p=""
        if p="$(installed_module_path 2>/dev/null)"; then
            say "installed_i2c_hid=$p"
            [[ -e "$p.pre-qtec0001-desc-retry-v1" ]] && say "module_backup_present=true" || say "module_backup_present=false"
        fi
        if initrd_contains_i2c_hid; then say "i2c_hid_present_in_initramfs=true"; else say "i2c_hid_present_in_initramfs=false"; fi
    fi
}

case "$ACTION" in
    build) build_fix ;;
    install) install_fix ;;
    status) status_fix ;;
    *) die "usage: $0 {build|install|status}" ;;
esac
