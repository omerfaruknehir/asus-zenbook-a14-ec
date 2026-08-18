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
JOBS="${A14_BUILD_JOBS:-$(nproc)}"

[[ -f "$SRC/Makefile" ]] || { echo "ERROR: kernel source missing: $SRC" >&2; exit 1; }
[[ -f "$OUT/.config" ]] || { echo "ERROR: build configuration missing: $OUT/.config" >&2; exit 1; }
[[ -f "$PROGRESS" ]] || { echo "ERROR: progress helper missing: $PROGRESS" >&2; exit 1; }

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

module_counts() {
    python3 - "$OUT" <<'PY'
from pathlib import Path
import sys
out = Path(sys.argv[1])
order = out / "modules.order"
if not order.is_file():
    print("0 0")
    raise SystemExit
mods=[]; seen=set()
for line in order.read_text(errors="replace").splitlines():
    p=line.strip()
    if p and p not in seen:
        seen.add(p); mods.append(p)
built=sum((out/p).is_file() and (out/p).stat().st_size>0 for p in mods)
print(len(mods), built)
PY
}

run_phase() {
    local label="$1" target="$2" mt=0 mb=0
    local slug="${label//[^A-Za-z0-9]/-}"
    local logfile="$ROOT/a14-build-${slug}.log"
    if [[ "$target" == modules ]]; then read -r mt mb < <(module_counts); fi

    echo
    echo "===== $label ====="
    echo "Starting real Kbuild immediately..."
    if [[ "$target" == modules ]]; then
        echo "modules_total=$mt"
        echo "modules_already_built=$mb"
    fi

    set +e
    make -C "$SRC" O="$OUT" -j"$JOBS" "$target" 2>&1 \
        | tee "$logfile" \
        | python3 "$PROGRESS" --label "$label" --logfile "$logfile" --module-total "$mt" --module-built "$mb"
    local rc=${PIPESTATUS[0]}
    set -e

    if (( rc != 0 )); then
        echo >&2
        echo "ERROR: Kbuild phase '$label' failed with exit code $rc" >&2
        echo "----- last 120 raw log lines: $logfile -----" >&2
        tail -n 120 "$logfile" >&2 || true
        return "$rc"
    fi

    printf '[##################################] 100%%  %s COMPLETE\n' "$label"
}

verify_source
echo "A14_FULL_ACPI_GENI_GPIO_RESUME=START"
echo "source=$SRC"
echo "build=$OUT"
echo "A14_BUILD_PROGRESS_UI=STDIN_SAFE"
echo "jobs=$JOBS"
echo "progress_preflight=disabled"
export LOCALVERSION=
run_phase "1/2 Kernel Image" Image
run_phase "2/2 Loadable Modules" modules

[[ -s "$OUT/arch/arm64/boot/Image" ]] || { echo "ERROR: Image missing" >&2; exit 1; }
verify_built_object
echo "A14_FULL_ACPI_GENI_GPIO_BUILD=COMPLETE"
echo "image=$OUT/arch/arm64/boot/Image"
echo "sha256=$(sha256sum "$OUT/arch/arm64/boot/Image" | awk '{print $1}')"
