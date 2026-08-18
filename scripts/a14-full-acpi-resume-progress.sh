#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Resume the interrupted A14 full-ACPI build without prepare/reset/clean.
set -euo pipefail

OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
ROOT="${A14_FULL_ACPI_WORKDIR:-${A14_FULL_ACPI_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}}"
SRC="$ROOT/linux-7.1.5"
OUT="$ROOT/build"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROGRESS="$SCRIPT_DIR/a14-kbuild-progress.py"
WATCH="$SCRIPT_DIR/a14-kbuild-watch.py"
JOBS="${A14_BUILD_JOBS:-$(nproc)}"

[[ -f "$SRC/Makefile" ]] || { echo "ERROR: kernel source missing: $SRC" >&2; exit 1; }
[[ -f "$OUT/.config" ]] || { echo "ERROR: build configuration missing: $OUT/.config" >&2; exit 1; }
[[ -f "$PROGRESS" ]] || { echo "ERROR: progress helper missing: $PROGRESS" >&2; exit 1; }
[[ -f "$WATCH" ]] || { echo "ERROR: exact module watcher missing: $WATCH" >&2; exit 1; }

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
print("ipc0_qcom0d_match=false")
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
print("built_ipc0_qcom0d_match=false")
PY
}

run_image_phase() {
    local label="1/2 Kernel Image"
    local logfile="$ROOT/a14-build-1-2-Kernel-Image.log"
    echo
    echo "===== $label ====="
    echo "Starting real Kbuild immediately..."
    set +e
    make -C "$SRC" O="$OUT" -j"$JOBS" Image 2>&1 \
        | tee "$logfile" \
        | python3 "$PROGRESS" --label "$label" --logfile "$logfile" --module-total 0 --module-built 0
    local rc=${PIPESTATUS[0]}
    set -e
    if (( rc != 0 )); then
        echo >&2
        echo "ERROR: Kbuild phase '$label' failed with exit code $rc" >&2
        tail -n 120 "$logfile" >&2 || true
        return "$rc"
    fi
    printf '[##################################] 100%%  %s COMPLETE\n' "$label"
}

run_modules_phase() {
    local label="2/2 Loadable Modules"
    local logfile="$ROOT/a14-build-2-2-Loadable-Modules.log"
    echo
    echo "===== $label ====="
    echo "Starting real Kbuild immediately..."
    echo "progress_metric=fully finalized .ko modules (current link + completed BTF when enabled)"
    : > "$logfile"

    set +e
    make -C "$SRC" O="$OUT" -j"$JOBS" modules >"$logfile" 2>&1 &
    local make_pid=$!
    trap "kill -INT $make_pid 2>/dev/null || true; wait $make_pid 2>/dev/null || true; exit 130" INT TERM

    python3 "$WATCH" --build "$OUT" --pid "$make_pid" --logfile "$logfile"
    local watch_rc=$?
    wait "$make_pid"
    local make_rc=$?
    trap - INT TERM
    set -e

    if (( make_rc != 0 )); then
        echo >&2
        echo "ERROR: Kbuild phase '$label' failed with exit code $make_rc" >&2
        echo "----- last 120 raw log lines: $logfile -----" >&2
        tail -n 120 "$logfile" >&2 || true
        return "$make_rc"
    fi

    # Make success is authoritative. Re-scan once after wait to close any tiny
    # race where the watcher observed the child exiting just before final cleanup.
    if (( watch_rc != 0 )); then
        python3 "$WATCH" --build "$OUT" --logfile "$logfile" --once || true
    fi
    printf '[##################################] 100%%  %s COMPLETE\n' "$label"
}

verify_source
echo "A14_FULL_ACPI_GENI_GPIO_RESUME=START"
echo "source=$SRC"
echo "build=$OUT"
echo "A14_BUILD_PROGRESS_UI=EXACT_MODULE_FINALIZATION"
echo "jobs=$JOBS"
echo "progress_preflight=disabled"
export LOCALVERSION=
run_image_phase
run_modules_phase

[[ -s "$OUT/arch/arm64/boot/Image" ]] || { echo "ERROR: Image missing" >&2; exit 1; }
verify_built_object
echo "A14_FULL_ACPI_GENI_GPIO_BUILD=COMPLETE"
echo "image=$OUT/arch/arm64/boot/Image"
echo "sha256=$(sha256sum "$OUT/arch/arm64/boot/Image" | awk '{print $1}')"
