#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
EDK2_DIR=${EDK2_DIR:?set EDK2_DIR to an edk2-stable202605 checkout}
OUT=${OUT:-$ROOT/dist/A14ECReadback.efi}
PACKAGE=$EDK2_DIR/A14EcReadbackPkg

test -f "$EDK2_DIR/edksetup.sh"
test -x "$EDK2_DIR/BaseTools/Source/C/bin/GenFw"

rm -rf "$PACKAGE"
mkdir -p "$PACKAGE" "$(dirname "$OUT")"
cp "$ROOT/a14_ec_readback.c" "$PACKAGE/"
cp "$ROOT/A14EcReadback.inf" "$PACKAGE/"
cp "$ROOT/A14EcReadbackPkg.dsc" "$PACKAGE/"

export WORKSPACE=$EDK2_DIR
export EDK_TOOLS_PATH=$EDK2_DIR/BaseTools
export GCC5_AARCH64_PREFIX=${GCC5_AARCH64_PREFIX:-aarch64-linux-gnu-}

cd "$EDK2_DIR"
. ./edksetup.sh BaseTools >/dev/null
build -a AARCH64 -t GCC5 -b RELEASE \
  -p A14EcReadbackPkg/A14EcReadbackPkg.dsc

BUILT=$(find "$EDK2_DIR/Build/A14EcReadbackPkg" \
  -type f -path '*/AARCH64/A14ECReadback.efi' -print -quit)
test -n "$BUILT"
cp "$BUILT" "$OUT"

python3 "$ROOT/audit.py" "$OUT"
sha256sum "$OUT"
