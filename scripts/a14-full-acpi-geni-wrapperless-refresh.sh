#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Refresh the A14 full-ACPI experimental kernel with the wrapperless GENI I2C
# fix and the audited UX3407RA WoA GPIO/TLMM transform.
set -euo pipefail

ROOT="${A14_FULL_ACPI_WORKDIR:-$HOME/Downloads/a14-full-acpi-kernel}"
SRC="$ROOT/linux-7.1.5"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/a14-full-acpi-kernel.sh"
GENI_PATCH="$SCRIPT_DIR/apply-a14-full-acpi-geni-wrapperless.py"
GPIO_PATCH="$SCRIPT_DIR/apply-a14-full-acpi-woa-gpio-xlate.py"

[[ -x "$BASE" ]] || { echo "ERROR: missing $BASE" >&2; exit 1; }
[[ -f "$GENI_PATCH" ]] || { echo "ERROR: missing $GENI_PATCH" >&2; exit 1; }
[[ -f "$GPIO_PATCH" ]] || { echo "ERROR: missing $GPIO_PATCH" >&2; exit 1; }
[[ -f "$SRC/Makefile" ]] || { echo "ERROR: kernel source missing: $SRC" >&2; exit 1; }

python3 "$GENI_PATCH" "$SRC"
python3 "$GPIO_PATCH" "$SRC"

python3 - "$SRC/drivers/pinctrl/qcom/pinctrl-x1e80100.c" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
try:
    table = t.split("x1e80100_pinctrl_acpi_match[]", 1)[1].split("};", 1)[0]
except IndexError:
    raise SystemExit("ERROR: x1e80100 ACPI match table not found")
for required in ('QCOM0C0C', 'QCOMFFEB'):
    if required not in table:
        raise SystemExit(f"ERROR: GIO0 ACPI ID missing from TLMM table: {required}")
if 'QCOM0C0D' in table:
    raise SystemExit("ERROR: A14 IPC0 HID QCOM0C0D still present in TLMM table")
print("A14_GIO0_TLMM_MATCH=VERIFIED")
print("gio0_ids=QCOM0C0C,QCOMFFEB")
print("ipc0_qcom0c0d_match=false")
PY

case "${1:-}" in
    "")
        echo "A14_FULL_ACPI_GENI_GPIO_REFRESH=READY"
        echo "source=$SRC"
        echo "next=$BASE build"
        ;;
    build)
        "$BASE" build
        ;;
    install)
        "$BASE" install
        ;;
    build-install)
        "$BASE" build
        "$BASE" install
        ;;
    *)
        echo "usage: $0 [build|install|build-install]" >&2
        exit 2
        ;;
esac
