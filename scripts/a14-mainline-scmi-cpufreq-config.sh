#!/usr/bin/env bash
set -euo pipefail

K=${1:-.}
K=$(CDPATH= cd -- "$K" 2>/dev/null && pwd) || {
  echo "kernel source path is not accessible: ${1:-.}" >&2
  exit 2
}

[ -f "$K/Makefile" ] || { echo "not a Linux source tree: $K" >&2; exit 2; }
[ -x "$K/scripts/config" ] || { echo "missing kernel scripts/config: $K/scripts/config" >&2; exit 2; }

hamoa="$K/arch/arm64/boot/dts/qcom/hamoa.dtsi"
[ -f "$hamoa" ] || { echo "missing Hamoa DT: $hamoa" >&2; exit 3; }
[ -f "$K/drivers/cpufreq/scmi-cpufreq.c" ] || {
  echo "kernel tree lacks SCMI CPUFreq driver" >&2
  exit 3
}
[ -f "$K/drivers/mailbox/qcom-cpucp-mbox.c" ] || {
  echo "kernel tree lacks Qualcomm CPUCP mailbox driver" >&2
  exit 3
}

for token in \
  'scmi_dvfs: protocol@13' \
  'power-domain-names = "psci", "perf"' \
  '<&scmi_dvfs 0>' \
  '<&scmi_dvfs 1>' \
  '<&scmi_dvfs 2>'; do
  if ! grep -Fq "$token" "$hamoa"; then
    echo "Hamoa DT lacks required SCMI DVFS token: $token" >&2
    exit 3
  fi
done

if [ ! -f "$K/.config" ]; then
  echo "No .config found; creating upstream arm64 defconfig first."
  make -C "$K" ARCH=arm64 defconfig
fi

cfg="$K/scripts/config"
# X1E80100/Hamoa uses CPUCP mailbox-backed SCMI Performance domains for its
# three Oryon CPU clusters. Keep this entire control path built-in so CPUFreq
# policies exist before A14 desktop/EC policy consumers start.
for symbol in \
  CPU_FREQ \
  CPU_FREQ_STAT \
  CPU_FREQ_GOV_SCHEDUTIL \
  PM_OPP \
  MAILBOX \
  QCOM_CPUCP_MBOX \
  ARM_SCMI_PROTOCOL \
  ARM_SCMI_TRANSPORT_MAILBOX \
  ARM_SCMI_CPUFREQ; do
  "$cfg" --enable "$symbol"
done

make -C "$K" ARCH=arm64 olddefconfig

failed=0
for symbol in \
  CPU_FREQ \
  CPU_FREQ_STAT \
  CPU_FREQ_GOV_SCHEDUTIL \
  PM_OPP \
  MAILBOX \
  QCOM_CPUCP_MBOX \
  ARM_SCMI_PROTOCOL \
  ARM_SCMI_TRANSPORT_MAILBOX \
  ARM_SCMI_CPUFREQ; do
  if grep -qx "CONFIG_${symbol}=y" "$K/.config"; then
    printf 'PASS CONFIG_%s=y\n' "$symbol"
  else
    printf 'FAIL CONFIG_%s expected built-in\n' "$symbol" >&2
    grep -E "^CONFIG_${symbol}=|^# CONFIG_${symbol} is not set" "$K/.config" >&2 || true
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  echo 'SCMI_CPUFREQ_CONFIG=FAIL' >&2
  exit 4
fi

printf '%s\n' 'SCMI_CPUFREQ_CONFIG=PASS'
printf '%s\n' 'expected_policies=policy0,policy4,policy8'
printf '%s\n' 'expected_domains=cpu0-3:0,cpu4-7:1,cpu8-11:2'
