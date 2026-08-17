#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Regenerate the currently saved device-bisect threshold without changing the
# saved binary-search range/outcome. Useful after rebuilding the experimental
# kernel to test a fix against the exact same failing threshold.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
STATE="/var/lib/a14-full-acpi/device-bisect.state"
HELPER="$ROOT/scripts/a14-full-acpi-device-bisect-entry.sh"

die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"
[[ -r "$STATE" ]] || die "missing saved bisect state: $STATE"
[[ -x "$HELPER" || -r "$HELPER" ]] || die "missing bisect helper: $HELPER"

saved="$(cat "$STATE")"
# shellcheck disable=SC1090
source "$STATE"
[[ "${state_current:-}" =~ ^[0-9]+$ ]] || die "saved state has no valid state_current"
current="$state_current"
low="${state_low:-?}"
high="${state_high:-?}"
last="${state_last_outcome:-?}"

# Numeric mode regenerates the requested GRUB entry but resets the helper's
# state to a manual full-range state. Restore the exact prior state afterward.
bash "$HELPER" "$current"
printf '%s\n' "$saved" > "$STATE"

echo "A14_FULL_ACPI_DEVICE_BISECT_REPEAT=READY"
echo "repeated_threshold=$current"
echo "preserved_suspect_range=$low..$high"
echo "preserved_last_outcome=$last"
echo "checkpoint_reboot_delay_ms=${A14_ACPI_REBOOT_DELAY_MS:-5000}"
echo "state_advanced=false"
