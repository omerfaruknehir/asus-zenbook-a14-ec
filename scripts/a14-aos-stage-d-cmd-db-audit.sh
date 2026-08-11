#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Read-only Stage D Command DB correlation audit for X1E80100 camera/AOS work.
#
# This script only reads the kernel's already-loaded Qualcomm Command DB via
# debugfs. It does not issue RPMh/ICC requests, change bandwidth, clocks or
# power domains, access CPAS MMIO, contact SSC, or invoke SCM.
set -Eeuo pipefail

out=${1:-"$HOME/Downloads/a14-stage-d-cmd-db-audit.txt"}
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for tool in cat date grep id mktemp python3 sudo uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done

[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run as your normal user, not with sudo"

case "$out" in
    ''|/) fail "unsafe output path: $out" ;;
esac

cmd_db=/sys/kernel/debug/cmd-db
if sudo test -r "$cmd_db"; then
    sudo cat "$cmd_db" > "$tmp"
else
    fail "$cmd_db is unavailable; ensure debugfs is mounted and CONFIG_QCOM_COMMAND_DB/DEBUG_FS are enabled"
fi

[ -s "$tmp" ] || fail "Command DB dump is empty"

{
    printf '%s\n' 'A14 Stage D Command DB correlation audit'
    printf '%s\n' '========================================'
    printf 'timestamp=%s\n' "$(date --iso-8601=seconds)"
    printf 'kernel_release=%s\n' "$(uname -r)"
    printf '%s\n' 'operation=read-only-command-db-dump'
    printf '%s\n' 'rpmh_request=false'
    printf '%s\n' 'icc_vote_change=false'
    printf '%s\n' 'clock_state_change=false'
    printf '%s\n' 'power_domain_state_change=false'
    printf '%s\n' 'cpas_mmio_access=false'
    printf '%s\n' 'ssc_contacted=false'
    printf '%s\n' 'scm_invocation=false'
    printf '\n'

    python3 - "$tmp" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8", errors="replace").splitlines()

# Camera-to-memory BCMs represented by the X1E80100 Linux ICC topology.
# MM1/MM0 cover MNOC camera traffic, SH1/SH0 cover the GEM/LLCC portion,
# and MC0/ACV cover the memory-controller tail.
camera_route_names = ("MM0", "MM1", "SH0", "SH1", "MC0", "ACV")

# The focused Windows CAMP trace contains three distinct RPMh-state groups.
# The first ICB request is state 0 (RPMH_SLEEP_STATE) and contains the camera
# fabric commands. Later state 2/1 requests are ACTIVE_ONLY/WAKE_ONLY aggregate
# updates; PC0/SN0 are valid Linux BCMs but are not camera-route resources.
windows_camera_sleep_batch = (0x50000, 0x50008, 0x50004, 0x50028, 0x50068)
windows_aggregate_batch = (0x50000, 0x50004, 0x5000C, 0x50010, 0x50068)
known_non_camera = {"PC0": "pcie-memory", "SN0": "system-noc-sf"}
windows_all = tuple(dict.fromkeys(windows_camera_sleep_batch + windows_aggregate_batch))

entry_re = re.compile(r"^\s*0x([0-9a-fA-F]+):\s*(\S+)")
entries = []
for line in lines:
    m = entry_re.match(line)
    if m:
        entries.append((int(m.group(1), 16), m.group(2), line.strip()))

by_name = {}
by_addr = {}
for addr, name, raw in entries:
    by_name.setdefault(name, []).append((addr, raw))
    by_addr.setdefault(addr, []).append((name, raw))

print("===== LINUX CAMERA-PATH BCM CANDIDATES =====")
for name in camera_route_names:
    vals = by_name.get(name, [])
    if not vals:
        print(f"{name}=not-found")
    else:
        for addr, raw in vals:
            print(f"{name}=0x{addr:05x}  {raw}")

print()
print("===== WINDOWS CAMERA SLEEP-STATE ICB BATCH =====")
for addr in windows_camera_sleep_batch:
    vals = by_addr.get(addr, [])
    if not vals:
        print(f"0x{addr:05x}=not-found")
    else:
        for name, raw in vals:
            print(f"0x{addr:05x}={name}  {raw}")

print()
print("===== WINDOWS ACTIVE/WAKE AGGREGATE ICB BATCH =====")
for addr in windows_aggregate_batch:
    vals = by_addr.get(addr, [])
    if not vals:
        print(f"0x{addr:05x}=not-found")
    else:
        for name, raw in vals:
            suffix = ""
            if name in known_non_camera:
                suffix = f"  route_class={known_non_camera[name]}"
            print(f"0x{addr:05x}={name}  {raw}{suffix}")

camera_addr_set = {
    addr for name in camera_route_names for addr, _raw in by_name.get(name, [])
}
all_known = {addr for addr in windows_all if by_addr.get(addr)}
camera_batch = set(windows_camera_sleep_batch)
camera_matches = sorted(camera_batch & camera_addr_set)
camera_unmatched = sorted(camera_batch - camera_addr_set)
aggregate_non_camera = []
for addr in windows_aggregate_batch:
    for name, _raw in by_addr.get(addr, []):
        if name in known_non_camera:
            aggregate_non_camera.append((addr, name, known_non_camera[name]))

print()
print("===== CORRELATION SUMMARY =====")
print("camera_route_names=" + ",".join(camera_route_names))
print("windows_camera_sleep_batch=" + ",".join(f"0x{x:05x}" for x in windows_camera_sleep_batch))
print("windows_aggregate_batch=" + ",".join(f"0x{x:05x}" for x in windows_aggregate_batch))
print(f"windows_all_command_db_resolved={len(all_known)}/{len(set(windows_all))}")
print("camera_batch_matches=" + (",".join(f"0x{x:05x}" for x in camera_matches) if camera_matches else "none"))
print("camera_batch_unmatched=" + (",".join(f"0x{x:05x}" for x in camera_unmatched) if camera_unmatched else "none"))
print(f"camera_batch_match_count={len(camera_matches)}/{len(camera_batch)}")
if aggregate_non_camera:
    print("aggregate_non_camera_cobatch=" + ",".join(
        f"0x{addr:05x}:{name}:{kind}" for addr, name, kind in aggregate_non_camera
    ))
else:
    print("aggregate_non_camera_cobatch=none")

if not camera_unmatched:
    print("correlation_result=windows-camera-icb-batch-maps-to-linux-camera-route-bcms")
elif camera_matches:
    print("correlation_result=partial-camera-route-match")
else:
    print("correlation_result=no-camera-route-match")

print("direct_cpas_mmio_authorized=false")
print("ssc_activation_authorized=false")
PY

    printf '\n%s\n' '===== EXACT COMMAND DB LINES FOR CORRELATED BCMs ====='
    grep -Ei '^\s*0x(50000|50004|50008|5000c|50010|50024|50028|50068):|:\s*(MM0|MM1|SH0|SH1|MC0|ACV|PC0|SN0)(\s|$)' "$tmp" || true
} | tee "$out"

printf '\nreport=%s\n' "$out"
