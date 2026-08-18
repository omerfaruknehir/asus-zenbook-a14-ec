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

[[ -f "$BASE" ]] || { echo "ERROR: base helper file missing from worktree: $BASE" >&2; exit 1; }
[[ -f "$GENI_PATCH" ]] || { echo "ERROR: missing $GENI_PATCH" >&2; exit 1; }
[[ -f "$GPIO_PATCH" ]] || { echo "ERROR: missing $GPIO_PATCH" >&2; exit 1; }

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
print("built_ipc0_qcom0d_match=false")
PY
}

prepare_and_patch() {
    bash "$BASE" prepare
    [[ -f "$SRC/Makefile" ]] || { echo "ERROR: kernel source missing after prepare: $SRC" >&2; exit 1; }
    python3 "$GENI_PATCH" "$SRC"
    python3 "$GPIO_PATCH" "$SRC"
    verify_source
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
mods = []
seen = set()
for line in order.read_text(errors="replace").splitlines():
    p = line.strip()
    if p and p not in seen:
        seen.add(p)
        mods.append(p)
built = sum((out / p).is_file() and (out / p).stat().st_size > 0 for p in mods)
print(len(mods), built)
PY
}

progress_filter() {
    local label="$1" logfile="$2" module_total="${3:-0}" module_built="${4:-0}"
    python3 - "$label" "$logfile" "$module_total" "$module_built" <<'PY'
import re, shutil, sys, time
label, logfile = sys.argv[1], sys.argv[2]
module_total, module_done = int(sys.argv[3]), int(sys.argv[4])
start = time.monotonic(); actions = warnings = shown = 0
last_target = "starting"; spin_i = 0
seen_ko = set()
act = re.compile(r"^\s*(AR|AS|BTF|BTFIDS|CALL|CC|CHK|DTC|DTB|GEN|HOSTCC|HOSTCXX|HOSTLD|KSYMS|LD|LEX|MODPOST|NM|OBJCOPY|SORTTAB|UPD|YACC)(?:\s+\[M\])?\s+(.+?)\s*$")
warn = re.compile(r"(?:\bwarning:|\bWARNING:)", re.I)
err = re.compile(r"(?:\bfatal:|\berror:|\bERROR:|undefined reference|No rule to make target|make(?:\[\d+\])?: \*\*\*)", re.I)
ko = re.compile(r"^\s*(?:LD|BTF)\s+\[M\]\s+(.+\.ko)\s*$")

def hms(v):
    v=max(0,int(v)); h,r=divmod(v,3600); m,s=divmod(r,60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"

def clear():
    w=shutil.get_terminal_size((120,20)).columns
    sys.stdout.write("\r"+" "*max(1,w-1)+"\r")

def draw(final=False):
    global spin_i
    elapsed=time.monotonic()-start; w=shutil.get_terminal_size((120,20)).columns
    bw=max(12,min(34,w//4))
    if final:
        bar="#"*bw; prefix="100%"; counts="complete"; eta="00:00"
    elif module_total>0:
        ratio=min(module_done/module_total,0.99); filled=int(bw*ratio)
        bar="#"*filled+"-"*(bw-filled); prefix=f"~{int(ratio*100):2d}%"
        counts=f"{module_done}/{module_total} modules"
        advanced=max(0,module_done-int(sys.argv[4]))
        if advanced>=2 and elapsed>0:
            rate=advanced/elapsed
            eta="~"+hms((module_total-module_done)/rate) if rate else "--:--"
        else: eta="--:--"
    else:
        span=min(6,bw); pos=spin_i % max(1,bw-span+1); spin_i+=1
        chars=list("-"*bw)
        for i in range(pos,pos+span): chars[i]="#"
        bar="".join(chars); prefix="running"; counts=f"actions:{actions}"; eta="--:--"
    target=last_target; max_target=max(18,w-bw-68)
    if len(target)>max_target: target="…"+target[-(max_target-1):]
    line=f"[{bar}] {prefix}  {counts}  elapsed {hms(elapsed)}  ETA {eta}  warn {warnings}  {target}"
    sys.stdout.write("\r"+line[:max(1,w-1)].ljust(max(1,w-1))); sys.stdout.flush()

print(f"A14_BUILD_PHASE={label}")
if module_total:
    print(f"modules_total={module_total}")
    print(f"modules_already_built={module_done}")
else:
    print("progress_mode=immediate activity bar; no blocking Kbuild preflight")
print(f"raw_log={logfile}")
draw()
for raw in sys.stdin:
    line=raw.rstrip("\n")
    km=ko.match(line)
    if km and km.group(1) not in seen_ko:
        seen_ko.add(km.group(1)); module_done=min(module_total or 10**9,module_done+1)
    m=act.match(line)
    if m:
        actions+=1; last_target=f"{m.group(1)} {m.group(2)}"; draw(); continue
    if warn.search(line):
        warnings+=1
        if shown<5:
            clear(); print(line); shown+=1
        draw(); continue
    if err.search(line):
        clear(); print(line); draw()
clear()
print(f"A14_BUILD_PHASE_STREAM_END={label}")
print(f"actions_observed={actions}")
print(f"warnings_observed={warnings}")
if warnings>shown:
    print(f"warnings_suppressed_from_terminal={warnings-shown} (all preserved in {logfile})")
PY
}

run_make_with_progress() {
    local label="$1" target="$2"
    local slug="${label//[^A-Za-z0-9]/-}"
    local logfile="$ROOT/a14-build-${slug}.log"
    local mt=0 mb=0
    if [[ "$target" == modules ]]; then read -r mt mb < <(module_counts); fi

    echo
    echo "===== $label ====="
    echo "Starting real Kbuild immediately..."

    if [[ "${A14_PROGRESS:-1}" == 0 || ! -t 1 ]]; then
        echo "progress_ui=disabled"; echo "raw_log=$logfile"
        set +e
        make -C "$SRC" O="$OUT" -j"$JOBS" "$target" 2>&1 | tee "$logfile"
        local rc=${PIPESTATUS[0]}
        set -e
        return "$rc"
    fi

    set +e
    make -C "$SRC" O="$OUT" -j"$JOBS" "$target" 2>&1 \
        | tee "$logfile" \
        | progress_filter "$label" "$logfile" "$mt" "$mb"
    local make_rc=${PIPESTATUS[0]}
    set -e

    if (( make_rc != 0 )); then
        echo
        echo "ERROR: Kbuild phase '$label' failed with exit code $make_rc" >&2
        echo "----- last 120 raw log lines: $logfile -----" >&2
        tail -n 120 "$logfile" >&2 || true
        echo "----- build state -----" >&2
        printf 'Image: ' >&2; ls -lh "$OUT/arch/arm64/boot/Image" 2>/dev/null >&2 || echo missing >&2
        printf 'vmlinux: ' >&2; ls -lh "$OUT/vmlinux" 2>/dev/null >&2 || echo missing >&2
        return "$make_rc"
    fi

    printf '[##################################] 100%%  %s COMPLETE\n' "$label"
}

run_full_make() {
    echo "A14_BUILD_PROGRESS_UI=ENABLED"
    echo "jobs=$JOBS"
    echo "progress_preflight=disabled (real build starts immediately)"
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
    "") prepare_and_patch; echo "A14_FULL_ACPI_GENI_GPIO_REFRESH=READY"; echo "source=$SRC"; echo "next=$0 build";;
    build) build_patched;;
    resume) resume_patched;;
    install) verify_installable; bash "$BASE" install;;
    build-install) build_patched; bash "$BASE" install;;
    *) echo "usage: $0 [build|resume|install|build-install]" >&2; exit 2;;
esac
