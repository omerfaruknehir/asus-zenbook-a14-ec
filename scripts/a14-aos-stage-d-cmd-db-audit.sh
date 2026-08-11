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

# X1E80100 Linux ICC path candidates from drivers/interconnect/qcom/x1e80100.c.
# ACV and MC0 both cover EBI; MM0/MM1 cover MNOC; SH0/SH1 cover GEM/LLCC.
candidate_names = ("MM0", "MM1", "SH0", "SH1", "MC0", "ACV")

# Exact addresses observed in the sustained Windows CAMP activation burst.
windows_activation = (0x50000, 0x50004, 0x5000C, 0x50010, 0x50068)
# Additional qcpep ICB addresses seen elsewhere in the captured window.
windows_other = (0x50008, 0x50028)
windows_all = windows_activation + windows_other

entries = []
entry_re = re.compile(r"^\s*0x([0-9a-fA-F]+):\s*(\S+)")
for line in lines:
    m = entry_re.match(line)
    if m:
        entries.append((int(m.group(1), 16), m.group(2), line.strip()))

by_name = {name: [] for name in candidate_names}
by_addr = {addr: [] for addr in windows_all}
for addr, name, raw in entries:
    if name in by_name:
        by_name[name].append((addr, raw))
    if addr in by_addr:
        by_addr[addr].append((name, raw))

print("===== LINUX CAMERA-PATH BCM CANDIDATES =====")
for name in candidate_names:
    vals = by_name[name]
    if not vals:
        print(f"{name}=not-found")
    else:
        for addr, raw in vals:
            print(f"{name}=0x{addr:05x}  {raw}")

print()
print("===== WINDOWS SUSTAINED CAMP-ACTIVATION ICB ADDRESSES =====")
for addr in windows_activation:
    vals = by_addr[addr]
    if not vals:
        print(f"0x{addr:05x}=not-found")
    else:
        for name, raw in vals:
            print(f"0x{addr:05x}={name}  {raw}")

print()
print("===== ADDITIONAL WINDOWS-OBSERVED ICB ADDRESSES =====")
for addr in windows_other:
    vals = by_addr[addr]
    if not vals:
        print(f"0x{addr:05x}=not-found")
    else:
        for name, raw in vals:
            print(f"0x{addr:05x}={name}  {raw}")

candidate_addr_set = {
    addr for name in candidate_names for addr, _raw in by_name[name]
}
activation_set = set(windows_activation)
matched = sorted(activation_set & candidate_addr_set)
unmatched = sorted(activation_set - candidate_addr_set)

print()
print("===== CORRELATION SUMMARY =====")
print("candidate_names=" + ",".join(candidate_names))
print("windows_activation_addresses=" + ",".join(f"0x{x:05x}" for x in windows_activation))
print("activation_candidate_matches=" + (",".join(f"0x{x:05x}" for x in matched) if matched else "none"))
print("activation_candidate_unmatched=" + (",".join(f"0x{x:05x}" for x in unmatched) if unmatched else "none"))
print(f"activation_candidate_match_count={len(matched)}/{len(windows_activation)}")

# This is deliberately only a correlation result. A full match identifies the
# Windows ICB burst as the same BCM resources represented by Linux ICC, but it
# does not authorize CPAS MMIO or SSC activation.
if not unmatched:
    print("correlation_result=windows-activation-addresses-all-map-to-linux-camera-path-bcm-candidates")
elif matched:
    print("correlation_result=partial")
else:
    print("correlation_result=no-candidate-address-match")

print("direct_cpas_mmio_authorized=false")
print("ssc_activation_authorized=false")
PY

    printf '\n%s\n' '===== EXACT COMMAND DB LINES FOR CANDIDATES / WINDOWS ADDRESSES ====='
    grep -Ei '^\s*0x(50000|50004|50008|5000c|50010|50028|50068):|:\s*(MM0|MM1|SH0|SH1|MC0|ACV)(\s|$)' "$tmp" || true
} | tee "$out"

printf '\nreport=%s\n' "$out"
