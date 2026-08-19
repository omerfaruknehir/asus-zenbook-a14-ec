#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Second-stage A/B diagnostic on the recovered 74c9bd5 ACPI kernel.
# Keeps the V1 functional change (GIO0 ACPI IDs only) and adds detailed
# gpiochip substage + per-GPIO TLMM control-register read tracing.
set -euo pipefail

ACTION="${1:-status}"
KREL="7.1.5-a14-acpi-full0"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="${A14_74C9_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="$WORK/linux-7.1.5"
OUT="$WORK/build"
IMAGE="$OUT/arch/arm64/boot/Image"
STAMP="$WORK/74c9-gio0-probe-v2.ready"
TRANSFORM_V1="$ROOT/scripts/apply-a14-74c9-gio0-probe.py"
TRANSFORM_V2="$ROOT/scripts/apply-a14-74c9-gio0-probe-v2.py"
KERNEL="/boot/vmlinuz-$KREL"
CONFIG="/boot/config-$KREL"
SYSTEM_MAP="/boot/System.map-$KREL"
BACKUP_KERNEL="/boot/vmlinuz-$KREL.pre-gio0-probe-v2"
BACKUP_CONFIG="/boot/config-$KREL.pre-gio0-probe-v2"
BACKUP_MAP="/boot/System.map-$KREL.pre-gio0-probe-v2"
GRUB_SNIPPET="/etc/grub.d/41_a14_full_acpi_checkpoint"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_user(){ [[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as normal user, not root"; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "install/restore requires sudo/root"; }

verify_baseline_tree(){
    [[ -f "$SRC/Makefile" && -f "$OUT/.config" && -s "$OUT/vmlinux" ]] || die "recovered 74c9 build tree missing"
    grep -q '^CONFIG_MODULE_ALLOW_BTF_MISMATCH=y$' "$OUT/.config" || die "BTF compatibility baseline is not enabled"
    grep -q 'A14 ACPI: wrapperless GENI SE, TX FIFO depth' "$SRC/drivers/i2c/busses/i2c-qcom-geni.c" || die "74c9 wrapperless GENI marker missing"
    grep -q 'a14_iort_pcie_smmuv3_firmware_owned' "$SRC/drivers/acpi/arm64/iort.c" || die "74c9 PCIe SMMUv3 ownership patch missing"
    grep -q 'a14_acpi_trace_delay_ms' "$SRC/drivers/acpi/bus.c" || die "74c9 trace-delay patch missing"
    grep -q 'smmu-reset-after-scr0-write' "$SRC/drivers/iommu/arm/arm-smmu/arm-smmu.c" || die "74c9 SMMU checkpoint patch missing"
    ! grep -q 'A14_QCOM_WOA_ACPI_GPIO_XLATE' "$SRC/drivers/gpio/gpiolib-acpi-core.c" || die "later virtual GPIO translation contamination detected"
    ! grep -q 'A14_ACPI_SCAN_TRACE_V' "$SRC/drivers/acpi/scan.c" || die "later namespace trace contamination detected"
}

verify_grub(){
    [[ -f "$GRUB_SNIPPET" ]] || die "74c9 GRUB snippet missing"
    line="$(awk '/^menuentry .*ACPI-ONLY UNRESTRICTED/{seen=1} seen && /^[[:space:]]*linux[[:space:]]/{print; exit}' "$GRUB_SNIPPET")"
    [[ -n "$line" ]] || die "74c9 GRUB linux line missing"
    for x in 'earlycon=efifb,ram' 'console=tty0' 'loglevel=8' 'ignore_loglevel' 'printk.time=1' 'acpi=force'; do
        grep -Fq "$x" <<<"$line" || die "GRUB line lacks $x"
    done
    for x in 'keep_bootcon' 'initcall_debug' 'a14_acpi_halt=' 'a14_device_halt_after='; do
        ! grep -Fq "$x" <<<"$line" || die "GRUB line contains forbidden diagnostic arg $x"
    done
    ! grep -qE '^[[:space:]]*devicetree[[:space:]]' "$GRUB_SNIPPET" || die "GRUB entry unexpectedly loads DTB"
    say "A14_74C9_COMMANDLINE=VERIFIED"
}

v2_already_applied(){
    local msm="$SRC/drivers/pinctrl/qcom/pinctrl-msm.c"
    local gpio="$SRC/drivers/gpio/gpiolib.c"
    grep -Fq 'A14_GIO0_PROBE_TRACE_V2' "$msm" &&
    grep -Fq 'A14GIO0DIR: before gpio=' "$msm" &&
    grep -Fq 'A14GIO0DIR: after gpio=' "$msm" &&
    grep -Fq 'A14_GIO0_PROBE_TRACE_V2' "$gpio" &&
    grep -Fq 'A14GIO0V2: before-valid-mask' "$gpio" &&
    grep -Fq 'A14GIO0V2: direction-scan-before' "$gpio" &&
    grep -Fq 'A14GIO0V2: direction-scan-after' "$gpio" &&
    grep -Fq 'A14GIO0V2: before-acpi-gpiochip-add' "$gpio" &&
    grep -Fq 'A14GIO0V2: before-add-irqchip' "$gpio" &&
    grep -Fq 'A14GIO0V2: gpiochip-success' "$gpio"
}

verify_probe_source(){
    x1="$SRC/drivers/pinctrl/qcom/pinctrl-x1e80100.c"
    msm="$SRC/drivers/pinctrl/qcom/pinctrl-msm.c"
    gpio="$SRC/drivers/gpio/gpiolib.c"
    table="$(awk '/x1e80100_pinctrl_acpi_match\[\]/{f=1} f{print} f && /^};/{exit}' "$x1")"
    grep -Fq 'QCOM0C0C' <<<"$table" || die "GIO0 HID missing from TLMM match table"
    grep -Fq 'QCOMFFEB' <<<"$table" || die "GIO0 CID missing from TLMM match table"
    ! grep -Fq 'QCOM0C0D' <<<"$table" || die "IPC0 HID still present in TLMM match table"
    grep -Fq 'A14_GIO0_PROBE_TRACE_V1' "$msm" || die "V1 GIO0 probe trace missing"
    grep -Fq 'A14_GIO0_PROBE_TRACE_V2' "$msm" || die "V2 per-read trace missing from pinctrl-msm.c"
    grep -Fq 'A14GIO0DIR: before gpio=' "$msm" || die "V2 before-read marker missing"
    grep -Fq 'A14GIO0DIR: after gpio=' "$msm" || die "V2 after-read marker missing"
    grep -Fq 'A14_GIO0_PROBE_TRACE_V2' "$gpio" || die "V2 gpiolib stage trace missing"
    grep -Fq 'A14GIO0V2: direction-scan-before' "$gpio" || die "V2 direction scan marker missing"
    grep -Fq 'A14GIO0V2: before-acpi-gpiochip-add' "$gpio" || die "V2 ACPI gpiochip marker missing"
}

build_probe(){
    need_user
    for c in python3 make sha256sum grep; do need "$c"; done
    verify_baseline_tree
    [[ -f "$TRANSFORM_V1" ]] || die "missing V1 transform: $TRANSFORM_V1"
    [[ -f "$TRANSFORM_V2" ]] || die "missing V2 transform: $TRANSFORM_V2"

    say "A14_74C9_GIO0_PROBE_V2_BUILD=START"
    say "functional_change=GIO0_ACPI_ID_binding_only_same_as_V1"
    say "virtual_gpio_translation=false"
    say "trace_scope=QCOM0C0C:00_only"
    say "direction_mmio_trace=before_and_after_each_gpio_0_to_238"
    say "gpiochip_substage_trace=true"
    say "full_module_rebuild=false"
    say "grub_unchanged=true"
    say "initramfs_unchanged=true"

    # V1 is idempotent. Running it first makes this work whether the local
    # recovered tree is pristine 74c9 or already contains the first GIO0 test.
    python3 "$TRANSFORM_V1" "$SRC"
    if v2_already_applied; then
        say "A14_GIO0_PROBE_TRACE_V2=current"
    else
        python3 "$TRANSFORM_V2" "$SRC"
    fi
    verify_probe_source

    # Force every source touched by V1/V2 stale. In particular, gpiolib.o is
    # new in V2 and must not be reused from the prior Image.
    rm -f \
      "$OUT/drivers/pinctrl/qcom/pinctrl-x1e80100.o" \
      "$OUT/drivers/pinctrl/qcom/.pinctrl-x1e80100.o.cmd" \
      "$OUT/drivers/pinctrl/qcom/pinctrl-msm.o" \
      "$OUT/drivers/pinctrl/qcom/.pinctrl-msm.o.cmd" \
      "$OUT/drivers/gpio/gpiolib.o" \
      "$OUT/drivers/gpio/.gpiolib.o.cmd"

    export LOCALVERSION=
    [[ "$(make -s -C "$SRC" O="$OUT" kernelrelease)" == "$KREL" ]] || die "kernelrelease mismatch"
    make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" Image

    obj_x1="$OUT/drivers/pinctrl/qcom/pinctrl-x1e80100.o"
    obj_msm="$OUT/drivers/pinctrl/qcom/pinctrl-msm.o"
    obj_gpio="$OUT/drivers/gpio/gpiolib.o"
    [[ -s "$IMAGE" && -s "$obj_x1" && -s "$obj_msm" && -s "$obj_gpio" ]] || die "rebuilt Image/trace objects missing"
    grep -aFq 'QCOM0C0C' "$obj_x1" || die "rebuilt X1E object lacks QCOM0C0C"
    grep -aFq 'QCOMFFEB' "$obj_x1" || die "rebuilt X1E object lacks QCOMFFEB"
    ! grep -aFq 'QCOM0C0D' "$obj_x1" || die "rebuilt X1E object still contains QCOM0C0D"
    grep -aFq 'A14_GIO0_PROBE_TRACE_V2' "$obj_msm" || die "rebuilt msm object lacks V2 marker"
    grep -aFq 'A14GIO0DIR: before gpio=' "$obj_msm" || die "rebuilt msm object lacks per-read before marker"
    grep -aFq 'A14GIO0DIR: after gpio=' "$obj_msm" || die "rebuilt msm object lacks per-read after marker"
    grep -aFq 'A14_GIO0_PROBE_TRACE_V2' "$obj_gpio" || die "rebuilt gpiolib object lacks V2 marker"
    grep -aFq 'A14GIO0V2: before-valid-mask' "$obj_gpio" || die "rebuilt gpiolib object lacks substage markers"
    grep -q '^CONFIG_MODULE_ALLOW_BTF_MISMATCH=y$' "$OUT/.config" || die "BTF compatibility was lost"

    sha="$(sha256sum "$IMAGE" | awk '{print $1}')"
    cat >"$STAMP" <<EOF
kernelrelease=$KREL
image_sha256=$sha
gio0_ids=QCOM0C0C,QCOMFFEB
ipc0_match=no
virtual_gpio_translation=no
probe_trace=v2
direction_mmio_trace=before_after_0_238
gpiochip_substage_trace=yes
module_allow_btf_mismatch=yes
EOF
    say "A14_74C9_GIO0_PROBE_V2_BUILD=COMPLETE"
    say "image=$IMAGE"
    say "sha256=$sha"
    say "object_verification=V2_VERIFIED"
}

install_probe(){
    need_root
    for c in install sha256sum; do need "$c"; done
    [[ "$(uname -r)" != "$KREL" ]] || die "boot the normal DT kernel before replacing the ACPI test Image"
    verify_baseline_tree
    verify_probe_source
    verify_grub
    [[ -r "$STAMP" ]] || die "successful GIO0 V2 build stamp missing"

    expected="$(awk -F= '$1=="image_sha256"{print $2}' "$STAMP")"
    actual="$(sha256sum "$IMAGE" | awk '{print $1}')"
    [[ -n "$expected" && "$expected" == "$actual" ]] || die "Image changed since verified V2 build"

    [[ -e "$BACKUP_KERNEL" ]] || cp -a "$KERNEL" "$BACKUP_KERNEL"
    [[ ! -s "$CONFIG" || -e "$BACKUP_CONFIG" ]] || cp -a "$CONFIG" "$BACKUP_CONFIG"
    [[ ! -s "$SYSTEM_MAP" || -e "$BACKUP_MAP" ]] || cp -a "$SYSTEM_MAP" "$BACKUP_MAP"

    install -m0644 "$IMAGE" "$KERNEL"
    install -m0644 "$OUT/.config" "$CONFIG"
    [[ ! -s "$OUT/System.map" ]] || install -m0644 "$OUT/System.map" "$SYSTEM_MAP"
    cmp -s "$IMAGE" "$KERNEL" || die "installed V2 Image mismatch"
    verify_grub

    say "A14_74C9_GIO0_PROBE_V2_INSTALL=COMPLETE"
    say "installed_sha256=$expected"
    say "installed_image_matches_build=true"
    say "modules_unchanged=true"
    say "initramfs_unchanged=true"
    say "grub_unchanged=true"
    say "restore_command=sudo bash scripts/a14-full-acpi-74c9-gio0-probe-v2.sh restore"
}

restore_previous(){
    need_root
    [[ "$(uname -r)" != "$KREL" ]] || die "boot the normal DT kernel before restoring the previous ACPI Image"
    [[ -s "$BACKUP_KERNEL" ]] || die "V2 pre-install backup not found: $BACKUP_KERNEL"
    cp -a "$BACKUP_KERNEL" "$KERNEL"
    [[ ! -s "$BACKUP_CONFIG" ]] || cp -a "$BACKUP_CONFIG" "$CONFIG"
    [[ ! -s "$BACKUP_MAP" ]] || cp -a "$BACKUP_MAP" "$SYSTEM_MAP"
    verify_grub
    say "A14_74C9_GIO0_PROBE_V2_RESTORE=COMPLETE"
    say "previous_kernel_restored=$KERNEL"
}

status(){
    say "running_kernel=$(uname -r)"
    say "work=$WORK"
    [[ -f "$OUT/.config" ]] && grep -E '^CONFIG_(MODULE_ALLOW_BTF_MISMATCH|DEBUG_INFO_BTF_MODULES)=' "$OUT/.config" || true
    [[ -r "$STAMP" ]] && { say "--- V2 probe stamp ---"; cat "$STAMP"; }
    [[ -s "$BACKUP_KERNEL" ]] && say "v2_preinstall_backup=$BACKUP_KERNEL"
    df -h "$OWNER_HOME" 2>/dev/null || true
}

case "$ACTION" in
    build) build_probe ;;
    install) install_probe ;;
    restore) restore_previous ;;
    status) status ;;
    *) die "usage: $0 {build|install|restore|status}" ;;
esac
