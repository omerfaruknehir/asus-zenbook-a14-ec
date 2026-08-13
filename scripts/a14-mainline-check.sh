#!/usr/bin/env bash
set -euo pipefail

K=${1:-.}
[ -f "$K/Makefile" ] || { echo "not a Linux source tree: $K" >&2; exit 2; }

need=(
  arch/arm64/boot/dts/qcom/hamoa.dtsi
  arch/arm64/boot/dts/qcom/x1e80100-asus-zenbook-a14.dts
  drivers/media/platform/qcom/camss/camss.c
  drivers/i2c/busses/i2c-qcom-cci.c
)

missing=0
for f in "${need[@]}"; do
  if [ -f "$K/$f" ]; then
    echo "PASS $f"
  else
    echo "MISSING $f"
    missing=1
  fi
done

for label in camcc cci0 cci1 camss csiphy0 csiphy4; do
  if grep -Eq "^[[:space:]]*${label}:" "$K/arch/arm64/boot/dts/qcom/hamoa.dtsi" 2>/dev/null; then
    echo "PASS hamoa:$label"
  else
    echo "MISSING hamoa:$label"
    missing=1
  fi
done

if [ "$missing" -ne 0 ]; then
  echo RESULT=NEEDS_X1E_CAMERA_BASE_BACKPORT
  exit 3
fi

echo RESULT=READY