#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Collect the Linux-visible CAMSS clock, runtime-PM, power-domain and
# interconnect state from a normal boot. This script performs no sysfs writes,
# module changes, MMIO, SSC contact, suspend transition, or camera streaming.
set -Eeuo pipefail

release=$(uname -r)
report=${A14_AOS_NORMAL_POWER_AUDIT_REPORT:-"$HOME/Downloads/a14-aos-normal-power-state-audit.txt"}
camss_dev=
of_node=
cam_tmp=

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    set +e
    [ -z "$cam_tmp" ] || rm -f "$cam_tmp"
}
trap cleanup EXIT INT TERM

for tool in cam cat date find grep journalctl ls mktemp od readlink rm sed \
            sudo tee timeout tr uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done

[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this audit as your normal user, not with sudo"
case " $(cat /proc/cmdline) " in
    *' a14_aos_power_test=1 '*)
        fail "reboot into the normal Ubuntu entry before running this audit"
        ;;
esac

if grep -Eq '^qcom_ssc_hpd[[:space:]]' /proc/modules; then
    fail "qcom_ssc_hpd is loaded; refusing the audit until the next normal boot"
fi

for link in /sys/bus/platform/drivers/qcom-camss/*; do
    [ -L "$link" ] || continue
    candidate=$(readlink -f "$link")
    if [ -r "$candidate/power/runtime_status" ]; then
        camss_dev=$candidate
        break
    fi
done
[ -n "$camss_dev" ] || fail "the bound qcom-camss platform device was not found"
of_node="$camss_dev/of_node"
[ -e "$of_node" ] || fail "the live CAMSS device-tree node is unavailable"

sudo -v
exec > >(tee "$report") 2>&1

printf '%s\n' 'ASUS Zenbook A14 normal-boot CAMSS power-state audit'
printf '%s\n' '====================================================='
printf 'collected_at=%s\n' "$(date --iso-8601=seconds)"
printf 'kernel_release=%s\n' "$release"
printf 'boot_mode=normal\n'
printf 'device=%s\n' "$camss_dev"
printf 'operation=read-only\n'
printf 'sysfs_writes=false\n'
printf 'module_changes=false\n'
printf 'camera_streaming=false\n'
printf 'direct_cpas_mmio=false\n'
printf 'ssc_contact=false\n'

print_file() {
    label=$1
    file=$2
    if [ -r "$file" ]; then
        printf '%s=%s\n' "$label" "$(cat "$file")"
    else
        printf '%s=unavailable\n' "$label"
    fi
}

print_dt_strings() {
    label=$1
    file=$2
    printf '%s:\n' "$label"
    if [ -r "$file" ]; then
        tr '\0' '\n' < "$file" | sed '/^$/d'
    else
        printf 'unavailable\n'
    fi
}

printf '\n%s\n' '===== CAMSS RUNTIME PM: INITIAL IDLE ====='
print_file control "$camss_dev/power/control"
print_file runtime_status "$camss_dev/power/runtime_status"
print_file runtime_usage "$camss_dev/power/runtime_usage"
print_file runtime_active_time "$camss_dev/power/runtime_active_time"
print_file runtime_suspended_time "$camss_dev/power/runtime_suspended_time"
print_file autosuspend_delay_ms "$camss_dev/power/autosuspend_delay_ms"

printf '\n%s\n' '===== LIVE DEVICE-TREE RESOURCE DESCRIPTION ====='
print_dt_strings compatible "$of_node/compatible"
print_dt_strings clock_names "$of_node/clock-names"
print_dt_strings interconnect_names "$of_node/interconnect-names"
print_dt_strings power_domain_names "$of_node/power-domain-names"
for property in clocks interconnects power-domains operating-points-v2; do
    file="$of_node/$property"
    printf '%s_raw_u32:' "$property"
    if [ -r "$file" ]; then
        od -An -tx4 -v "$file" | tr -s ' ' | sed 's/^ / /'
    else
        printf ' unavailable\n'
    fi
done

printf '\n%s\n' '===== DEVICE LINKS ====='
for relation in supplier consumer; do
    found=false
    for link in "$camss_dev"/$relation:*; do
        [ -L "$link" ] || continue
        found=true
        printf '%s=%s\n' "$(basename "$link")" "$(readlink -f "$link")"
    done
    [ "$found" = true ] || printf '%s_links=none-visible\n' "$relation"
done

printf '\n%s\n' '===== RELEVANT CLOCK FRAMEWORK LINES ====='
clk_summary=/sys/kernel/debug/clk/clk_summary
clock_patterns=(
    cam_cc_camnoc_axi_rt_clk
    cam_cc_camnoc_axi_nrt_clk
    cam_cc_cpas_ahb_clk
    cam_cc_core_ahb_clk
    cam_cc_cpas_fast_ahb_clk
    gcc_camera_hf_axi_clk
    gcc_camera_sf_axi_clk
    camnoc_rt_axi
    camnoc_nrt_axi
    cpas_ahb
    core_ahb
    cpas_fast_ahb
    gcc_axi_hf
    gcc_axi_sf
)
if sudo test -r "$clk_summary"; then
    for pattern in "${clock_patterns[@]}"; do
        printf '\n-- clock-pattern=%s --\n' "$pattern"
        sudo grep -F "$pattern" "$clk_summary" || printf 'not-found\n'
    done
else
    printf 'clk_summary=unavailable\n'
fi

printf '\n%s\n' '===== CLOCK TREE CONTEXT FOR GCC CAMERA AXI CLOCKS ====='
if sudo test -r "$clk_summary"; then
    for pattern in gcc_camera_hf_axi_clk gcc_camera_sf_axi_clk; do
        printf '\n-- context=%s --\n' "$pattern"
        while IFS=: read -r line _; do
            [ -n "$line" ] || continue
            start=$((line > 6 ? line - 6 : 1))
            end=$((line + 3))
            sudo sed -n "${start},${end}p" "$clk_summary"
        done < <(sudo grep -n -F "$pattern" "$clk_summary" || true)
    done
fi

printf '\n%s\n' '===== GENERIC POWER DOMAINS ====='
genpd_summary=/sys/kernel/debug/pm_genpd/pm_genpd_summary
if sudo test -r "$genpd_summary"; then
    sudo cat "$genpd_summary"
else
    printf 'pm_genpd_summary=unavailable\n'
fi

printf '\n%s\n' '===== INTERCONNECT DEBUGFS ====='
if sudo test -d /sys/kernel/debug/interconnect; then
    sudo find /sys/kernel/debug/interconnect -maxdepth 2 -type f -print | sort
    for file in \
        /sys/kernel/debug/interconnect/interconnect_summary \
        /sys/kernel/debug/interconnect/interconnect_graph; do
        if sudo test -r "$file"; then
            printf '\n-- %s --\n' "$file"
            sudo cat "$file"
        fi
    done
else
    printf 'interconnect_debugfs=unavailable\n'
fi

printf '\n%s\n' '===== PRIVILEGED CAMERA ENUMERATION ====='
cam_tmp=$(mktemp)
set +e
sudo timeout 25 cam -l >"$cam_tmp" 2>&1
cam_status=$?
set -e
cat "$cam_tmp"
printf 'camera_enumeration_status=%s\n' "$cam_status"
if grep -Eq '^[[:space:]]*[0-9]+:' "$cam_tmp"; then
    printf 'accessible_camera_count=%s\n' "$(grep -Ec '^[[:space:]]*[0-9]+:' "$cam_tmp")"
else
    printf 'accessible_camera_count=0\n'
fi
rm -f "$cam_tmp"
cam_tmp=

printf '\n%s\n' '===== CAMSS RUNTIME PM: AFTER ENUMERATION ====='
print_file control "$camss_dev/power/control"
print_file runtime_status "$camss_dev/power/runtime_status"
print_file runtime_usage "$camss_dev/power/runtime_usage"
print_file runtime_active_time "$camss_dev/power/runtime_active_time"
print_file runtime_suspended_time "$camss_dev/power/runtime_suspended_time"

printf '\n%s\n' '===== RELEVANT KERNEL LOG ====='
sudo journalctl -k -b --no-pager -o short-monotonic |
    grep -Ei 'qcom-camss|qcom_camss|camss|camnoc|cpas|camera.*(clock|power|icc)|genpd|interconnect' || true

printf '\nreport=%s\n' "$report"
printf 'audit_result=complete\n'
