#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Temporary A14-only A/B test for Qualcomm charge-control disable semantics.
# Nothing is installed into /lib/modules. The replacement qcom_battmgr module
# remains active only until it is unloaded/rebooted.

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
action=${1:-status}
kernel=$(uname -r)
base=${kernel%%-*}
work=${A14_BATTMGR_TEST_DIR:-$HOME/Downloads/a14-qcom-battmgr-disable-test-$base}
bat=/sys/class/power_supply/qcom-battmgr-bat
patch_file="$repo/kernel-patches/battery/0001-qcom-battmgr-experimental-disable-charge-control.patch"
model=$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)
ok=1

show_status()
{
    echo "kernel=$kernel"
    echo "model=$model"
    if [ -d "$bat" ]; then
        for p in status capacity charge_control_start_threshold charge_control_end_threshold; do
            if [ -r "$bat/$p" ]; then
                printf '%s=' "$p"
                cat "$bat/$p"
            fi
        done
    else
        echo "battery_sysfs=missing"
    fi
    echo "loaded_qcom_battmgr=$(lsmod | awk '$1 == "qcom_battmgr" {print $1}' | head -n1)"
    echo "stock_module=$(modinfo -n qcom_battmgr 2>/dev/null || true)"
    if [ -f "$work/module/qcom_battmgr.ko" ]; then
        echo "test_module=$work/module/qcom_battmgr.ko"
        sha256sum "$work/module/qcom_battmgr.ko" 2>/dev/null || true
    fi
}

build_test_module()
{
    case "$model" in
        *"ASUS Zenbook A14 (UX3407RA)"*) ;;
        *)
            echo "ERROR: refusing experimental battery module on unexpected model: $model" >&2
            return 1
            ;;
    esac

    cfg=/boot/config-$kernel
    if [ ! -r "$cfg" ] || ! grep -Fxq 'CONFIG_BATTERY_QCOM_BATTMGR=m' "$cfg"; then
        echo "ERROR: running kernel does not expose qcom_battmgr as a module" >&2
        return 1
    fi
    if [ ! -e "/lib/modules/$kernel/build/Makefile" ]; then
        echo "ERROR: missing running-kernel headers: /lib/modules/$kernel/build" >&2
        return 1
    fi
    if [ ! -s "$patch_file" ]; then
        echo "ERROR: missing test patch: $patch_file" >&2
        return 1
    fi
    for cmd in patch sha256sum; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "ERROR: missing required command: $cmd" >&2
            return 1
        fi
    done

    rm -rf "$work/source" "$work/module"
    mkdir -p "$work/source/drivers/power/supply" "$work/module"

    url="https://raw.githubusercontent.com/gregkh/linux/v$base/drivers/power/supply/qcom_battmgr.c"
    echo "Fetching exact stable source: $url"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --connect-timeout 15 "$url" -o "$work/source/drivers/power/supply/qcom_battmgr.c" || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$work/source/drivers/power/supply/qcom_battmgr.c" "$url" || return 1
    else
        echo "ERROR: need curl or wget" >&2
        return 1
    fi

    echo "Checking experimental upstream disable patch against v$base"
    if ! patch --dry-run --batch -d "$work/source" -p1 --forward <"$patch_file"; then
        echo "ERROR: experimental patch does not apply cleanly to v$base" >&2
        return 1
    fi

    echo "Applying experimental upstream disable patch"
    patch --batch -d "$work/source" -p1 --forward <"$patch_file" || return 1

    if ! grep -Fq '.enable = cpu_to_le32(enable)' "$work/source/drivers/power/supply/qcom_battmgr.c"; then
        echo "ERROR: patched source does not contain firmware enable/disable control" >&2
        return 1
    fi
    if ! grep -Fq 'bool enable = start_soc != 0;' "$work/source/drivers/power/supply/qcom_battmgr.c"; then
        echo "ERROR: patched source does not recognize UPower start=0 as disable" >&2
        return 1
    fi

    cp "$work/source/drivers/power/supply/qcom_battmgr.c" "$work/module/qcom_battmgr.c" || return 1
    printf '%s\n' 'obj-m += qcom_battmgr.o' >"$work/module/Makefile"

    echo "Building temporary module against $kernel"
    A14_MODULE_DIR="$work/module" "$repo/scripts/a14-kbuild-compat.sh" "$kernel" || return 1
    if [ ! -s "$work/module/qcom_battmgr.ko" ]; then
        echo "ERROR: build completed without qcom_battmgr.ko" >&2
        return 1
    fi

    echo "Built: $work/module/qcom_battmgr.ko"
    sha256sum "$work/module/qcom_battmgr.ko"
}

load_test_module()
{
    if [ ! -s "$work/module/qcom_battmgr.ko" ]; then
        build_test_module || return 1
    fi

    echo "Unloading stock qcom_battmgr..."
    if ! sudo modprobe -r qcom_battmgr; then
        echo "ERROR: could not unload stock qcom_battmgr" >&2
        return 1
    fi

    echo "Loading temporary experimental qcom_battmgr..."
    if ! sudo insmod "$work/module/qcom_battmgr.ko"; then
        echo "ERROR: experimental module failed to load; restoring stock module" >&2
        sudo modprobe qcom_battmgr || true
        return 1
    fi

    if [ ! -d "$bat" ]; then
        echo "ERROR: battery power_supply did not return; restoring stock module" >&2
        sudo modprobe -r qcom_battmgr || true
        sudo modprobe qcom_battmgr || true
        return 1
    fi
}

run_disable_test()
{
    load_test_module || return 1

    echo
    echo "BEFORE experimental disable:"
    show_status
    echo
    echo "Sending UPower-style Maximize request directly: start=0, end=100"

    if ! printf '0\n' | sudo tee "$bat/charge_control_start_threshold" >/dev/null; then
        echo "ERROR: start=0 write failed; restoring stock module" >&2
        sudo modprobe -r qcom_battmgr || true
        sudo modprobe qcom_battmgr || true
        return 1
    fi
    if ! printf '100\n' | sudo tee "$bat/charge_control_end_threshold" >/dev/null; then
        echo "ERROR: end=100 write failed; restoring stock module" >&2
        sudo modprobe -r qcom_battmgr || true
        sudo modprobe qcom_battmgr || true
        return 1
    fi

    echo
    echo "AFTER experimental disable:"
    show_status
    echo
    echo "The test module is still loaded. Run this script with 'status' again after the charger state updates."
    echo "Run this script with 'restore' to unload it and return to the stock kernel module."
}

restore_stock()
{
    echo "Restoring stock qcom_battmgr module..."
    sudo modprobe -r qcom_battmgr || true
    if sudo modprobe qcom_battmgr; then
        echo "Stock module restored."
        show_status
        return 0
    fi
    echo "ERROR: stock qcom_battmgr failed to reload; reboot to restore the normal kernel driver" >&2
    return 1
}

case "$action" in
    build)
        build_test_module || ok=0
        ;;
    test)
        run_disable_test || ok=0
        ;;
    restore)
        restore_stock || ok=0
        ;;
    status)
        show_status
        ;;
    *)
        echo "usage: $0 {build|test|status|restore}" >&2
        ok=0
        ;;
esac

test "$ok" -eq 1
