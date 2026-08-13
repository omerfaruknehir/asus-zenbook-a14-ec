#!/usr/bin/env bash
set -euo pipefail

K="${1:-.}"
H="$K/arch/arm64/boot/dts/qcom/hamoa.dtsi"
A="$K/arch/arm64/boot/dts/qcom/x1-asus-zenbook-a14.dtsi"

fail=0

[[ -f "$H" ]] || { echo "MISSING $H"; fail=1; }
[[ -f "$A" ]] || { echo "MISSING $A"; fail=1; }

if [[ $fail -eq 0 ]]; then
  for label in camcc cci0 cci1 camss csiphy0 csiphy4; do
    if grep -Eq "^[[:space:]]*${label}:" "$H"; then
      echo "PASS hamoa:$label"
    else
      echo "MISSING hamoa:$label"
      fail=1
    fi
  done

  for include in 'dt-bindings/clock/qcom,x1e80100-camcc.h' 'dt-bindings/phy/phy.h'; do
    if grep -Fq "$include" "$H" "$A"; then
      echo "PASS include:$include"
    else
      echo "MISSING include:$include"
      fail=1
    fi
  done
fi

if [[ $fail -ne 0 ]]; then
  echo 'RESULT=NEEDS_X1E_CAMERA_DT_BACKPORT'
  exit 2
fi

echo 'RESULT=READY'
