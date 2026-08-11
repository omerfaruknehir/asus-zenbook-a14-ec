#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Read-only normal-boot audit of the Linux-visible resources that remain after
# the staged Windows-F0 clock-rate subset test. This script performs no sysfs
# writes, clock changes, module changes, MMIO, SSC contact, suspend transition,
# camera enumeration, or camera streaming.
set -Eeuo pipefail

report=${A14_AOS_F0_RESOURCE_AUDIT_REPORT:-"$HOME/Downloads/a14-aos-f0-resource-audit.txt"}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

for tool in basename cat date find grep od readlink sed sort sudo tee tr uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done

[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this audit as your normal user, not with sudo"
case " $(cat /proc/cmdline) " in
    *' a14_aos_power_test=1 '*|*' a14_aos_f0_rate_test=1 '*)
        fail "reboot into the normal Ubuntu entry before running this audit"
        ;;
esac

if grep -Eq '^qcom_ssc_hpd[[:space:]]' /proc/modules; then
    fail "qcom_ssc_hpd is loaded; refusing the audit until the next normal boot"
fi

sudo -v
exec > >(tee "$report") 2>&1

printf '%s\n' 'ASUS Zenbook A14 remaining Windows-F0 resource audit'
printf '%s\n' '====================================================='
printf 'collected_at=%s\n' "$(date --iso-8601=seconds)"
printf 'kernel_release=%s\n' "$(uname -r)"
printf 'boot_mode=normal\n'
printf 'operation=read-only\n'
printf 'sysfs_writes=false\n'
printf 'clock_changes=false\n'
printf 'module_changes=false\n'
printf 'camera_enumeration=false\n'
printf 'camera_streaming=false\n'
printf 'direct_cpas_mmio=false\n'
printf 'ssc_contact=false\n'

print_strings() {
    label=$1
    file=$2
    printf '%s:' "$label"
    if [ -r "$file" ]; then
        printf '\n'
        tr '\0' '\n' < "$file" | sed '/^$/d'
    else
        printf ' unavailable\n'
    fi
}

print_file() {
    label=$1
    file=$2
    if [ -r "$file" ]; then
        printf '%s=%s\n' "$label" "$(cat "$file")"
    else
        printf '%s=unavailable\n' "$label"
    fi
}

print_device() {
    dev=$1
    [ -e "$dev" ] || return 0

    printf '\n-- device=%s --\n' "$dev"
    if [ -L "$dev/driver" ]; then
        printf 'driver=%s\n' "$(basename "$(readlink -f "$dev/driver")")"
    else
        printf 'driver=unbound-or-unavailable\n'
    fi
    print_file runtime_control "$dev/power/control"
    print_file runtime_status "$dev/power/runtime_status"
    print_file runtime_usage "$dev/power/runtime_usage"

    if [ -e "$dev/of_node" ]; then
        print_strings compatible "$dev/of_node/compatible"
        print_strings clock_names "$dev/of_node/clock-names"
        print_strings power_domain_names "$dev/of_node/power-domain-names"
        print_strings interconnect_names "$dev/of_node/interconnect-names"
    else
        printf 'of_node=unavailable\n'
    fi

    for relation in supplier consumer; do
        found=false
        for link in "$dev"/$relation:*; do
            [ -L "$link" ] || continue
            found=true
            printf '%s=%s\n' "$(basename "$link")" "$(readlink -f "$link")"
        done
        [ "$found" = true ] || printf '%s_links=none-visible\n' "$relation"
    done
}

printf '\n%s\n' '===== TARGET DEVICE OWNERSHIP / RUNTIME PM ====='
for dev in \
    /sys/bus/platform/devices/ac15000.cci \
    /sys/bus/platform/devices/ac16000.cci \
    /sys/bus/platform/devices/acb7000.isp \
    /sys/bus/platform/devices/ade0000.clock-controller \
    /sys/bus/platform/devices/100000.clock-controller; do
    print_device "$dev"
done

printf '\n%s\n' '===== OTHER LIVE DT CONSUMERS WITH CCI / ICP CLOCK-NAMES ====='
consumer_count=0
while IFS= read -r file; do
    [ -r "$file" ] || continue
    if tr '\0' '\n' < "$file" | grep -Eiq '(^|[_-])(cci|icp)([_-]|$)|camnoc|cpas'; then
        node=$(readlink -f "$(dirname "$file")")
        printf '\n-- of_node=%s --\n' "$node"
        print_strings clock_names "$file"
        print_strings compatible "$(dirname "$file")/compatible"
        consumer_count=$((consumer_count + 1))
    fi
done < <(find /sys/firmware/devicetree/base -type f -name clock-names 2>/dev/null | sort)
printf 'matching_dt_consumer_count=%d\n' "$consumer_count"

printf '\n%s\n' '===== RELEVANT CLOCK FRAMEWORK LINES ====='
clk_summary=/sys/kernel/debug/clk/clk_summary
clock_patterns=(
    cam_cc_cci_0_clk
    cam_cc_cci_0_clk_src
    cam_cc_cci_1_clk
    cam_cc_cci_1_clk_src
    cam_cc_icp_ahb_clk
    cam_cc_icp_clk
    cam_cc_icp_clk_src
    cam_cc_camnoc_axi_rt_clk
    cam_cc_camnoc_axi_nrt_clk
    cam_cc_cpas_ahb_clk
    cam_cc_core_ahb_clk
    cam_cc_cpas_fast_ahb_clk
    cam_cc_gdsc_clk
    cam_cc_titan_top_gdsc
    gcc_camera_xo_clk
    gcc_camera_ahb_clk
    gcc_camera_hf_axi_clk
    gcc_camera_sf_axi_clk
)

if sudo test -r "$clk_summary"; then
    for pattern in "${clock_patterns[@]}"; do
        printf '\n-- clock-pattern=%s --\n' "$pattern"
        sudo grep -F "$pattern" "$clk_summary" || printf 'not-found\n'
    done
else
    printf 'clk_summary=unavailable\n'
fi

printf '\n%s\n' '===== CLOCK TREE CONTEXT FOR REMAINING F0 CLOCKS ====='
if sudo test -r "$clk_summary"; then
    for pattern in \
        cam_cc_cci_0_clk cam_cc_cci_1_clk cam_cc_icp_ahb_clk cam_cc_icp_clk \
        cam_cc_gdsc_clk gcc_camera_xo_clk gcc_camera_ahb_clk; do
        printf '\n-- context=%s --\n' "$pattern"
        while IFS=: read -r line _; do
            [ -n "$line" ] || continue
            start=$((line > 5 ? line - 5 : 1))
            end=$((line + 4))
            sudo sed -n "${start},${end}p" "$clk_summary"
        done < <(sudo grep -n -F "$pattern" "$clk_summary" || true)
    done
fi

printf '\n%s\n' '===== GENERIC POWER-DOMAIN FILTER ====='
genpd_summary=/sys/kernel/debug/pm_genpd/pm_genpd_summary
if sudo test -r "$genpd_summary"; then
    sudo grep -Ei 'cam_cc|camera|titan|ife|icp|cci|mmcx|mxc' "$genpd_summary" || true
else
    printf 'pm_genpd_summary=unavailable\n'
fi

printf '\n%s\n' '===== INTERCONNECT FILTER ====='
for file in \
    /sys/kernel/debug/interconnect/interconnect_summary \
    /sys/kernel/debug/interconnect/interconnect_graph; do
    if sudo test -r "$file"; then
        printf '\n-- %s --\n' "$file"
        sudo grep -Ei 'camnoc|acb7000\.isp|qnm_camnoc|qns_mem_noc|qnm_mnoc|camera' "$file" || true
    fi
done

printf '\n%s\n' '===== LIVE CAMSS DT PHANDLE SNAPSHOT ====='
camss_node=/sys/bus/platform/devices/acb7000.isp/of_node
if [ -e "$camss_node" ]; then
    for property in clocks interconnects power-domains operating-points-v2; do
        printf '%s_raw_u32:' "$property"
        if [ -r "$camss_node/$property" ]; then
            od -An -tx4 -v "$camss_node/$property" | tr -s ' ' | sed 's/^ / /'
        else
            printf ' unavailable\n'
        fi
    done
fi

printf '\nreport=%s\n' "$report"
printf 'audit_result=complete\n'
