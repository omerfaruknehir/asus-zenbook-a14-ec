#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Read-only validation for the first live A14 ACPI GPUCC stage.
set -u

sudo mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true

{
    echo "===== KERNEL ====="
    uname -r

    echo
    echo "===== GPUCC PLATFORM DEVICE ====="
    p=/sys/bus/platform/devices/gpucc-x1e80100
    if [[ -e "$p" ]]; then
        echo "device=$p"
        printf 'driver='
        if [[ -L "$p/driver" ]]; then readlink -f "$p/driver"; else echo UNBOUND; fi
        printf 'modalias='
        cat "$p/modalias" 2>/dev/null || echo NONE
        echo "resources:"
        cat "$p/resource" 2>/dev/null || true
    else
        echo MISSING
    fi

    echo
    echo "===== GPU / GMU MUST REMAIN UNBOUND ====="
    for p in \
        /sys/bus/platform/devices/a14-adreno-x185-acpi-topology \
        /sys/bus/platform/devices/a14-gmu-x185-acpi-topology
    do
        echo "--- ${p##*/} ---"
        if [[ ! -e "$p" ]]; then
            echo MISSING
            continue
        fi
        printf 'driver='
        if [[ -L "$p/driver" ]]; then readlink -f "$p/driver"; else echo UNBOUND; fi
    done

    echo
    echo "===== MODULES ====="
    lsmod | grep -E '^(msm|gpucc_x1e80100)\b' || true

    echo
    echo "===== GPUCC PARENTS / INTERNAL CLOCKS ====="
    sudo grep -Ei \
'bi-tcxo-div2-clk|gcc_gpu_gpll0_(cph|div_cph)_clk_src|gpu_cc_(pll0|pll1|gmu_clk_src|hub_clk_src|cxo_clk|cxo_aon_clk|ahb_clk|sleep_clk|hlos1_vote_gpu_smmu_clk)' \
        /sys/kernel/debug/clk/clk_summary 2>/dev/null || true

    echo
    echo "===== GPUCC GDSCS ====="
    sudo grep -Ei 'gpu_(cx|gx)_gdsc|gpu' \
        /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null || true

    echo
    echo "===== LIVE-STAGE BOOT TRACE ====="
    sudo dmesg | grep -Ei \
'A14GPUCC-LIVE|A14GPU-TOPOLOGY|gpucc-x1e80100|gpu_cc_|QCOM0C36|arm-smmu|SMMU|external abort|SError|imprecise external abort|translation fault' \
        || true

    echo
    echo "===== DEFERRED PROBES ====="
    cat /sys/kernel/debug/devices_deferred 2>/dev/null | \
        grep -Ei 'gpu|gmu|gpucc|clock|qcom0c36' || true

} | tee ~/a14-acpi-gpucc-live-v1.log
