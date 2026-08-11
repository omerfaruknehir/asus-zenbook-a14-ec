#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Recover the result of an already-executed combined F0 prerequisite hold.
# Read-only: no sysfs writes, camera acquisition, CPAS MMIO, SSC, ICP or ICC changes.
set -Eeuo pipefail

report=${A14_AOS_F0_COMBINED_RECOVERY_REPORT:-"$HOME/Downloads/a14-aos-f0-combined-recovery-report.txt"}
klog=${A14_AOS_F0_COMBINED_RECOVERY_KLOG:-"$HOME/Downloads/a14-aos-f0-combined-recovery-kernel.log"}
marker=${A14_AOS_F0_COMBINED_MARKER:-"$HOME/Downloads/a14-aos-f0-combined-last-run.txt"}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for tool in cat grep journalctl python3 readlink tee uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done

case " $(cat /proc/cmdline) " in
    *' a14_aos_f0_combined_test=1 '*) ;;
    *) fail "this is not the isolated A14 combined-F0 diagnostic boot" ;;
esac
if grep -Eq '^qcom_ssc_hpd[[:space:]]' /proc/modules; then
    fail "qcom_ssc_hpd is loaded; recovery stopped"
fi

camss_dev=
for link in /sys/bus/platform/drivers/qcom-camss/*; do
    [ -L "$link" ] || continue
    dev=$(readlink -f "$link")
    if [ -r "$dev/power/runtime_status" ]; then
        camss_dev=$dev
        break
    fi
done
[ -n "$camss_dev" ] || fail "CAMSS platform device was not found"

journalctl -k -b --no-pager -o short-monotonic > "$klog"

exec > >(tee "$report") 2>&1
printf '%s\n' 'A14 combined F0 prerequisite recovery'
printf '%s\n' '====================================='
printf 'kernel_release=%s\n' "$(uname -r)"
printf 'boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id)"
printf '%s\n' 'operation=offline-current-boot-log-recovery'
printf '%s\n' 'sysfs_writes=false'
printf '%s\n' 'camera_acquisition=false'
printf '%s\n' 'direct_cpas_mmio=false'
printf '%s\n' 'ssc_contacted=false'
printf '%s\n' 'icp_clock_manipulation=false'
printf '%s\n' 'raw_interconnect_manipulation=false'
printf 'source_marker=%s\n' "$marker"
printf 'kernel_log=%s\n' "$klog"

if [ -r "$marker" ]; then
    printf '\n%s\n' '===== ORIGINAL MARKER ====='
    cat "$marker"
fi

printf '\n%s\n' '===== CURRENT FRAMEWORK STATE ====='
printf 'camss_runtime_status=%s\n' "$(cat "$camss_dev/power/runtime_status")"
printf 'cci0_runtime_status=%s\n' "$(cat /sys/bus/platform/devices/ac15000.cci/power/runtime_status)"
printf 'cci1_runtime_status=%s\n' "$(cat /sys/bus/platform/devices/ac16000.cci/power/runtime_status)"
for d in ac15000.cci ac16000.cci; do
    status="/sys/bus/platform/devices/$d/a14_f0_cci_rate_diag/a14_f0_cci_rate_status"
    [ -r "$status" ] && printf '%s_status=%s\n' "$d" "$(cat "$status")"
done
camss_status="$camss_dev/a14_f0_rate_diag/a14_f0_rate_status"
[ -r "$camss_status" ] && printf 'camss_status=%s\n' "$(cat "$camss_status")"

printf '\n%s\n' '===== RECOVER LATEST COMBINED HOLD ====='
python3 - "$klog" <<'PY'
import re
import sys

path = sys.argv[1]
ts = r"^\[\s*([0-9]+(?:\.[0-9]+)?)\]"
patterns = {
    "camss": re.compile(ts + r".*AON-F0-RATE-DIAG phase=3 targets-ok hold-ms=250"),
    "cci0": re.compile(ts + r".*AON-F0-CCI-RATE-DIAG target-ok device=ac15000\.cci hold-ms=250"),
    "cci1": re.compile(ts + r".*AON-F0-CCI-RATE-DIAG target-ok device=ac16000\.cci hold-ms=250"),
}
complete_patterns = {
    "camss": re.compile(ts + r".*AON-F0-RATE-DIAG complete phase=3 ret=(-?\d+) restore-ret=(-?\d+)"),
    "cci0": re.compile(ts + r".*AON-F0-CCI-RATE-DIAG complete device=ac15000\.cci ret=(-?\d+) restore-ret=(-?\d+)"),
    "cci1": re.compile(ts + r".*AON-F0-CCI-RATE-DIAG complete device=ac16000\.cci ret=(-?\d+) restore-ret=(-?\d+)"),
}
fault = re.compile(r"(?i)(watchdog|panic|SError|Call trace|Internal error|Oops)")

lines = []
with open(path, "r", encoding="utf-8", errors="replace") as fh:
    lines = list(fh)

targets = {}
for line in lines:
    for key, pat in patterns.items():
        m = pat.search(line)
        if m:
            targets[key] = float(m.group(1))

missing = [k for k in patterns if k not in targets]
if missing:
    print("recovery_status=missing-target-markers")
    print("missing=" + ",".join(missing))
    raise SystemExit(2)

# The runner launches all three stores together; require the latest target markers
# to belong to one tight cluster rather than accidentally combining old tests.
span_ms = (max(targets.values()) - min(targets.values())) * 1000.0
overlap_ms = 250.0 - span_ms
for key in ("cci0", "cci1", "camss"):
    print(f"{key}_target_hold_start_monotonic={targets[key]:.6f}")
print(f"target_hold_start_span_ms={span_ms:.3f}")
print(f"minimum_common_hold_overlap_ms={overlap_ms:.3f}")
if span_ms > 1000.0:
    print("recovery_status=target-markers-not-one-cluster")
    raise SystemExit(3)
if overlap_ms < 100.0:
    print("overlap_status=too-short")
    raise SystemExit(4)
print("overlap_status=validated-at-least-100ms")

start = min(targets.values()) - 0.050
end = max(targets.values()) + 1.000
completes = {}
fault_lines = []
for line in lines:
    mt = re.match(ts, line)
    if not mt:
        continue
    t = float(mt.group(1))
    if not (start <= t <= end):
        continue
    if fault.search(line):
        fault_lines.append(line.rstrip())
    for key, pat in complete_patterns.items():
        m = pat.search(line)
        if m:
            completes[key] = (float(m.group(1)), int(m.group(2)), int(m.group(3)), line.rstrip())

for key in ("cci0", "cci1", "camss"):
    if key not in completes:
        print(f"{key}_complete=missing")
        continue
    _, ret, restore, _ = completes[key]
    print(f"{key}_complete_ret={ret}")
    print(f"{key}_restore_ret={restore}")

if fault_lines:
    print("kernel_fault_status=detected")
    for line in fault_lines:
        print("fault=" + line)
    raise SystemExit(5)
print("kernel_fault_status=none-in-combined-window")

# CAMSS -ERANGE/-ERANGE is the already-known inability to reconstruct the parked
# 19.2 MHz CAMNOC rate after the successful 300 MHz target hold.
if "camss" in completes:
    _, ret, restore, _ = completes["camss"]
    if (ret, restore) == (-34, -34):
        print("camss_return_class=known-camnoc-restore-erange-after-successful-hold")
    elif ret == 0:
        print("camss_return_class=success")
    else:
        print("camss_return_class=unexpected")
        raise SystemExit(6)

for key in ("cci0", "cci1"):
    if key in completes and completes[key][1] != 0:
        print(f"{key}_return_class=unexpected")
        raise SystemExit(7)

print("recovery_status=combined-hold-validated")
print("authorization_for_cpas_mmio=false")
PY

printf '\n%s\n' '===== RELEVANT LATEST KERNEL MARKERS ====='
grep -E 'AON-F0-RATE-DIAG|AON-F0-CCI-RATE-DIAG|watchdog|panic|SError|Call trace|Internal error|Oops' "$klog" | tail -n 80 || true

printf '\nreport=%s\n' "$report"
printf 'kernel_log=%s\n' "$klog"
