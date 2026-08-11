#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Read-only verification after the full-F0 SSC discriminator.
set -Eeuo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for tool in cam cat grep lsmod readlink sudo timeout; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done

camss_dev=
for link in /sys/bus/platform/drivers/qcom-camss/*; do
    [ -L "$link" ] || continue
    camss_dev=$(readlink -f "$link")
    break
done
[ -n "$camss_dev" ] || fail "CAMSS platform device was not found"

printf '%s\n' 'A14 F0/SSC post-test verification'
printf '%s\n' '================================='
printf 'camss_device=%s\n' "$camss_dev"

if grep -Eq '^qcom_ssc_hpd[[:space:]]' /proc/modules; then
    printf '%s\n' 'qcom_ssc_hpd_loaded=true'
    fail "diagnostic HPD module is still loaded"
else
    printf '%s\n' 'qcom_ssc_hpd_loaded=false'
fi

cs=$(cat "$camss_dev/power/runtime_status" 2>/dev/null || true)
c0=$(cat /sys/bus/platform/devices/ac15000.cci/power/runtime_status 2>/dev/null || true)
c1=$(cat /sys/bus/platform/devices/ac16000.cci/power/runtime_status 2>/dev/null || true)
printf 'camss_runtime_status=%s\n' "$cs"
printf 'cci0_runtime_status=%s\n' "$c0"
printf 'cci1_runtime_status=%s\n' "$c1"

[ "$cs" = suspended ] || fail "CAMSS did not return to runtime suspend"
[ "$c0" = suspended ] || fail "CCI0 did not return to runtime suspend"
[ "$c1" = suspended ] || fail "CCI1 did not return to runtime suspend"

printf '\n%s\n' '===== CAMERA ENUMERATION ====='
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
set +e
sudo timeout 25 cam -l >"$tmp" 2>&1
rc=$?
set -e
cat "$tmp"
[ "$rc" -eq 0 ] || fail "camera enumeration failed with status $rc"
grep -Eq '^[[:space:]]*1:' "$tmp" || fail "camera 1 is missing after test"
grep -Eq '^[[:space:]]*2:' "$tmp" || fail "camera 2 is missing after test"

printf '\n%s\n' 'post_test_result=clean'
