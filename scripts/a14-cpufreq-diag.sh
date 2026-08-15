#!/usr/bin/env bash
set -u

try_load=0
[ "${1:-}" = --try-load ] && try_load=1

section()
{
  printf '\n===== %s =====\n' "$1"
}

read_config()
{
  local pattern='CONFIG_(CPU_FREQ|CPU_FREQ_STAT|CPU_FREQ_GOV_SCHEDUTIL|PM_OPP|MAILBOX|QCOM_CPUCP_MBOX|ARM_SCMI_PROTOCOL|ARM_SCMI_TRANSPORT_MAILBOX|ARM_SCMI_CPUFREQ)='
  if [ -r "/boot/config-$(uname -r)" ]; then
    grep -E "$pattern|# CONFIG_(QCOM_CPUCP_MBOX|ARM_SCMI_PROTOCOL|ARM_SCMI_TRANSPORT_MAILBOX|ARM_SCMI_CPUFREQ) is not set" "/boot/config-$(uname -r)" || true
  elif [ -r /proc/config.gz ]; then
    zgrep -E "$pattern|# CONFIG_(QCOM_CPUCP_MBOX|ARM_SCMI_PROTOCOL|ARM_SCMI_TRANSPORT_MAILBOX|ARM_SCMI_CPUFREQ) is not set" /proc/config.gz || true
  else
    echo 'kernel_config=unavailable'
  fi
}

show_policies()
{
  local found=0 p value
  shopt -s nullglob
  for p in /sys/devices/system/cpu/cpufreq/policy*; do
    found=1
    echo "--- $p"
    for value in affected_cpus related_cpus scaling_driver scaling_governor \
                 cpuinfo_min_freq cpuinfo_max_freq cpuinfo_cur_freq cpuinfo_avg_freq \
                 scaling_min_freq scaling_max_freq scaling_cur_freq scaling_available_frequencies; do
      if [ -r "$p/$value" ]; then
        printf '%s=' "$value"
        cat "$p/$value"
      fi
    done
  done
  shopt -u nullglob
  if [ "$found" -eq 0 ]; then
    echo 'cpufreq_policies=NONE'
    return 1
  fi
  return 0
}

section 'KERNEL'
uname -a
printf 'model='; tr -d '\000' </proc/device-tree/model 2>/dev/null || true; echo
printf 'compatible='; tr '\000' ' ' </proc/device-tree/compatible 2>/dev/null || true; echo

section 'CONFIG'
read_config

section 'CPU DT PERF DOMAINS'
for cpu in 0 4 8; do
  node="/sys/devices/system/cpu/cpu${cpu}/of_node"
  printf 'cpu%s: ' "$cpu"
  if [ -e "$node/power-domain-names" ]; then
    printf 'power-domain-names='
    tr '\000' ' ' <"$node/power-domain-names"
    echo
  else
    echo 'power-domain-names=missing'
  fi
done

section 'SCMI DEVICES'
for root in /sys/bus/scmi/devices /sys/bus/scmi_protocol/devices /sys/bus/platform/devices; do
  [ -d "$root" ] || continue
  echo "--- $root"
  find "$root" -maxdepth 1 -mindepth 1 -printf '%f\n' 2>/dev/null | grep -Ei 'scmi|cpucp' || true
done

section 'MODULES'
for m in qcom_cpucp_mbox scmi_core scmi_transport_mailbox scmi_cpufreq; do
  if modinfo "$m" >/dev/null 2>&1; then
    echo "$m=available"
  else
    echo "$m=not-a-module-or-absent"
  fi
done
lsmod | grep -Ei 'scmi|cpucp|cpufreq' || true

if [ "$try_load" -eq 1 ]; then
  section 'TRY STANDARD SCMI CPUFREQ LOAD'
  if [ "$(id -u)" -eq 0 ]; then
    runner=()
  elif command -v sudo >/dev/null 2>&1; then
    runner=(sudo)
  else
    runner=()
    echo 'cannot_try_load=no-root-helper'
  fi

  if [ "$(id -u)" -eq 0 ] || [ "${#runner[@]}" -gt 0 ]; then
    for m in qcom_cpucp_mbox scmi_transport_mailbox scmi_cpufreq; do
      echo "+ ${runner[*]} modprobe $m"
      "${runner[@]}" modprobe "$m" 2>&1 || true
    done
    sleep 1
  fi
fi

section 'CPUFREQ POLICIES'
if show_policies; then
  policy_count=$(find /sys/devices/system/cpu/cpufreq -maxdepth 1 -type d -name 'policy*' 2>/dev/null | wc -l)
  echo "cpufreq_policy_count=$policy_count"
  if [ "$policy_count" -ge 3 ]; then
    echo 'CPUFREQ_RUNTIME=PASS'
  else
    echo 'CPUFREQ_RUNTIME=PARTIAL'
  fi
else
  echo 'CPUFREQ_RUNTIME=FAIL'
fi

section 'KERNEL LOG'
if command -v journalctl >/dev/null 2>&1; then
  journalctl -k -b --no-pager 2>/dev/null | grep -Ei 'scmi|cpufreq|cpucp|performance domain|opp' | tail -n 160 || true
elif dmesg >/dev/null 2>&1; then
  dmesg | grep -Ei 'scmi|cpufreq|cpucp|performance domain|opp' | tail -n 160 || true
fi
