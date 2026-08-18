#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Refresh the A14 full-ACPI experimental kernel with the wrapperless GENI I2C
# fix and the audited UX3407RA WoA GPIO/TLMM transform.
#
# IMPORTANT: the base builder's prepare() deliberately resets/cleans the kernel
# tree before applying the base ACPI transform. Therefore the extra GENI/GPIO
# transforms MUST be applied after `prepare`, not before `build`.
set -euo pipefail

ROOT="${A14_FULL_ACPI_WORKDIR:-${A14_FULL_ACPI_WORK:-$HOME/Downloads/a14-full-acpi-kernel}}"
SRC="$ROOT/linux-7.1.5"
OUT="$ROOT/build"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/a14-full-acpi-kernel.sh"
GENI_PATCH="$SCRIPT_DIR/apply-a14-full-acpi-geni-wrapperless.py"
GPIO_PATCH="$SCRIPT_DIR/apply-a14-full-acpi-woa-gpio-xlate.py"

[[ -x "$BASE" ]] || { echo "ERROR: missing $BASE" >&2; exit 1; }
[[ -f "$GENI_PATCH" ]] || { echo "ERROR: missing $GENI_PATCH" >&2; exit 1; }
[[ -f "$GPIO_PATCH" ]] || { echo "ERROR: missing $GPIO_PATCH" >&2; exit 1; }

# Force the base builder and this wrapper to operate on exactly the same tree.
export A14_FULL_ACPI_WORK="$ROOT"

verify_source() {
    python3 - "$SRC/drivers/pinctrl/qcom/pinctrl-x1e80100.c" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
try:
    table = t.split("x1e80100_pinctrl_acpi_match[]", 1)[1].split("};", 1)[0]
except IndexError:
    raise SystemExit("ERROR: x1e80100 ACPI match table not found")
for required in ("QCOM0C0C", "QCOMFFEB"):
    if required not in table:
        raise SystemExit(f"ERROR: GIO0 ACPI ID missing from TLMM table: {required}")
if "QCOM0C0D" in table:
    raise SystemExit("ERROR: A14 IPC0 HID QCOM0C0D still present in TLMM table")
print("A14_GIO0_TLMM_SOURCE=VERIFIED")
print("gio0_ids=QCOM0C0C,QCOMFFEB")
print("ipc0_qcom0c0d_match=false")
PY
}

verify_built_object() {
    local obj="$OUT/drivers/pinctrl/qcom/pinctrl-x1e80100.o"
    [[ -s "$obj" ]] || { echo "ERROR: built TLMM object missing: $obj" >&2; exit 1; }
    python3 - "$obj" <<'PY'
from pathlib import Path
import sys
b = Path(sys.argv[1]).read_bytes()
for required in (b"QCOM0C0C\x00", b"QCOMFFEB\x00"):
    if required not in b:
        raise SystemExit(f"ERROR: built TLMM object lacks {required[:-1].decode()}")
if b"QCOM0C0D\x00" in b:
    raise SystemExit("ERROR: built TLMM object still contains IPC0 match QCOM0C0D")
print("A14_GIO0_TLMM_OBJECT=VERIFIED")
print("built_gio0_ids=QCOM0C0C,QCOMFFEB")
print("built_ipc0_qcom0c0d_match=false")
PY
}

prepare_and_patch() {
    # This reset/clean MUST happen first.
    "$BASE" prepare
    [[ -f "$SRC/Makefile" ]] || { echo "ERROR: kernel source missing after prepare: $SRC" >&2; exit 1; }

    # Apply the additive transforms only after the destructive prepare step.
    python3 "$GENI_PATCH" "$SRC"
    python3 "$GPIO_PATCH" "$SRC"
    verify_source
}

build_patched() {
    prepare_and_patch
    export LOCALVERSION=
    make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" Image modules
    [[ -s "$OUT/arch/arm64/boot/Image" ]] || { echo "ERROR: Image missing" >&2; exit 1; }
    verify_built_object
    echo "A14_FULL_ACPI_GENI_GPIO_BUILD=COMPLETE"
    echo "image=$OUT/arch/arm64/boot/Image"
    echo "sha256=$(sha256sum "$OUT/arch/arm64/boot/Image" | awk '{print $1}')"
}

verify_installable() {
    [[ -f "$SRC/Makefile" ]] || { echo "ERROR: kernel source missing: $SRC" >&2; exit 1; }
    [[ -s "$OUT/arch/arm64/boot/Image" ]] || { echo "ERROR: no patched build to install; run '$0 build' first" >&2; exit 1; }
    verify_source
    verify_built_object
}

case "${1:-}" in
    "")
        prepare_and_patch
        echo "A14_FULL_ACPI_GENI_GPIO_REFRESH=READY"
        echo "source=$SRC"
        echo "next=$0 build"
        ;;
    build)
        build_patched
        ;;
    install)
        verify_installable
        "$BASE" install
        ;;
    build-install)
        build_patched
        "$BASE" install
        ;;
    *)
        echo "usage: $0 [build|install|build-install]" >&2
        exit 2
        ;;
esac
