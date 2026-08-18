#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Refresh the A14 full-ACPI experimental kernel with the wrapperless GENI I2C
# fix and the audited UX3407RA WoA GPIO/TLMM transform.
#
# IMPORTANT: the base builder's prepare() deliberately resets/cleans the kernel
# tree before applying the base ACPI transform. Therefore the extra GENI/GPIO
# transforms MUST be applied after `prepare`, not before `build`.
set -euo pipefail

OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
ROOT="${A14_FULL_ACPI_WORKDIR:-${A14_FULL_ACPI_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}}"
SRC="$ROOT/linux-7.1.5"
OUT="$ROOT/build"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/a14-full-acpi-kernel.sh"
GENI_PATCH="$SCRIPT_DIR/apply-a14-full-acpi-geni-wrapperless.py"
GPIO_PATCH="$SCRIPT_DIR/apply-a14-full-acpi-woa-gpio-xlate.py"
JOBS="${A14_BUILD_JOBS:-$(nproc)}"

[[ -f "$BASE" ]] || { echo "ERROR: base helper file missing from worktree: $BASE" >&2; echo "       Verify with: git ls-tree -r --name-only HEAD -- scripts/a14-full-acpi-kernel.sh" >&2; exit 1; }
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
    # This reset/clean MUST happen first. Invoke through bash so the repository's
    # executable bit / filesystem noexec state cannot masquerade as a missing file.
    bash "$BASE" prepare
    [[ -f "$SRC/Makefile" ]] || { echo "ERROR: kernel source missing after prepare: $SRC" >&2; exit 1; }

    # Apply the additive transforms only after the destructive prepare step.
    python3 "$GENI_PATCH" "$SRC"
    python3 "$GPIO_PATCH" "$SRC"
    verify_source
}

estimate_pending_actions() {
    local target="$1"
    local plan
    plan="$(mktemp)"

    # A dry run gives us the work Kbuild currently believes is still pending.
    # This is an estimate: generated prerequisites and parallel scheduling can
    # make the final action count differ slightly, so the UI marks percentages ~.
    set +e
    make -C "$SRC" O="$OUT" -n -j1 --no-print-directory "$target" >"$plan" 2>/dev/null
    local plan_rc=$?
    set -e

    if (( plan_rc != 0 )); then
        rm -f "$plan"
        printf '0\n'
        return 0
    fi

    python3 - "$plan" <<'PY'
from pathlib import Path
import re, sys
text = Path(sys.argv[1]).read_text(errors="replace")
actions = (
    "AR|AS|BTF|BTFIDS|CALL|CC|CHK|DTC|DTB|GEN|HOSTCC|HOSTCXX|HOSTLD|"
    "KSYMS|LD|LEX|MODPOST|NM|OBJCOPY|SORTTAB|UPD|YACC"
)
# Default quiet Kbuild recipes contain an echo of the concise action label.
pat = re.compile(r"\becho\s+['\"]?\s*(?:%s)\b" % actions)
count = sum(1 for line in text.splitlines() if pat.search(line))
print(count)
PY
    rm -f "$plan"
}

progress_filter() {
    local total="$1"
    local label="$2"
    local logfile="$3"
    python3 - "$total" "$label" "$logfile" <<'PY'
import re
import shutil
import sys
import time

total = int(sys.argv[1])
label = sys.argv[2]
logfile = sys.argv[3]
start = time.monotonic()
done = 0
warnings = 0
shown_warnings = 0
last_target = "starting"
spinner = "|/-\\"
spin_i = 0

act = re.compile(
    r"^\s*(AR|AS|BTF|BTFIDS|CALL|CC|CHK|DTC|DTB|GEN|HOSTCC|HOSTCXX|HOSTLD|"
    r"KSYMS|LD|LEX|MODPOST|NM|OBJCOPY|SORTTAB|UPD|YACC)(?:\s+\[M\])?\s+(.+?)\s*$"
)
warn = re.compile(r"(?:\bwarning:|\bWARNING:)", re.I)
err = re.compile(
    r"(?:\bfatal:|\berror:|\bERROR:|undefined reference|No rule to make target|"
    r"make(?:\[\d+\])?: \*\*\*)",
    re.I,
)

def hms(seconds):
    seconds = max(0, int(seconds))
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h:d}:{m:02d}:{s:02d}"
    return f"{m:02d}:{s:02d}"

def clear_line():
    width = shutil.get_terminal_size((120, 20)).columns
    sys.stdout.write("\r" + (" " * max(1, width - 1)) + "\r")

def draw(final=False):
    global spin_i
    elapsed = time.monotonic() - start
    width = shutil.get_terminal_size((120, 20)).columns
    bar_w = max(12, min(34, width // 4))

    if final:
        pct = 100
        filled = bar_w
        prefix = "100%"
        eta = "00:00"
    elif total > 0:
        # Keep 100% for successful make completion; estimates can undercount.
        ratio = min(done / total, 0.99)
        pct = int(ratio * 100)
        filled = int(bar_w * ratio)
        prefix = f"~{pct:2d}%"
        if done >= 3 and elapsed > 0:
            rate = done / elapsed
            eta_s = max(0, total - done) / rate if rate else 0
            eta = "~" + hms(eta_s)
        else:
            eta = "--:--"
    else:
        pct = 0
        filled = (spin_i % bar_w) + 1
        prefix = " ..."
        eta = "--:--"
        spin_i += 1

    bar = "#" * filled + "-" * (bar_w - filled)
    target = last_target
    max_target = max(18, width - bar_w - 61)
    if len(target) > max_target:
        target = "…" + target[-(max_target - 1):]

    counts = f"{done}/{total}" if total > 0 else f"actions:{done}"
    line = (
        f"[{bar}] {prefix}  {counts}  elapsed {hms(elapsed)}  ETA {eta}  "
        f"warn {warnings}  {target}"
    )
    sys.stdout.write("\r" + line[: max(1, width - 1)].ljust(max(1, width - 1)))
    sys.stdout.flush()

print(f"A14_BUILD_PHASE={label}")
if total > 0:
    print(f"estimated_pending_actions={total}")
else:
    print("estimated_pending_actions=unknown; using activity bar")
print(f"raw_log={logfile}")
draw()

for raw in sys.stdin:
    line = raw.rstrip("\n")
    m = act.match(line)
    if m:
        done += 1
        last_target = f"{m.group(1)} {m.group(2)}"
        draw()
        continue

    if warn.search(line):
        warnings += 1
        # Show only the first few warnings in the live terminal. Everything is
        # preserved verbatim by tee in logfile.
        if shown_warnings < 5:
            clear_line()
            print(line)
            shown_warnings += 1
        draw()
        continue

    if err.search(line):
        clear_line()
        print(line)
        draw()

clear_line()
print(f"A14_BUILD_PHASE_STREAM_END={label}")
print(f"actions_observed={done}")
print(f"warnings_observed={warnings}")
if warnings > shown_warnings:
    print(f"warnings_suppressed_from_terminal={warnings - shown_warnings} (all preserved in {logfile})")
PY
}

run_make_with_progress() {
    local label="$1"
    local target="$2"
    local slug="${label//[^A-Za-z0-9]/-}"
    local logfile="$ROOT/a14-build-${slug}.log"
    local total

    echo
    echo "===== $label ====="
    echo "Planning remaining Kbuild work for '$target'..."
    total="$(estimate_pending_actions "$target")"

    if [[ "${A14_PROGRESS:-1}" == 0 || ! -t 1 ]]; then
        echo "progress_ui=disabled"
        echo "raw_log=$logfile"
        make -C "$SRC" O="$OUT" -j"$JOBS" "$target" 2>&1 | tee "$logfile"
        return ${PIPESTATUS[0]}
    fi

    set +e
    make -C "$SRC" O="$OUT" -j"$JOBS" "$target" 2>&1 \
        | tee "$logfile" \
        | progress_filter "$total" "$label" "$logfile"
    local make_rc=${PIPESTATUS[0]}
    set -e

    if (( make_rc != 0 )); then
        echo
        echo "ERROR: Kbuild phase '$label' failed with exit code $make_rc" >&2
        echo "----- last 80 raw log lines: $logfile -----" >&2
        tail -n 80 "$logfile" >&2 || true
        return "$make_rc"
    fi

    # Successful phase: provide an unambiguous final 100% line even when the
    # preflight estimate was slightly off.
    printf '[##################################] 100%%  %s COMPLETE\n' "$label"
}

run_full_make() {
    echo "A14_BUILD_PROGRESS_UI=ENABLED"
    echo "jobs=$JOBS"
    echo "note=percentages marked ~ are based on Kbuild dry-run pending-action estimates"
    run_make_with_progress "1/2 Kernel Image" Image
    run_make_with_progress "2/2 Loadable Modules" modules
}

finish_build() {
    [[ -s "$OUT/arch/arm64/boot/Image" ]] || { echo "ERROR: Image missing" >&2; exit 1; }
    verify_built_object
    echo "A14_FULL_ACPI_GENI_GPIO_BUILD=COMPLETE"
    echo "image=$OUT/arch/arm64/boot/Image"
    echo "sha256=$(sha256sum "$OUT/arch/arm64/boot/Image" | awk '{print $1}')"
}

build_patched() {
    prepare_and_patch
    export LOCALVERSION=
    run_full_make
    finish_build
}

resume_patched() {
    [[ -f "$SRC/Makefile" ]] || { echo "ERROR: kernel source missing; run '$0 build' first" >&2; exit 1; }
    [[ -f "$OUT/.config" ]] || { echo "ERROR: build configuration missing; run '$0 build' first" >&2; exit 1; }
    verify_source
    echo "A14_FULL_ACPI_GENI_GPIO_RESUME=START"
    echo "source=$SRC"
    echo "build=$OUT"
    export LOCALVERSION=
    # Do NOT call prepare here: make will reuse all valid objects from the interrupted build.
    run_full_make
    finish_build
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
    resume)
        resume_patched
        ;;
    install)
        verify_installable
        bash "$BASE" install
        ;;
    build-install)
        build_patched
        bash "$BASE" install
        ;;
    *)
        echo "usage: $0 [build|resume|install|build-install]" >&2
        exit 2
        ;;
esac
