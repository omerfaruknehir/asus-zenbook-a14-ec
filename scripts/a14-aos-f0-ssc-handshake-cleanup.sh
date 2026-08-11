#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Safe cleanup/diagnostic for a qcom_ssc_hpd module left loaded by an A14
# full-F0 SSC handshake test. This does not activate SSC, alter F0 clocks or
# touch the CPAS ownership mux.
set -Eeuo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for tool in cat find grep lsmod readlink rmmod sudo; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done

printf '%s\n' 'A14 SSC diagnostic cleanup'
printf '%s\n' '=========================='
printf '%s\n' 'ssc_activation=false'
printf '%s\n' 'f0_resource_changes=false'
printf '%s\n' 'cpas_ownership_mux_access=false'

if ! grep -Eq '^qcom_ssc_hpd[[:space:]]' /proc/modules; then
    printf '%s\n' 'qcom_ssc_hpd_loaded=false'
    printf '%s\n' 'cleanup_result=already-unloaded'
    exit 0
fi

printf '%s\n' 'qcom_ssc_hpd_loaded=true'
lsmod | grep -E '^qcom_ssc_hpd[[:space:]]' || true

refcnt=unknown
if [ -r /sys/module/qcom_ssc_hpd/refcnt ]; then
    refcnt=$(cat /sys/module/qcom_ssc_hpd/refcnt)
fi
printf 'module_refcnt=%s\n' "$refcnt"

printf '%s\n' 'module_holders_begin'
holders=0
if [ -d /sys/module/qcom_ssc_hpd/holders ]; then
    for h in /sys/module/qcom_ssc_hpd/holders/*; do
        [ -e "$h" ] || continue
        holders=$((holders + 1))
        printf 'holder=%s\n' "$(basename "$(readlink -f "$h")")"
    done
fi
printf 'module_holders_count=%s\n' "$holders"
printf '%s\n' 'module_holders_end'

if [ -e /sys/bus/platform/devices/qcom-ssc-hpd-a14 ]; then
    printf '%s\n' 'platform_device_present=true'
else
    printf '%s\n' 'platform_device_present=false'
fi

printf '\n%s\n' '===== ATTEMPT DIRECT MODULE REMOVE ====='
# The diagnostic was loaded with insmod from a staging directory and is not
# necessarily indexed in /lib/modules. rmmod is therefore the correct symmetric
# unload operation; modprobe -r can fail before it ever asks the kernel to
# remove an unindexed module.
set +e
remove_output=$(sudo rmmod qcom_ssc_hpd 2>&1)
remove_rc=$?
set -e
[ -z "$remove_output" ] || printf '%s\n' "$remove_output"
printf 'rmmod_status=%s\n' "$remove_rc"

if grep -Eq '^qcom_ssc_hpd[[:space:]]' /proc/modules; then
    printf '%s\n' 'qcom_ssc_hpd_loaded_after_remove=true'
    refcnt_after=unknown
    [ ! -r /sys/module/qcom_ssc_hpd/refcnt ] || \
        refcnt_after=$(cat /sys/module/qcom_ssc_hpd/refcnt)
    printf 'module_refcnt_after=%s\n' "$refcnt_after"
    printf '%s\n' 'cleanup_result=remove-failed'
    exit 1
fi

printf '%s\n' 'qcom_ssc_hpd_loaded_after_remove=false'
printf '%s\n' 'cleanup_result=success'
