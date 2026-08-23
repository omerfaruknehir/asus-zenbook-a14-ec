#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# ROOT14 corrected launcher.
#
# The original ROOT14 script accidentally reused root0-build.  Linux reads
# KERNELRELEASE from O=.../include/config/kernel.release when present, so an
# older ROOT11 build tree can leak its generated release string into ROOT14.
# Also force LOCALVERSION to the empty environment value so setlocalversion
# cannot append SCM/dirty state beyond CONFIG_LOCALVERSION.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
TARGET="$SCRIPT_DIR/a14-acpi-root14-qcom-flash-one-go.sh"

[[ -r "$TARGET" ]] || {
    echo "ERROR: ROOT14 target script missing: $TARGET" >&2
    exit 1
}

OWNER="${SUDO_USER:-${USER:-}}"
[[ -n "$OWNER" ]] || {
    echo "ERROR: cannot resolve invoking user" >&2
    exit 1
}

OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
[[ -d "$OWNER_HOME" ]] || {
    echo "ERROR: cannot resolve invoking user's home" >&2
    exit 1
}

WORK="${A14_74C9_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
ROOT14_OUT="$WORK/root14-build"

# Refuse an externally supplied conflicting output directory.  This prevents
# accidentally falling back to root0-build/root11-generated metadata again.
if [[ -n "${A14_KERNEL_OUT:-}" && "$A14_KERNEL_OUT" != "$ROOT14_OUT" ]]; then
    echo "ERROR: refusing conflicting A14_KERNEL_OUT=$A14_KERNEL_OUT" >&2
    echo "expected ROOT14-only output directory: $ROOT14_OUT" >&2
    exit 1
fi

export A14_KERNEL_OUT="$ROOT14_OUT"
export LOCALVERSION=

printf '%s\n' \
    "A14_ACPI_ROOT14_V2_LAUNCHER=1" \
    "root14_out=$A14_KERNEL_OUT" \
    "localversion_environment=EMPTY" \
    "delegating_to=$TARGET"

exec bash "$TARGET" "$@"
