#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Orchestrate the A14 full-ACPI prepare/patch/build/resume/install workflow.
set -euo pipefail

OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
ROOT="${A14_FULL_ACPI_WORKDIR:-${A14_FULL_ACPI_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}}"
SRC="$ROOT/linux-7.1.5"
OUT="$ROOT/build"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/a14-full-acpi-kernel.sh"
GENI_PATCH="$SCRIPT_DIR/apply-a14-full-acpi-geni-wrapperless.py"
GPIO_PATCH="$SCRIPT_DIR/apply-a14-full-acpi-woa-gpio-xlate.py"
PRUNE="$SCRIPT_DIR/a14-full-acpi-prune-config.sh"
BUILD_UI="$SCRIPT_DIR/a14-full-acpi-resume-progress.sh"
INSTALL_UI="$SCRIPT_DIR/a14-full-acpi-install-progress.sh"

for f in "$BASE" "$GENI_PATCH" "$GPIO_PATCH" "$PRUNE" "$BUILD_UI" "$INSTALL_UI"; do
    [[ -f "$f" ]] || { echo "ERROR: required helper missing: $f" >&2; exit 1; }
done

export A14_FULL_ACPI_WORK="$ROOT"

verify_source() {
    python3 - "$SRC/drivers/pinctrl/qcom/pinctrl-x1e80100.c" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
t=p.read_text()
try:
    table=t.split("x1e80100_pinctrl_acpi_match[]",1)[1].split("};",1)[0]
except IndexError:
    raise SystemExit("ERROR: x1e80100 ACPI match table not found")
for required in ("QCOM0C0C","QCOMFFEB"):
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
b=Path(sys.argv[1]).read_bytes()
for required in (b"QCOM0C0C\0",b"QCOMFFEB\0"):
    if required not in b:
        raise SystemExit(f"ERROR: built TLMM object lacks {required[:-1].decode()}")
if b"QCOM0C0D\0" in b:
    raise SystemExit("ERROR: built TLMM object still contains IPC0 match QCOM0C0D")
print("A14_GIO0_TLMM_OBJECT=VERIFIED")
print("built_gio0_ids=QCOM0C0C,QCOMFFEB")
print("built_ipc0_qcom0c0d_match=false")
PY
}

prepare_and_patch() {
    [[ ${EUID:-$(id -u)} -ne 0 ]] || { echo "ERROR: build/prepare as your normal user, not root" >&2; exit 1; }

    # The base prepare intentionally resets/cleans the kernel tree first.
    bash "$BASE" prepare
    [[ -f "$SRC/Makefile" ]] || { echo "ERROR: source missing after prepare: $SRC" >&2; exit 1; }

    # Prune obviously unrelated graphics stacks before compiling. This keeps
    # Qualcomm MSM DRM and simpledrm, while avoiding AMDGPU/Radeon/Nouveau/etc.
    bash "$PRUNE" "$SRC" "$OUT"

    # Add the A14-specific ACPI transforms only after destructive prepare.
    python3 "$GENI_PATCH" "$SRC"
    python3 "$GPIO_PATCH" "$SRC"
    verify_source
}

verify_installable() {
    [[ -f "$SRC/Makefile" ]] || { echo "ERROR: kernel source missing: $SRC" >&2; exit 1; }
    [[ -s "$OUT/arch/arm64/boot/Image" ]] || { echo "ERROR: no built Image; run '$0 build' first" >&2; exit 1; }
    [[ -f "$OUT/modules.order" ]] || { echo "ERROR: modules are incomplete; run '$0 build' or '$0 resume'" >&2; exit 1; }
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
        prepare_and_patch
        bash "$BUILD_UI"
        ;;
    resume)
        [[ ${EUID:-$(id -u)} -ne 0 ]] || { echo "ERROR: resume as your normal user, not root" >&2; exit 1; }
        bash "$BUILD_UI"
        ;;
    install)
        [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "ERROR: install requires sudo/root" >&2; exit 1; }
        verify_installable
        bash "$INSTALL_UI"
        ;;
    build-install)
        echo "ERROR: build and install deliberately require different privilege levels." >&2
        echo "       Run: bash $0 build" >&2
        echo "       Then: sudo bash $0 install" >&2
        exit 2
        ;;
    *)
        echo "usage: $0 [build|resume|install]" >&2
        exit 2
        ;;
esac
