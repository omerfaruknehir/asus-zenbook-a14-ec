#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Validate and adopt an already-completed 74c9bd5 historical Image when the
# outer restore helper failed only at its post-build kernelrelease verifier.
set -euo pipefail

GOOD_COMMIT="74c9bd5ebc77e2563b8be50d8cb4af67202c71fe"
KREL="7.1.5-a14-acpi-full0"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
WORK="${A14_74C9_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="$WORK/linux-7.1.5"
OUT="$WORK/build"
STAMP="$WORK/74c9bd5-build.ready"
CHECKPOINT_STAMP="$WORK/checkpoint-build.ready"
IMAGE="$OUT/arch/arm64/boot/Image"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -ne 0 ]] || die "run as normal user, not root"

[[ -f "$SRC/Makefile" ]] || die "missing historical source tree: $SRC"
[[ -f "$OUT/.config" ]] || die "missing historical build config: $OUT/.config"
[[ -s "$IMAGE" ]] || die "missing completed Image: $IMAGE"
[[ -s "$OUT/vmlinux" ]] || die "missing completed vmlinux"
[[ -r "$CHECKPOINT_STAMP" ]] || die "missing historical checkpoint build stamp: $CHECKPOINT_STAMP"

# Source provenance: exact characteristic state from the 74c9 historical chain.
grep -q 'A14 ACPI: wrapperless GENI SE, TX FIFO depth' "$SRC/drivers/i2c/busses/i2c-qcom-geni.c" || die "wrapperless GENI marker missing"
grep -q 'a14_iort_pcie_smmuv3_firmware_owned' "$SRC/drivers/acpi/arm64/iort.c" || die "historical PCIe SMMUv3 ownership patch missing"
grep -q 'a14_acpi_trace_delay_ms' "$SRC/drivers/acpi/bus.c" || die "historical trace-delay patch missing"
grep -q 'smmu-reset-after-scr0-write' "$SRC/drivers/iommu/arm/arm-smmu/arm-smmu.c" || die "historical SMMU reset checkpoints missing"
grep -q 'void a14_acpi_checkpoint(const char \*stage);' "$SRC/include/linux/a14_full_acpi.h" || die "historical base checkpoints missing"
! grep -q 'A14_QCOM_WOA_ACPI_GPIO_XLATE' "$SRC/drivers/gpio/gpiolib-acpi-core.c" || die "later WoA GPIO translation contaminated source"
! grep -q 'A14_ACPI_SCAN_TRACE_V' "$SRC/drivers/acpi/scan.c" || die "later scan tracer contaminated source"

# Release provenance. Historical scripts deliberately export LOCALVERSION= before
# invoking Kbuild. Reproduce that exact environment instead of inheriting an
# unrelated shell LOCALVERSION value.
config_localversion="$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"$/\1/p' "$OUT/.config" | head -n1)"
[[ "$config_localversion" == '-a14-acpi-full0' ]] || die "unexpected CONFIG_LOCALVERSION: ${config_localversion:-missing}"
! grep -q '^CONFIG_LOCALVERSION_AUTO=y$' "$OUT/.config" || die "CONFIG_LOCALVERSION_AUTO unexpectedly enabled"

make_krel="$(env LOCALVERSION= make -s -C "$SRC" O="$OUT" kernelrelease)"
[[ "$make_krel" == "$KREL" ]] || die "kernelrelease still mismatches with LOCALVERSION cleared: $make_krel"

[[ -r "$OUT/include/config/kernel.release" ]] || die "generated kernel.release missing"
generated_krel="$(cat "$OUT/include/config/kernel.release")"
[[ "$generated_krel" == "$KREL" ]] || die "generated kernel.release mismatch: $generated_krel"

grep -Fq "#define UTS_RELEASE \"$KREL\"" "$OUT/include/generated/utsrelease.h" || die "UTS_RELEASE mismatch"

image_sha="$(sha256sum "$IMAGE" | awk '{print $1}')"
checkpoint_sha="$(awk -F= '$1 == "image_sha256" {print $2}' "$CHECKPOINT_STAMP" | tail -n1)"
checkpoint_krel="$(awk -F= '$1 == "kernelrelease" {print $2}' "$CHECKPOINT_STAMP" | tail -n1)"
[[ "$checkpoint_krel" == "$KREL" ]] || die "checkpoint stamp kernelrelease mismatch: ${checkpoint_krel:-missing}"
[[ -n "$checkpoint_sha" && "$checkpoint_sha" == "$image_sha" ]] || die "Image no longer matches successful historical checkpoint build stamp"

cat >"$STAMP" <<EOF
repo_commit=$GOOD_COMMIT
kernelrelease=$KREL
image_sha256=$image_sha
build_mode=in-place-image-only-adopted
historical_prerequisite=base-checkpoints-from-74c9bd5
historical_cmdline=earlycon=efifb,ram console=tty0 loglevel=8 ignore_loglevel printk.time=1 acpi=force
EOF

say "A14_74C9_EXISTING_IMAGE=VERIFIED"
say "repo_commit=$GOOD_COMMIT"
say "kernelrelease=$KREL"
say "config_localversion=$config_localversion"
say "generated_kernelrelease=$generated_krel"
say "image=$IMAGE"
say "sha256=$image_sha"
say "checkpoint_stamp_match=true"
say "A14_74C9_BUILD=COMPLETE"
say "stamp=$STAMP"
