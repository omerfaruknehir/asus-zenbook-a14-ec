#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Finalize an already-successful historical ACPI image after the outer
# reproducer's LOCALVERSION verification bug. This does not rebuild anything.
set -euo pipefail

KREL="7.1.5-a14-acpi-full0"
GOOD_COMMIT="74c9bd5ebc77e2563b8be50d8cb4af67202c71fe"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
WORK="${A14_74C9_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="$WORK/linux-7.1.5"
OUT="$WORK/build"
IMAGE="$OUT/arch/arm64/boot/Image"
INNER_STAMP="$WORK/checkpoint-build.ready"
FINAL_STAMP="$WORK/74c9bd5-build.ready"

die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
say(){ printf '%s\n' "$*"; }

[[ ${EUID:-$(id -u)} -ne 0 ]] || die "run as your normal user, not root"
for c in make sha256sum awk grep; do command -v "$c" >/dev/null 2>&1 || die "missing command: $c"; done
[[ -f "$SRC/Makefile" ]] || die "source tree missing: $SRC"
[[ -f "$OUT/.config" ]] || die "build config missing: $OUT/.config"
[[ -s "$IMAGE" ]] || die "built Image missing: $IMAGE"
[[ -s "$OUT/vmlinux" ]] || die "built vmlinux missing: $OUT/vmlinux"
[[ -r "$INNER_STAMP" ]] || die "inner successful-build stamp missing: $INNER_STAMP"

# The nested historical build exports LOCALVERSION= before olddefconfig,
# kernelrelease verification, and Image compilation. Reproduce that exact
# environment here. The old outer verifier omitted this assignment.
plain_release="$(make -s -C "$SRC" O="$OUT" kernelrelease 2>/dev/null || true)"
exact_release="$(LOCALVERSION= make -s -C "$SRC" O="$OUT" kernelrelease)"
say "kernelrelease_without_explicit_LOCALVERSION=${plain_release:-unavailable}"
say "kernelrelease_with_LOCALVERSION_empty=$exact_release"
[[ "$exact_release" == "$KREL" ]] || die "exact build environment kernelrelease mismatch: got '$exact_release', expected '$KREL'"

image_sha="$(sha256sum "$IMAGE" | awk '{print $1}')"
inner_krel="$(awk -F= '$1 == "kernelrelease" {print $2}' "$INNER_STAMP")"
inner_sha="$(awk -F= '$1 == "image_sha256" {print $2}' "$INNER_STAMP")"
[[ "$inner_krel" == "$KREL" ]] || die "inner build stamp kernelrelease mismatch: ${inner_krel:-missing}"
[[ -n "$inner_sha" && "$inner_sha" == "$image_sha" ]] || die "Image no longer matches inner successful-build stamp"

# Verify the final semantic markers that the pinned reproducer checks after the
# historical wrapperless/SMMU chain. This prevents finalizing an unrelated Image.
grep -q 'A14 ACPI: wrapperless GENI SE, TX FIFO depth' "$SRC/drivers/i2c/busses/i2c-qcom-geni.c" || die "wrapperless GENI marker missing"
grep -q 'a14_iort_pcie_smmuv3_firmware_owned' "$SRC/drivers/acpi/arm64/iort.c" || die "PCIe SMMUv3 ownership quirk missing"
grep -q 'a14_acpi_trace_delay_ms' "$SRC/drivers/acpi/bus.c" || die "trace-delay patch missing"
grep -q 'smmu-reset-after-scr0-write' "$SRC/drivers/iommu/arm/arm-smmu/arm-smmu.c" || die "SMMU reset checkpoints missing"
! grep -q 'A14_QCOM_WOA_ACPI_GPIO_XLATE' "$SRC/drivers/gpio/gpiolib-acpi-core.c" || die "later WoA GPIO experiment contaminated source"
! grep -q 'A14_ACPI_SCAN_TRACE_V' "$SRC/drivers/acpi/scan.c" || die "later ACPI scan experiment contaminated source"

cat >"$FINAL_STAMP" <<EOF
repo_commit=$GOOD_COMMIT
kernelrelease=$KREL
image_sha256=$image_sha
build_mode=in-place-image-only
historical_prerequisite=base-checkpoints-from-74c9bd5
historical_cmdline=earlycon=efifb,ram console=tty0 loglevel=8 ignore_loglevel printk.time=1 acpi=force
finalized_from_existing_inner_stamp=$INNER_STAMP
outer_localversion_bug_workaround=yes
EOF

say "A14_ACPI_V2_FINALIZE_EXISTING=PASS"
say "kernelrelease=$exact_release"
say "image=$IMAGE"
say "image_sha256=$image_sha"
say "inner_stamp=$INNER_STAMP"
say "final_stamp=$FINAL_STAMP"
say "rebuild_performed=false"
