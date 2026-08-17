#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Apply the A14 QCOM SMMU ACPI revision fix, mirror X1's firmware-owned PCIe
# SMMUv3 rule at EL1, retain fine-grained SMMU reset checkpoints/readable
# SMMU-only traces, then reuse the validated checkpoint build/install pipeline.
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
    local iort="$SRC/drivers/acpi/arm64/iort.c"
    local smmu="$SRC/drivers/iommu/arm/arm-smmu/arm-smmu.c"
    local qcom="$SRC/drivers/iommu/arm/arm-smmu/arm-smmu-qcom.c"
    grep -q 'a14_acpi_trace_delay_ms' "$bus" || die "trace-delay source patch missing"
    grep -q '!strncmp(stage, "smmu-probe", 10)' "$bus" || die "SMMU-scoped probe trace delay missing"
    grep -q '!strncmp(stage, "smmu-reset-", 11)' "$bus" || die "SMMU-scoped reset trace delay missing"
    grep -q 'smmu-reset-after-contexts' "$smmu" || die "SMMU reset checkpoints missing"
    grep -q 'smmu-reset-before-scr0-write' "$smmu" || die "SMMU final-write checkpoint missing"
    grep -q 'smmu-reset-after-scr0-write' "$smmu" || die "SMMU final-write completion checkpoint missing"
    grep -q '{ "QCOM  ", "QCOMEDK2", 0x8380, ACPI_SIG_IORT, equal, "QCOM SMMU A14" }' "$qcom" || die "QCOMEDK2 0x8380 ACPI SMMU matcher missing"
    grep -q 'a14_iort_pcie_smmuv3_firmware_owned' "$iort" || die "PCIe SMMUv3 firmware-ownership quirk missing"
    grep -q 'iort_table->oem_id' "$iort" || die "PCIe SMMUv3 quirk lacks direct IORT header OEM ID guard"
    grep -q 'iort_table->oem_table_id' "$iort" || die "PCIe SMMUv3 quirk lacks direct IORT header table ID guard"
    grep -q 'iort_table->oem_revision != 0x8380' "$iort" || die "PCIe SMMUv3 quirk lacks exact OEM revision guard"
    ! grep -q 'header = &iort_table->header' "$iort" || die "obsolete embedded-header form remains in PCIe SMMUv3 quirk"
    grep -q 'smmu->base_address == 0x15400000' "$iort" || die "PCIe SMMUv3 quirk lacks exact base-address guard"
    grep -q 'is_kernel_in_hyp_mode()' "$iort" || die "PCIe SMMUv3 quirk lacks EL1/EL2 ownership guard"
    grep -q 'A14: leaving PCIe SMMUv3\[%llx\] firmware-owned at EL1' "$iort" || die "PCIe SMMUv3 ownership boot marker missing"
    grep -q 'continue;' "$iort" || die "PCIe SMMUv3 ownership skip lacks loop continue"
    ! grep -q 'goto next_iort_node;' "$iort" || die "obsolete goto-based PCIe SMMUv3 skip remains"
    ! grep -q '^next_iort_node:' "$iort" || die "obsolete PCIe SMMUv3 next-node label remains"
}

case "$ACTION" in
    build)
        [[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as your normal user, not root"
        [[ -f "$SRC/Makefile" ]] || die "existing Linux 7.1.5 source tree missing: $SRC"
        python3 "$ROOT/scripts/apply-a14-full-acpi-trace-checkpoints.py" "$SRC"
        python3 "$ROOT/scripts/apply-a14-full-acpi-smmu-checkpoints.py" "$SRC"
        python3 "$ROOT/scripts/apply-a14-full-acpi-smmu-qcom-8380.py" "$SRC"
        python3 "$ROOT/scripts/apply-a14-full-acpi-pcie-smmuv3-firmware-owned.py" "$SRC"
        python3 "$ROOT/scripts/apply-a14-full-acpi-trace-delay.py" "$SRC"
        python3 "$ROOT/scripts/apply-a14-full-acpi-smmu-reset-checkpoints.py" "$SRC"
        verify_source
        bash "$ROOT/scripts/a14-full-acpi-checkpoint-refresh.sh" build
        verify_source
        say "A14_FULL_ACPI_SMMU_RESET_DEBUG_BUILD=COMPLETE"
        say "qcom_iort_8380_fix=yes"
        say "selected_acpi_smmu_impl=qcom_smmu_500_impl0_data"
        say "pcie_smmuv3_15400000_el1=firmware-owned"
        say "pcie_smmuv3_15400000_el2=linux-owned-normal-iort"
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
        say "pcie_smmuv3_15400000_el1=firmware-owned"
        say "pcie_smmuv3_15400000_el2=linux-owned-normal-iort"
        say "trace_delay_supported=yes"
        say "trace_delay_scope=smmu-probe-and-reset-only"
        say "smmu_reset_internal_checkpoints=yes"
        ;;
    *)
        die "usage: $0 {build|install}"
        ;;
esac
