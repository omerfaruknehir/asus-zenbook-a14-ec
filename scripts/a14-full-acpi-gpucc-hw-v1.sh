#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# First real X1E80100 GPU clock/power layer for A14 ACPI.
# Builds/installs only clk-qcom.ko + gpucc-x1e80100.ko.
set -euo pipefail

ACTION="${1:-status}"
KREL="7.1.5-a14-acpi-full0"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="${A14_74C9_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="$WORK/linux-7.1.5"
OUT="$WORK/build"
TRANSFORM="$ROOT/scripts/apply-a14-full-acpi-gpucc-hw-v1.py"
CLK_QCOM_KO="$OUT/drivers/clk/qcom/clk-qcom.ko"
GPUCC_KO="$OUT/drivers/clk/qcom/gpucc-x1e80100.ko"
STAMP="$WORK/gpucc-hw-v1.ready"
INITRD="/boot/initrd.img-$KREL"
INITRD_BACKUP="/boot/initrd.img-$KREL.pre-gpucc-hw-v1"
BACKUP_SUFFIX=".pre-gpucc-hw-v1"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_user(){ [[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as normal user"; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "install/restore requires sudo/root"; }

verify_tree(){
    [[ -f "$SRC/Makefile" && -f "$OUT/.config" && -s "$OUT/vmlinux" ]] || die "A14 kernel build tree missing"
    export LOCALVERSION=
    local actual
    actual="$(make -s -C "$SRC" O="$OUT" kernelrelease)"
    [[ "$actual" == "$KREL" ]] || die "kernelrelease mismatch: $actual"

    grep -q '^CONFIG_COMMON_CLK_QCOM=m$' "$OUT/.config" || die "this helper expects CONFIG_COMMON_CLK_QCOM=m"
    grep -q '^CONFIG_CLK_X1E80100_GPUCC=m$' "$OUT/.config" || die "this helper expects CONFIG_CLK_X1E80100_GPUCC=m"
    grep -q '^CONFIG_QCOM_GDSC=y$' "$OUT/.config" || grep -q '^CONFIG_QCOM_GDSC=m$' "$OUT/.config" || die "QCOM_GDSC required"
    grep -q '^CONFIG_MODULE_ALLOW_BTF_MISMATCH=y$' "$OUT/.config" || die "BTF compatibility prerequisite missing"

    # Preserve every already-proven prerequisite.
    grep -q 'A14_QCOM0C36_PLATFORM_ENUM_V1' "$SRC/drivers/acpi/scan.c" || die "GPU0 ACPI enumeration missing"
    grep -q 'A14_IORT_NCOMP_NO_TRAILING_V1' "$SRC/drivers/acpi/arm64/iort.c" || die "IORT path fix missing"
    grep -q 'A14_IORT_NCOMP_MULTI_ID_INIT_ONCE_V1' "$SRC/drivers/acpi/arm64/iort.c" || die "IORT multi-ID fix missing"
    grep -q 'A14_QCOM0C36_TOPOLOGY_V3' "$SRC/drivers/gpu/drm/msm/msm_drv.c" || die "working no-MMIO topology missing"
    grep -q 'A14_GIO0_SAFE_REGISTRATION_V1' "$SRC/drivers/pinctrl/qcom/pinctrl-msm.c" || die "working GIO0 fix missing"
    grep -q 'A14_QCOM_WOA_ACPI_GPIO_XLATE' "$SRC/drivers/gpio/gpiolib-acpi-core.c" || die "working keyboard GPIO translator missing"
    grep -q 'A14_QCOM_SCM_ACPI_QCOM04DD' "$SRC/drivers/firmware/qcom/qcom_scm.c" || die "working SCM fix missing"
}

verify_source(){
    grep -q 'A14_X1E80100_GPUCC_ACPI_HW_V1' "$SRC/drivers/clk/qcom/gpucc-x1e80100.c" || die "GPUCC ACPI hardware marker missing"
    grep -q 'A14_QCOM_CC_NON_OF_PROVIDER_V1' "$SRC/drivers/clk/qcom/common.c" || die "qcom common no-OF marker missing"
    grep -q 'A14_GDSC_NON_OF_PROVIDER_V1' "$SRC/drivers/clk/qcom/gdsc.c" || die "GDSC no-OF marker missing"
    grep -q '0x00152000ULL' "$SRC/drivers/clk/qcom/gpucc-x1e80100.c" || die "GCC GPU gate physical address missing"
    grep -q 'a14-gpucc-x1e80100-acpi-topology' "$SRC/drivers/clk/qcom/gpucc-x1e80100.c" || die "platform alias source missing"
}

build_fix(){
    need_user
    for c in python3 make grep sha256sum nproc modinfo; do need "$c"; done
    verify_tree
    [[ -f "$TRANSFORM" ]] || die "missing transform: $TRANSFORM"

    say "A14_GPUCC_HW_V1_BUILD=START"
    say "layer=first_real_gpu_clock_power_mmio"
    say "gpucc_mmio=0x03d90000+0xa000"
    say "gcc_gpu_gate_mmio=0x00152000_bits_15_16"
    say "parent_rates=19.2MHz_600MHz_300MHz"
    say "build_modules=clk-qcom.ko,gpucc-x1e80100.ko"
    say "image_rebuild=false"
    say "msm_module_rebuild=false"
    say "i2c_hid_module_rebuild=false"
    say "gmu_binding=false"
    say "adreno_binding=false"

    rm -f "$STAMP"
    python3 "$TRANSFORM" "$SRC"
    python3 "$TRANSFORM" "$SRC"
    verify_source

    export LOCALVERSION=
    make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" \
        drivers/clk/qcom/clk-qcom.ko \
        drivers/clk/qcom/gpucc-x1e80100.ko

    [[ -s "$CLK_QCOM_KO" && -s "$GPUCC_KO" ]] || die "target modules missing after build"
    grep -aFq 'A14QCOMCC: non-OF clock registration' "$CLK_QCOM_KO" || die "compiled clk-qcom lacks no-OF path"
    grep -aFq 'A14GDSC: initialized' "$CLK_QCOM_KO" || die "compiled clk-qcom lacks GDSC no-OF path"
    grep -aFq 'A14GPUCC: parent bridge READY' "$GPUCC_KO" || die "compiled gpucc lacks parent bridge"
    grep -aFq 'A14GPUCC: READY' "$GPUCC_KO" || die "compiled gpucc lacks READY marker"
    modinfo "$GPUCC_KO" | grep -Fq 'alias:          platform:a14-gpucc-x1e80100-acpi-topology' || \
        modinfo "$GPUCC_KO" | grep -Fq 'platform:a14-gpucc-x1e80100-acpi-topology' || \
        die "compiled gpucc lacks platform alias"

    local clk_sha gpucc_sha
    clk_sha="$(sha256sum "$CLK_QCOM_KO" | awk '{print $1}')"
    gpucc_sha="$(sha256sum "$GPUCC_KO" | awk '{print $1}')"
    cat >"$STAMP" <<EOF
kernelrelease=$KREL
clk_qcom_sha256=$clk_sha
gpucc_sha256=$gpucc_sha
module_targets=2
image_rebuild=no
msm_module_rebuild=no
i2c_hid_module_rebuild=no
gmu_binding=no
adreno_binding=no
EOF

    say "A14_GPUCC_HW_V1_BUILD=COMPLETE"
    say "clk_qcom_sha256=$clk_sha"
    say "gpucc_sha256=$gpucc_sha"
    say "compiled_platform_alias=VERIFIED"
    say "compiled_non_of_qcom_cc=VERIFIED"
    say "compiled_non_of_gdsc=VERIFIED"
    say "full_module_rebuild=false"
}

module_path(){
    local name="$1" p
    p="$(modinfo -k "$KREL" -n "$name" 2>/dev/null || true)"
    [[ -n "$p" && "$p" == /* ]] || die "cannot resolve installed $name for $KREL"
    readlink -f "$p"
}

install_compressed_like(){
    local src="$1" dst="$2" tmp
    tmp="${dst}.a14tmp.$$"
    rm -f "$tmp"
    case "$dst" in
        *.zst)
            need zstd
            zstd -q -f -c "$src" >"$tmp"
            ;;
        *.xz)
            need xz
            xz -c "$src" >"$tmp"
            ;;
        *.gz)
            need gzip
            gzip -c "$src" >"$tmp"
            ;;
        *.ko)
            cp "$src" "$tmp"
            ;;
        *) die "unsupported installed module compression: $dst" ;;
    esac
    chmod 0644 "$tmp"
    chown root:root "$tmp"
    mv -f "$tmp" "$dst"
}

uncompressed_sha(){
    local p="$1"
    case "$p" in
        *.zst) zstd -q -d -c "$p" | sha256sum | awk '{print $1}' ;;
        *.xz) xz -d -c "$p" | sha256sum | awk '{print $1}' ;;
        *.gz) gzip -d -c "$p" | sha256sum | awk '{print $1}' ;;
        *.ko) sha256sum "$p" | awk '{print $1}' ;;
        *) die "unsupported module compression: $p" ;;
    esac
}

install_fix(){
    need_root
    for c in modinfo depmod update-initramfs sha256sum awk cp readlink; do need "$c"; done
    [[ "$(uname -r)" != "$KREL" ]] || die "boot the normal DT kernel before replacing ACPI GPUCC modules"
    verify_tree
    verify_source
    [[ -r "$STAMP" ]] || die "successful GPUCC build stamp missing"
    [[ -s "$CLK_QCOM_KO" && -s "$GPUCC_KO" ]] || die "built modules missing"

    local clk_expected gpucc_expected clk_actual gpucc_actual clk_dst gpucc_dst
    clk_expected="$(awk -F= '$1=="clk_qcom_sha256"{print $2}' "$STAMP")"
    gpucc_expected="$(awk -F= '$1=="gpucc_sha256"{print $2}' "$STAMP")"
    clk_actual="$(sha256sum "$CLK_QCOM_KO" | awk '{print $1}')"
    gpucc_actual="$(sha256sum "$GPUCC_KO" | awk '{print $1}')"
    [[ "$clk_expected" == "$clk_actual" ]] || die "clk-qcom changed since verified build"
    [[ "$gpucc_expected" == "$gpucc_actual" ]] || die "gpucc changed since verified build"

    clk_dst="$(module_path clk_qcom)"
    gpucc_dst="$(module_path gpucc_x1e80100)"
    [[ -s "$clk_dst" && -s "$gpucc_dst" ]] || die "installed module path missing"

    [[ -e "${clk_dst}${BACKUP_SUFFIX}" ]] || cp -a "$clk_dst" "${clk_dst}${BACKUP_SUFFIX}"
    [[ -e "${gpucc_dst}${BACKUP_SUFFIX}" ]] || cp -a "$gpucc_dst" "${gpucc_dst}${BACKUP_SUFFIX}"
    [[ ! -s "$INITRD" || -e "$INITRD_BACKUP" ]] || cp -a "$INITRD" "$INITRD_BACKUP"

    install_compressed_like "$CLK_QCOM_KO" "$clk_dst"
    install_compressed_like "$GPUCC_KO" "$gpucc_dst"

    [[ "$(uncompressed_sha "$clk_dst")" == "$clk_expected" ]] || die "installed clk-qcom verification failed"
    [[ "$(uncompressed_sha "$gpucc_dst")" == "$gpucc_expected" ]] || die "installed gpucc verification failed"

    depmod "$KREL"
    update-initramfs -u -k "$KREL"

    say "A14_GPUCC_HW_V1_INSTALL=COMPLETE"
    say "installed_clk_qcom=$clk_dst"
    say "installed_gpucc=$gpucc_dst"
    say "clk_qcom_source_sha256=$clk_expected"
    say "gpucc_source_sha256=$gpucc_expected"
    say "previous_clk_qcom=${clk_dst}${BACKUP_SUFFIX}"
    say "previous_gpucc=${gpucc_dst}${BACKUP_SUFFIX}"
    say "previous_initramfs=$INITRD_BACKUP"
    say "depmod_updated=true"
    say "initramfs_updated=true"
    say "kernel_image_unchanged=true"
    say "msm_module_unchanged=true"
    say "i2c_hid_module_unchanged=true"
    say "grub_unchanged=true"
}

restore_fix(){
    need_root
    for c in modinfo depmod cp readlink; do need "$c"; done
    [[ "$(uname -r)" != "$KREL" ]] || die "boot the normal DT kernel before restore"
    local clk_dst gpucc_dst
    clk_dst="$(module_path clk_qcom)"
    gpucc_dst="$(module_path gpucc_x1e80100)"
    [[ -s "${clk_dst}${BACKUP_SUFFIX}" ]] || die "clk-qcom backup missing"
    [[ -s "${gpucc_dst}${BACKUP_SUFFIX}" ]] || die "gpucc backup missing"
    cp -a "${clk_dst}${BACKUP_SUFFIX}" "$clk_dst"
    cp -a "${gpucc_dst}${BACKUP_SUFFIX}" "$gpucc_dst"
    if [[ -s "$INITRD_BACKUP" ]]; then
        cp -a "$INITRD_BACKUP" "$INITRD"
    fi
    depmod "$KREL"
    say "A14_GPUCC_HW_V1_RESTORE=COMPLETE"
    say "kernel_image_unchanged=true"
}

status_fix(){
    say "running_kernel=$(uname -r)"
    say "work=$WORK"
    [[ -r "$STAMP" ]] && { say "--- GPUCC HW V1 stamp ---"; cat "$STAMP"; }
    [[ -s "$INITRD_BACKUP" ]] && say "pre_gpucc_initramfs=$INITRD_BACKUP"
}

case "$ACTION" in
    build) build_fix ;;
    install) install_fix ;;
    restore) restore_fix ;;
    status) status_fix ;;
    *) die "usage: $0 {build|install|restore|status}" ;;
esac
