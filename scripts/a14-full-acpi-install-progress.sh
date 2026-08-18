#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Install the already-built A14 full-ACPI kernel with truthful staged progress.
set -euo pipefail

KREL="7.1.5-a14-acpi-full0"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
WORK="${A14_FULL_ACPI_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="$WORK/linux-7.1.5"
OUT="$WORK/build"
MODROOT="/lib/modules/$KREL"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROGRESS="$SCRIPT_DIR/a14-install-progress.py"
UNRESTRICTED="$SCRIPT_DIR/a14-full-acpi-unrestricted-entry.sh"
LOGDIR="$WORK/install-logs"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"
case "$(uname -m)" in aarch64|arm64) ;; *) die "AArch64 host required; found $(uname -m)";; esac
[[ "$(uname -r)" != "$KREL" ]] || die "refusing to reinstall the currently running experimental kernel"
for c in make python3 install depmod update-initramfs cmp sha256sum; do need "$c"; done
[[ -f "$PROGRESS" ]] || die "missing installer progress helper: $PROGRESS"
[[ -f "$UNRESTRICTED" ]] || die "missing unrestricted-entry helper: $UNRESTRICTED"
[[ -f "$SRC/Makefile" ]] || die "missing kernel source: $SRC"
[[ -f "$OUT/.config" ]] || die "missing build config: $OUT/.config"
[[ -s "$OUT/arch/arm64/boot/Image" ]] || die "missing built Image"
[[ -f "$OUT/modules.order" ]] || die "missing modules.order; build modules first"

export LOCALVERSION=
actual_krel="$(make -s -C "$SRC" O="$OUT" kernelrelease)"
[[ "$actual_krel" == "$KREL" ]] || die "built kernelrelease is '$actual_krel', expected '$KREL'"

# Verify that the binary being installed really contains the audited GIO0 match
# and no longer binds the IPC0 HID QCOM0C0D as TLMM.
python3 - "$OUT/drivers/pinctrl/qcom/pinctrl-x1e80100.o" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
if not p.is_file() or p.stat().st_size == 0:
    raise SystemExit(f"ERROR: missing built TLMM object: {p}")
b=p.read_bytes()
for req in (b"QCOM0C0C\0", b"QCOMFFEB\0"):
    if req not in b:
        raise SystemExit(f"ERROR: built TLMM object lacks {req[:-1].decode()}")
if b"QCOM0C0D\0" in b:
    raise SystemExit("ERROR: built TLMM object still contains IPC0 QCOM0C0D match")
print("A14_GIO0_TLMM_OBJECT=VERIFIED")
print("built_gio0_ids=QCOM0C0C,QCOMFFEB")
print("built_ipc0_qcom0c0d_match=false")
PY

mkdir -p "$LOGDIR" "$MODROOT"

echo "A14_INSTALL_PROGRESS_UI=ENABLED"
echo "kernelrelease=$KREL"
echo "source=$SRC"
echo "build=$OUT"

run_activity() {
    local label="$1" logfile="$2"; shift 2
    "$@" >"$logfile" 2>&1 &
    local pid=$!
    set +e
    python3 "$PROGRESS" activity --pid "$pid" --label "$label"
    wait "$pid"
    local rc=$?
    set -e
    if (( rc != 0 )); then
        echo "ERROR: $label failed with exit code $rc" >&2
        tail -n 100 "$logfile" >&2 || true
        return "$rc"
    fi
}

# ---------------------------------------------------------------------------
# 1/5 modules_install — real count of final module files copied to MODROOT.
# Suppress Kbuild's internal depmod so depmod has its own visible phase below.
# Remove the previous in-tree module payload first, otherwise stale modules from
# an older config (for example AMDGPU) would survive a leaner rebuild.
# ---------------------------------------------------------------------------
echo
echo "===== 1/5 Install kernel modules ====="
rm -rf "$MODROOT/kernel"
rm -f "$MODROOT"/modules.{alias,alias.bin,builtin,builtin.alias.bin,builtin.bin,builtin.modinfo,dep,dep.bin,devname,softdep,symbols,symbols.bin} 2>/dev/null || true
modules_log="$LOGDIR/1-modules-install.log"
make -C "$SRC" O="$OUT" DEPMOD=/bin/true modules_install >"$modules_log" 2>&1 &
modules_pid=$!
set +e
python3 "$PROGRESS" modules --build "$OUT" --dest "$MODROOT" --pid "$modules_pid"
watch_rc=$?
wait "$modules_pid"
modules_rc=$?
set -e
if (( modules_rc != 0 )); then
    echo "ERROR: modules_install failed with exit code $modules_rc" >&2
    tail -n 120 "$modules_log" >&2 || true
    exit "$modules_rc"
fi
if (( watch_rc != 0 )); then
    echo "ERROR: modules_install exited but not every module from modules.order appeared in $MODROOT/kernel" >&2
    tail -n 120 "$modules_log" >&2 || true
    exit 1
fi
printf '[##########################################] 100%%  modules_install COMPLETE\n'

ln -sfn "$OUT" "$MODROOT/build"
ln -sfn "$SRC" "$MODROOT/source"

# ---------------------------------------------------------------------------
# 2/5 deterministic kernel artifacts.
# ---------------------------------------------------------------------------
echo
echo "===== 2/5 Install kernel artifacts ====="
printf '[##############----------------------------]  33%%  Image\r'
command install -m0644 "$OUT/arch/arm64/boot/Image" "/boot/vmlinuz-$KREL"
printf '[############################--------------]  67%%  config/System.map\r'
command install -m0644 "$OUT/.config" "/boot/config-$KREL"
[[ ! -s "$OUT/System.map" ]] || command install -m0644 "$OUT/System.map" "/boot/System.map-$KREL"
printf '[##########################################] 100%%  kernel artifacts COMPLETE\n'

# Binary provenance check before generating anything derived from this install.
cmp -s "$OUT/arch/arm64/boot/Image" "/boot/vmlinuz-$KREL" || die "installed Image does not match build output"
installed_sha="$(sha256sum "/boot/vmlinuz-$KREL" | awk '{print $1}')"
build_sha="$(sha256sum "$OUT/arch/arm64/boot/Image" | awk '{print $1}')"
[[ "$installed_sha" == "$build_sha" ]] || die "installed Image SHA-256 mismatch"
echo "INSTALLED_IMAGE_MATCHES_BUILD"
echo "installed_sha256=$installed_sha"

# ---------------------------------------------------------------------------
# 3/5 depmod. depmod does not expose meaningful per-module progress, so this is
# an explicit activity bar rather than a fabricated percentage.
# ---------------------------------------------------------------------------
echo
echo "===== 3/5 Generate module dependency database ====="
run_activity "depmod $KREL" "$LOGDIR/3-depmod.log" depmod -a "$KREL"
printf '[##########################################] 100%%  depmod COMPLETE\n'

# ---------------------------------------------------------------------------
# 4/5 initramfs. update-initramfs likewise has no trustworthy work denominator.
# ---------------------------------------------------------------------------
echo
echo "===== 4/5 Build initramfs ====="
rm -f "/boot/initrd.img-$KREL"
run_activity "update-initramfs $KREL" "$LOGDIR/4-initramfs.log" update-initramfs -c -k "$KREL"
[[ -s "/boot/initrd.img-$KREL" ]] || die "initramfs was not created"
printf '[##########################################] 100%%  initramfs COMPLETE\n'

# ---------------------------------------------------------------------------
# 5/5 generate only the current unrestricted ACPI-only test entry and GRUB cfg.
# Remove the older base helper's duplicate entry if present.
# ---------------------------------------------------------------------------
echo
echo "===== 5/5 Generate ACPI-only GRUB entry ====="
rm -f /etc/grub.d/41_a14_full_acpi
run_activity "GRUB / unrestricted ACPI entry" "$LOGDIR/5-grub.log" bash "$UNRESTRICTED"
printf '[##########################################] 100%%  GRUB COMPLETE\n'

echo
echo "A14_FULL_ACPI_INSTALL=COMPLETE"
echo "kernel=/boot/vmlinuz-$KREL"
echo "initrd=/boot/initrd.img-$KREL"
echo "installed_sha256=$installed_sha"
echo "hardware_dtb_loaded_by_test_entry=false"
echo "acpi_force=true"
echo "normal_running_kernel_untouched=true"
echo "Select the ACPI-ONLY UNRESTRICTED entry manually for the test boot."
