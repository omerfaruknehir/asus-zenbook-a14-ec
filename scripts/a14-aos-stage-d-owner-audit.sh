#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Read-only Stage D ownership/dependency audit for the X1E80100 AOS handoff.
# This script does not map or access CPAS MMIO, change clocks/power domains,
# contact SSC, or invoke Qualcomm SCM services.
set -Eeuo pipefail

stamp=$(date +%Y%m%d-%H%M%S)
out=${A14_AOS_STAGE_D_AUDIT_DIR:-"$HOME/Downloads/a14-aos-stage-d-owner-audit-$stamp"}
camss_dev=
camss_of=/sys/firmware/devicetree/base/soc@0/isp@acb7000

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

for tool in basename cat cp date dmesg find grep head id mkdir python3 readlink sed strings sudo tail tee tr uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this audit as your normal user, not with sudo"
case "$out" in
    ''|/|"$HOME"|"$HOME/Downloads") fail "unsafe output directory: $out" ;;
esac
[ ! -e "$out" ] || fail "output directory already exists: $out"
mkdir -p "$out/acpi" "$out/debugfs" "$out/sysfs"

exec > >(tee "$out/summary.txt") 2>&1

note 'A14 Stage D ownership/dependency audit'
note '========================================'
printf 'timestamp=%s\n' "$(date --iso-8601=seconds)"
printf 'kernel_release=%s\n' "$(uname -r)"
note 'operation=read-only-discovery'
note 'cpas_mmio_mapped=false'
note 'cpas_mmio_access=false'
note 'direct_readl_writel=false'
note 'scm_invocation=false'
note 'ssc_contacted=false'
note 'clock_state_change=false'
note 'power_domain_state_change=false'
note 'camera_stream_started=false'

cat /proc/cmdline > "$out/proc-cmdline.txt"
sudo cat /proc/iomem > "$out/proc-iomem.txt" 2>/dev/null || true

printf '\n%s\n' '===== CAMSS PLATFORM DEVICE ====='
for link in /sys/bus/platform/drivers/qcom-camss/*; do
    [ -L "$link" ] || continue
    candidate=$(readlink -f "$link")
    case "$candidate" in
        */acb7000.isp) camss_dev=$candidate; break ;;
    esac
done
if [ -z "$camss_dev" ]; then
    for link in /sys/bus/platform/drivers/qcom-camss/*; do
        [ -L "$link" ] || continue
        camss_dev=$(readlink -f "$link")
        break
    done
fi

if [ -n "$camss_dev" ]; then
    printf 'camss_device=%s\n' "$camss_dev"
    for p in power/runtime_status power/control power/runtime_active_time power/runtime_suspended_time; do
        if [ -r "$camss_dev/$p" ]; then
            printf '%s=%s\n' "${p//\//_}" "$(cat "$camss_dev/$p")"
        fi
    done
    if [ -r "$camss_dev/resource" ]; then
        cp "$camss_dev/resource" "$out/sysfs/camss-resource.txt"
        printf '%s\n' 'camss_resource_table:'
        cat "$camss_dev/resource"
    fi
else
    note 'camss_device=not-found'
fi

printf '\n%s\n' '===== CPAS WINDOW RESOURCE PROVENANCE ====='
python3 - "$out/proc-iomem.txt" <<'PY'
import re, sys
path = sys.argv[1]
want_lo = 0x0AC19000
want_hi = 0x0AC24FFF
print(f'query_window=0x{want_lo:08x}-0x{want_hi:08x}')
try:
    lines = open(path, encoding='utf-8', errors='replace').read().splitlines()
except OSError as exc:
    print(f'iomem_read_error={exc}')
    raise SystemExit(0)
found = 0
for line in lines:
    m = re.match(r'\s*([0-9a-fA-F]+)-([0-9a-fA-F]+)\s*:\s*(.*)', line)
    if not m:
        continue
    lo, hi = int(m.group(1), 16), int(m.group(2), 16)
    if lo <= want_hi and hi >= want_lo:
        found += 1
        print(f'overlap={lo:#x}-{hi:#x}:{m.group(3)}')
print(f'iomem_overlap_count={found}')
PY

printf '\n%s\n' '===== DEVICE-TREE OWNERSHIP ====='
if [ -d "$camss_of" ]; then
    printf 'camss_of_node=%s\n' "$camss_of"
    for prop in compatible reg-names clock-names power-domain-names interconnect-names; do
        if [ -r "$camss_of/$prop" ]; then
            printf '%s:\n' "$prop"
            tr '\0' '\n' < "$camss_of/$prop" | sed '/^$/d' | sed 's/^/  /'
        fi
    done
    if [ -r "$camss_of/reg" ]; then
        python3 - "$camss_of/reg" <<'PY'
import struct, sys
raw = open(sys.argv[1], 'rb').read()
if len(raw) % 16:
    print(f'reg_raw_bytes={len(raw)} (not an integral 4-cell tuple count)')
else:
    vals = struct.unpack('>' + 'I' * (len(raw)//4), raw)
    for n in range(0, len(vals), 4):
        ahi, alo, shi, slo = vals[n:n+4]
        addr = (ahi << 32) | alo
        size = (shi << 32) | slo
        print(f'  reg[{n//4}]={addr:#x}+{size:#x}')
PY
    fi
else
    note 'camss_of_node=not-present'
fi

snapshot_debugfs() {
    src=$1
    dst=$2
    if sudo test -r "$src"; then
        sudo cat "$src" > "$dst" 2>/dev/null || true
        [ -s "$dst" ]
    else
        return 1
    fi
}

printf '\n%s\n' '===== GENPD / CLOCK / INTERCONNECT STATE ====='
if snapshot_debugfs /sys/kernel/debug/pm_genpd/pm_genpd_summary "$out/debugfs/pm-genpd-summary.txt"; then
    note 'genpd_summary=available'
    grep -Ei 'cam|titan|mmcx|mxc|isp|ipe|ife|bps|sfe' "$out/debugfs/pm-genpd-summary.txt" || true
else
    note 'genpd_summary=unavailable'
fi

if snapshot_debugfs /sys/kernel/debug/clk/clk_summary "$out/debugfs/clk-summary.txt"; then
    note 'clk_summary=available'
    grep -Ei 'cam_cc_(titan|icp|cpas|camnoc|core|cci)|gcc_camera|mmcx|mxc' "$out/debugfs/clk-summary.txt" || true
else
    note 'clk_summary=unavailable'
fi

icc_src=
for p in /sys/kernel/debug/interconnect/interconnect_summary /sys/kernel/debug/interconnect_summary; do
    if sudo test -r "$p"; then icc_src=$p; break; fi
done
if [ -n "$icc_src" ] && snapshot_debugfs "$icc_src" "$out/debugfs/interconnect-summary.txt"; then
    printf 'interconnect_summary=%s\n' "$icc_src"
    grep -Ei 'cam|mnoc|isp|cpas' "$out/debugfs/interconnect-summary.txt" || true
else
    note 'interconnect_summary=unavailable'
fi

printf '\n%s\n' '===== GPIO / PMIC OWNERSHIP SNAPSHOTS ====='
if snapshot_debugfs /sys/kernel/debug/gpio "$out/debugfs/gpio.txt"; then
    note 'gpio_summary=available'
    grep -Ei 'cam|camera|privacy|cci|isp|sensor|aon' "$out/debugfs/gpio.txt" || true
else
    note 'gpio_summary=unavailable'
fi

if snapshot_debugfs /sys/kernel/debug/regulator/regulator_summary "$out/debugfs/regulator-summary.txt"; then
    note 'regulator_summary=available'
    grep -Ei 'cam|camera|cci|isp|sensor|vreg|pmic' "$out/debugfs/regulator-summary.txt" | head -n 250 || true
else
    note 'regulator_summary=unavailable'
fi

# Keep pinctrl state as a file for later correlation with any ACPI/GPIO mapping.
: > "$out/debugfs/pinctrl-files.txt"
for p in /sys/kernel/debug/pinctrl/*/pinmux-pins /sys/kernel/debug/pinctrl/*/pins; do
    if sudo test -r "$p"; then
        safe=$(printf '%s' "$p" | tr '/ ' '__')
        sudo cat "$p" > "$out/debugfs/$safe.txt" 2>/dev/null || true
        printf '%s\n' "$p" >> "$out/debugfs/pinctrl-files.txt"
    fi
done
if [ -s "$out/debugfs/pinctrl-files.txt" ]; then
    note 'pinctrl_snapshots=available'
else
    note 'pinctrl_snapshots=unavailable'
fi

printf '\n%s\n' '===== KERNEL SECURITY / OWNERSHIP CLUES ====='
sudo dmesg --color=never > "$out/dmesg.txt" 2>/dev/null || true
if [ -s "$out/dmesg.txt" ]; then
    grep -Ei 'cpas|camss|cam_cc|titan|mmcx|xpu|firewall|secure|permission|scm|smmu|aon|watchdog|SError' "$out/dmesg.txt" | tail -n 250 || true
else
    note 'dmesg=unavailable'
fi

printf '\n%s\n' '===== SCM PRESENCE (NO CALLS) ====='
if [ -d /sys/bus/platform/drivers/qcom_scm ]; then
    note 'qcom_scm_driver=present'
    find /sys/bus/platform/drivers/qcom_scm -maxdepth 1 -mindepth 1 -printf '%f\n' 2>/dev/null | sed 's/^/  /' || true
else
    note 'qcom_scm_driver=not-visible'
fi
grep -E '^qcom_scm[[:space:]]' /proc/modules 2>/dev/null || true

printf '\n%s\n' '===== ACPI / PEP-EQUIVALENT DEPENDENCY EVIDENCE ====='
acpi_tables=/sys/firmware/acpi/tables
if [ -d "$acpi_tables" ]; then
    note 'acpi_tables=available'
    copied=0
    for src in "$acpi_tables"/DSDT "$acpi_tables"/SSDT*; do
        [ -e "$src" ] || continue
        base=$(basename "$src")
        if sudo cat "$src" > "$out/acpi/$base.aml" 2>/dev/null; then
            copied=$((copied + 1))
        fi
    done
    printf 'acpi_tables_copied=%s\n' "$copied"

    : > "$out/acpi/string-hits.txt"
    for aml in "$out"/acpi/*.aml; do
        [ -s "$aml" ] || continue
        hits=$(strings -a "$aml" | grep -Ei '(^|[^A-Z0-9])(CAMP|AONC|QCOM0C32|QCOM0D06|QCOM0C17|CPAS|TITAN|MMCX|CAM_AON)([^A-Z0-9]|$)' || true)
        if [ -n "$hits" ]; then
            printf '%s\n' "--- $(basename "$aml") ---" >> "$out/acpi/string-hits.txt"
            printf '%s\n' "$hits" >> "$out/acpi/string-hits.txt"
        fi
    done
    if [ -s "$out/acpi/string-hits.txt" ]; then
        note 'acpi_string_hits:'
        cat "$out/acpi/string-hits.txt"
    else
        note 'acpi_string_hits=none'
    fi

    if command -v iasl >/dev/null 2>&1; then
        note 'iasl=available'
        mkdir -p "$out/acpi/dsl"
        for aml in "$out"/acpi/*.aml; do
            [ -s "$aml" ] || continue
            base=$(basename "$aml" .aml)
            (cd "$out/acpi/dsl" && iasl -d "../$(basename "$aml")" >/dev/null 2>&1) || true
            [ -e "$out/acpi/dsl/$base.dsl" ] || true
        done
        grep -RniE 'CAMP|AONC|QCOM0C32|QCOM0D06|QCOM0C17|CPAS|CAM_AON|OperationRegion|_DEP|_PR0|_PR3|_PS0|_PS3|_DSM' \
            "$out/acpi/dsl" > "$out/acpi/dsl-hits.txt" 2>/dev/null || true
        if [ -s "$out/acpi/dsl-hits.txt" ]; then
            note 'acpi_dsl_hits:'
            head -n 300 "$out/acpi/dsl-hits.txt"
        else
            note 'acpi_dsl_hits=none-or-disassembly-incomplete'
        fi
    else
        note 'iasl=not-installed'
    fi
else
    note 'acpi_tables=not-exposed-by-current-linux-boot'
fi

printf '\n%s\n' '===== RESULT ====='
note 'stage_d_audit=collected'
printf 'output_dir=%s\n' "$out"
note 'hardware_state_changed=false'
note 'cpas_mmio_access=false'
note 'ssc_contacted=false'
note 'Next step: inspect the collected ownership/dependency evidence before designing any Stage D hardware action.'
