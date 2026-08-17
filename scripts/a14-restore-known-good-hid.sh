#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Restore the committed pre-Fn-lock HID keyboard module without running the
# mutating prepare-a14-ec.py composition pipeline.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
KVER="${KVER:-$(uname -r)}"
WORK="/var/tmp/a14-hid-known-good-${KVER}"
BACKUP_DIR="/var/lib/asus-zenbook-a14-ec/hid-recovery"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"
for c in git modinfo depmod install strings grep; do need "$c"; done
command -v update-initramfs >/dev/null 2>&1 || die "update-initramfs not found"
[[ -e "/lib/modules/$KVER/build/Makefile" ]] || die "missing headers for $KVER"
[[ -x "$ROOT/scripts/a14-kbuild-compat.sh" ]] || die "missing kbuild compatibility wrapper"

git -C "$ROOT" rev-parse --verify HEAD >/dev/null
HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)"
BASE_BLOB="$(git -C "$ROOT" rev-parse HEAD:hid_asus_ec.c)"

rm -rf "$WORK"
mkdir -p "$WORK"
git -C "$ROOT" show HEAD:hid_asus_ec.c > "$WORK/hid_asus_ec.c"
cat > "$WORK/Makefile" <<'EOF'
obj-m += hid_asus_ec.o
EOF

# The committed source is the known-good pre-Fn-lock keyboard implementation.
grep -Fq 'static int asus_hid_initialise' "$WORK/hid_asus_ec.c" || die "committed HID source lacks old initializer"
grep -Fq '0xd0, 0x8f, 0x01' "$WORK/hid_asus_ec.c" || die "committed HID source lacks old OOBE/backlight bring-up sequence"
if grep -Fq 'A14_HID_FNLOCK_WINDOWS_FULL_FEATURE_REPORT' "$WORK/hid_asus_ec.c"; then
    die "committed HID source unexpectedly contains generated Fn-lock stack"
fi

say "recovery_head=$HEAD_SHA"
say "recovery_hid_blob=$BASE_BLOB"
say "recovery_source=$WORK/hid_asus_ec.c"

A14_MODULE_DIR="$WORK" \
A14_KBUILD_TARGET=modules \
"$ROOT/scripts/a14-kbuild-compat.sh" "$KVER"

BUILT="$WORK/hid_asus_ec.ko"
[[ -f "$BUILT" ]] || die "build did not produce $BUILT"
VERMAGIC="$(modinfo -F vermagic "$BUILT" 2>/dev/null || true)"
[[ "$VERMAGIC" == "$KVER "* || "$VERMAGIC" == "$KVER"* ]] || die "built vermagic does not match $KVER: $VERMAGIC"

# Guard against accidentally installing another generated Fn-lock module.
if strings "$BUILT" | grep -Fq 'Fn-lock hardware path ready'; then
    die "built recovery module still contains Fn-lock generated code"
fi
strings "$BUILT" | grep -Fq 'Zenbook A14 EC keyboard support enabled' || die "built module identity check failed"

CURRENT="$(modinfo -k "$KVER" -n hid_asus_ec 2>/dev/null || true)"
[[ -n "$CURRENT" && -f "$CURRENT" ]] || die "cannot resolve currently installed hid_asus_ec module"

mkdir -p "$BACKUP_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BACKUP_DIR/$(basename "$CURRENT").fnlock-regression-$STAMP"
cp -a "$CURRENT" "$BACKUP"
say "current_module=$CURRENT"
say "backup_module=$BACKUP"

TMP_INSTALL="${CURRENT}.a14-recovery-new"
rm -f "$TMP_INSTALL"
case "$CURRENT" in
    *.ko)
        install -m 0644 "$BUILT" "$TMP_INSTALL"
        ;;
    *.ko.zst)
        need zstd
        zstd -q -f "$BUILT" -o "$TMP_INSTALL"
        chmod 0644 "$TMP_INSTALL"
        ;;
    *.ko.xz)
        need xz
        xz -c -f "$BUILT" > "$TMP_INSTALL"
        chmod 0644 "$TMP_INSTALL"
        ;;
    *.ko.gz)
        need gzip
        gzip -c -f "$BUILT" > "$TMP_INSTALL"
        chmod 0644 "$TMP_INSTALL"
        ;;
    *)
        die "unsupported installed module compression: $CURRENT"
        ;;
esac
mv -f "$TMP_INSTALL" "$CURRENT"

# Keep the normal transport modules stock; this script changes only hid_asus_ec.
depmod -a "$KVER"
update-initramfs -u -k "$KVER"

RESOLVED="$(modinfo -k "$KVER" -n hid_asus_ec 2>/dev/null || true)"
say "resolved_hid_asus_ec=$RESOLVED"
[[ "$RESOLVED" == "$CURRENT" ]] || die "depmod resolved a different HID module: $RESOLVED"

say "A14_HID_KNOWN_GOOD_RECOVERY=INSTALLED"
say "Only hid_asus_ec was replaced. The currently loaded module remains unchanged until reboot."
say "Use a full power-off/power-on so the keyboard controller starts from a clean firmware state."
