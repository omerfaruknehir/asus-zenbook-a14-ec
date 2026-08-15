#!/usr/bin/env bash
set -euo pipefail

K=${1:-.}
[ -f "$K/Makefile" ] || { echo "not a Linux source tree: $K" >&2; exit 2; }

need=(
  arch/arm64/boot/dts/qcom/hamoa.dtsi
  arch/arm64/boot/dts/qcom/x1e80100-asus-zenbook-a14.dts
  drivers/cpufreq/scmi-cpufreq.c
  drivers/firmware/arm_scmi/perf.c
  drivers/firmware/arm_scmi/transports/mailbox.c
  drivers/mailbox/qcom-cpucp-mbox.c
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

hamoa="$K/arch/arm64/boot/dts/qcom/hamoa.dtsi"
for label in camcc cci0 cci1 camss csiphy0 csiphy4 scmi_dvfs cpucp_mbox; do
  if grep -Eq "^[[:space:]]*${label}:" "$hamoa" 2>/dev/null; then
    echo "PASS hamoa:$label"
  else
    echo "MISSING hamoa:$label"
    missing=1
  fi
done

# X1E80100 has three four-core Oryon performance domains. CPUFreq must be
# sourced from SCMI protocol 0x13, not invented in Resources/userspace.
for token in \
  'scmi_dvfs: protocol@13' \
  'power-domain-names = "psci", "perf"' \
  '<&scmi_dvfs 0>' \
  '<&scmi_dvfs 1>' \
  '<&scmi_dvfs 2>'; do
  if grep -Fq "$token" "$hamoa" 2>/dev/null; then
    echo "PASS hamoa:$token"
  else
    echo "MISSING hamoa:$token"
    missing=1
  fi
done

if [ "$missing" -ne 0 ]; then
  echo RESULT=NEEDS_X1E_MAINLINE_BASE_BACKPORT
  exit 3
fi

echo RESULT=READY
