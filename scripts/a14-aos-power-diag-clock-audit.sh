#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Read-only audit for the A14 CAMSS platform-power diagnostic prerequisites.
# This script performs no sysfs writes, MMIO, module changes, or SSC contact.
set -Eeuo pipefail

release=${A14_KERNEL_RELEASE:-$(uname -r)}
report=${A14_AOS_POWER_CLOCK_AUDIT_REPORT:-"$HOME/Downloads/a14-aos-power-clock-audit.txt"}
attr=
dev=
of_node=

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

for tool in cat date grep journalctl readlink sudo tr uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done

[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this script as your normal user, not with sudo"
case " $(cat /proc/cmdline) " in
    *' a14_aos_power_test=1 '*) ;;
    *) fail "this is not the isolated A14 power-diagnostic boot" ;;
esac

grep -Eq '^qcom_camss[[:space:]]' /proc/modules || fail "qcom_camss is not loaded"
if grep -Eq '^qcom_ssc_hpd[[:space:]]' /proc/modules; then
    fail "qcom_ssc_hpd is loaded; refusing even the read-only audit"
fi

for link in /sys/bus/platform/drivers/qcom-camss/*; do
    [ -L "$link" ] || continue
    candidate_dev=$(readlink -f "$link")
    candidate="$candidate_dev/a14_aon_power_diag/a14_aon_power_probe"
    if [ -e "$candidate" ]; then
        attr=$candidate
        dev=$candidate_dev
        break
    fi
done
[ -n "$attr" ] || fail "the loaded CAMSS module lacks the diagnostic-only attribute"

of_node="$dev/of_node"
[ -e "$of_node" ] || fail "CAMSS live device-tree node is unavailable: $of_node"

sudo -v
exec > >(tee "$report") 2>&1

printf '%s\n' 'A14 CAMSS power-diagnostic clock audit'
printf '%s\n' '======================================='
printf 'collected_at=%s\n' "$(date --iso-8601=seconds)"
printf 'kernel_release=%s\n' "$release"
printf 'device=%s\n' "$dev"
printf 'sysfs_attribute=%s\n' "$attr"
printf '%s\n' 'operation=read-only'
printf '%s\n' 'sysfs_writes=false'
printf '%s\n' 'direct_cpas_mmio=false'
printf '%s\n' 'ssc_contact=false'

printf '\n%s\n' '===== MODULE INITIALIZATION LOG ====='
sudo journalctl -k -b --no-pager -o short-monotonic |
    grep -E 'A14 power diagnostic|A14 non-MMIO|AON-POWER-DIAG|qcom-camss|qcom_camss' || true

printf '\n%s\n' '===== LIVE CAMSS DEVICE-TREE CLOCK NAMES ====='
clock_names_file="$of_node/clock-names"
if [ -r "$clock_names_file" ]; then
    tr '\0' '\n' < "$clock_names_file" | sed '/^$/d' | tee /tmp/a14-aon-clock-names.$$
    clock_names_tmp=/tmp/a14-aon-clock-names.$$
else
    printf 'clock_names_property=unreadable-or-absent\n'
    clock_names_tmp=
fi

printf '\n%s\n' '===== EXPECTED DIAGNOSTIC CLOCK MAPPING ====='
for clock in \
    camnoc_rt_axi \
    camnoc_nrt_axi \
    cpas_ahb \
    core_ahb \
    cpas_fast_ahb \
    gcc_axi_hf \
    gcc_axi_sf; do
    if [ -n "$clock_names_tmp" ] && grep -Fqx "$clock" "$clock_names_tmp"; then
        printf 'clock=%s dt_status=present\n' "$clock"
    else
        printf 'clock=%s dt_status=missing\n' "$clock"
    fi
done
[ -z "$clock_names_tmp" ] || rm -f "$clock_names_tmp"

printf '\n%s\n' '===== RUNTIME POWER STATE ====='
for property in control runtime_status runtime_active_time runtime_suspended_time; do
    file="$dev/power/$property"
    if [ -r "$file" ]; then
        printf '%s=%s\n' "$property" "$(cat "$file")"
    else
        printf '%s=unavailable\n' "$property"
    fi
done

printf '\n%s\n' '===== GLOBAL CLOCK FRAMEWORK VISIBILITY ====='
if sudo test -r /sys/kernel/debug/clk/clk_summary; then
    for clock in \
        camnoc_rt_axi \
        camnoc_nrt_axi \
        cpas_ahb \
        core_ahb \
        cpas_fast_ahb \
        gcc_axi_hf \
        gcc_axi_sf; do
        matches=$(sudo grep -F "$clock" /sys/kernel/debug/clk/clk_summary || true)
        if [ -n "$matches" ]; then
            printf '%s\n' "$matches"
        else
            printf 'clock=%s clk_summary_status=not-found\n' "$clock"
        fi
    done
else
    printf '%s\n' 'clk_summary=unavailable'
fi

printf '\nreport=%s\n' "$report"
printf '%s\n' 'audit_result=complete'
