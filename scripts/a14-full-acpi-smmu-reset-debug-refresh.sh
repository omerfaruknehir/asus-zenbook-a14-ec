#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Apply the A14 QCOM SMMU ACPI revision fix, fine-grained SMMU reset
# checkpoints, and readable SMMU-only trace delay, then reuse the validated
# checkpoint refresh build/install pipeline.
set -euo pipefail

ACTION="${1:-build}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
WORK="${A14_FULL_ACPI_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="$WORK/linux-7.1.5"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

verify_source(){
    local bus="$SRC/drivers/acpi/bus.c"
    local smmu="$SRC/drivers/iommu/arm/arm-smmu/arm-smmu.c"
    local qcom="$SRC/drivers/iommu/arm/arm-smmu/arm-smmu-qcom.c"
    grep -q 'a14_acpi_trace_delay_ms' "$bus" || die "trace-delay source patch missing"
    grep -q '!strncmp(stage, "smmu-probe", 10)' "$bus" || die "SMMU-scoped probe trace delay missing"
    grep -q '!strncmp(stage, "smmu-reset-", 11)' "$bus" || die "SMMU-scoped reset trace delay missing"
    grep -q 'smmu-reset-after-contexts' "$smmu" || die "SMMU reset checkpoints missing"
    grep -q 'smmu-reset-before-scr0-write' "$smmu" || die "SMMU final-write checkpoint missing"
    grep -q 'smmu-reset-after-scr0-write' "$smmu" || die "SMMU final-write completion checkpoint missing"
    grep -q '{ "QCOM  ", "QCOMEDK2", 0x8380, ACPI_SIG_IORT, equal, "QCOM SMMU A14" }' "$qcom" || die "QCOMEDK2 0x8380 ACPI SMMU matcher missing"
}

case "$ACTION" in
    build)
        [[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as your normal user, not root"
        [[ -f "$SRC/Makefile" ]] || die "existing Linux 7.1.5 source tree missing: $SRC"
        # First bring the existing transforms to their current semantic state.
        python3 "$ROOT/scripts/apply-a14-full-acpi-trace-checkpoints.py" "$SRC"
        python3 "$ROOT/scripts/apply-a14-full-acpi-smmu-checkpoints.py" "$SRC"
        # Select Qualcomm's SMMU implementation for the A14's actual IORT
        # OEM revision instead of falling through to the generic ARM-SMMU path.
        python3 "$ROOT/scripts/apply-a14-full-acpi-smmu-qcom-8380.py" "$SRC"
        # Add readable SMMU-only breadcrumbs and reset-internal stages.
        python3 "$ROOT/scripts/apply-a14-full-acpi-trace-delay.py" "$SRC"
        python3 "$ROOT/scripts/apply-a14-full-acpi-smmu-reset-checkpoints.py" "$SRC"
        verify_source
        # The existing refresh script re-validates all older transforms, builds
        # the full Image, and writes a successful-image SHA stamp.
        bash "$ROOT/scripts/a14-full-acpi-checkpoint-refresh.sh" build
        verify_source
        say "A14_FULL_ACPI_SMMU_RESET_DEBUG_BUILD=COMPLETE"
        say "qcom_iort_8380_fix=yes"
        say "selected_acpi_smmu_impl=qcom_smmu_500_impl0_data"
        say "trace_delay_supported=yes"
        say "trace_delay_scope=smmu-probe-and-reset-only"
        say "smmu_reset_internal_checkpoints=yes"
        ;;
    install)
        [[ ${EUID:-$(id -u)} -eq 0 ]] || die "install requires sudo/root"
        verify_source
        bash "$ROOT/scripts/a14-full-acpi-checkpoint-refresh.sh" install
        say "A14_FULL_ACPI_SMMU_RESET_DEBUG_INSTALL=COMPLETE"
        say "qcom_iort_8380_fix=yes"
        say "selected_acpi_smmu_impl=qcom_smmu_500_impl0_data"
        say "trace_delay_supported=yes"
        say "trace_delay_scope=smmu-probe-and-reset-only"
        say "smmu_reset_internal_checkpoints=yes"
        ;;
    *)
        die "usage: $0 {build|install}"
        ;;
esac
