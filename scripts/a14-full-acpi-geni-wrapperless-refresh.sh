#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Apply/verify the wrapperless ACPI GENI-I2C fix, then reuse the validated
# full-ACPI SMMU/checkpoint build and install pipeline.
set -euo pipefail

ACTION="${1:-build}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
WORK="${A14_FULL_ACPI_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="$WORK/linux-7.1.5"
I2C="$SRC/drivers/i2c/busses/i2c-qcom-geni.c"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

verify_source(){
    [[ -r "$I2C" ]] || die "missing GENI I2C source: $I2C"
    grep -q 'has_acpi_companion(dev) && !gi2c->se.wrapper' "$I2C" || die "wrapperless ACPI GENI guard missing"
    grep -q 'TX_FIFO_DEPTH_MSK_256_BYTES' "$I2C" || die "wrapperless FIFO-depth field missing"
    grep -q 'A14 ACPI: wrapperless GENI SE, TX FIFO depth' "$I2C" || die "wrapperless GENI boot marker missing"
}

case "$ACTION" in
    build)
        [[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as your normal user, not root"
        [[ -f "$SRC/Makefile" ]] || die "existing Linux 7.1.5 source tree missing: $SRC"
        python3 "$ROOT/scripts/apply-a14-full-acpi-geni-wrapperless.py" "$SRC"
        verify_source
        bash "$ROOT/scripts/a14-full-acpi-smmu-reset-debug-refresh.sh" build
        verify_source
        say "A14_FULL_ACPI_GENI_WRAPPERLESS_BUILD=COMPLETE"
        say "acpi_null_wrapper_guard=yes"
        say "fifo_depth_source=SE_HW_PARAM_0"
        say "dt_wrapper_path=unchanged"
        ;;
    install)
        [[ ${EUID:-$(id -u)} -eq 0 ]] || die "install requires sudo/root"
        verify_source
        bash "$ROOT/scripts/a14-full-acpi-smmu-reset-debug-refresh.sh" install
        say "A14_FULL_ACPI_GENI_WRAPPERLESS_INSTALL=COMPLETE"
        say "acpi_null_wrapper_guard=yes"
        say "fifo_depth_source=SE_HW_PARAM_0"
        say "dt_wrapper_path=unchanged"
        ;;
    *)
        die "usage: $0 {build|install}"
        ;;
esac
