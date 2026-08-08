#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Hold both CCI 37.5 MHz targets concurrently with CAMSS F0 phase 3.
# Framework APIs only: no CPAS MMIO, SSC, ICP, raw ICC, or DT changes.
set -Eeuo pipefail

release=${A14_KERNEL_RELEASE:-$(uname -r)}
report=${A14_AOS_F0_COMBINED_REPORT:-"$HOME/Downloads/a14-aos-f0-combined-report.txt"}
marker=${A14_AOS_F0_COMBINED_MARKER:-"$HOME/Downloads/a14-aos-f0-combined-last-run.txt"}
klog=${A14_AOS_F0_COMBINED_KLOG:-"$HOME/Downloads/a14-aos-f0-combined-kernel.log"}
camss_probe=
camss_status=
cci0_dev=/sys/bus/platform/devices/ac15000.cci
cci1_dev=/sys/bus/platform/devices/ac16000.cci
cci0_probe="$cci0_dev/a14_f0_cci_rate_diag/a14_f0_cci_rate_probe"
cci1_probe="$cci1_dev/a14_f0_cci_rate_diag/a14_f0_cci_rate_probe"
cci0_status="$cci0_dev/a14_f0_cci_rate_diag/a14_f0_cci_rate_status"
cci1_status="$cci1_dev/a14_f0_cci_rate_diag/a14_f0_cci_rate_status"
media_stopped=false
cam_tmp=

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
cleanup() {
    set +e
    [ -z "$cam_tmp" ] || rm -f "$cam_tmp"
    if [ "$media_stopped" = true ]; then
        systemctl --user start pipewire.socket pipewire-pulse.socket 2>/dev/null
        systemctl --user start pipewire.service pipewire-pulse.service wireplumber.service 2>/dev/null
    fi
}
trap cleanup EXIT INT TERM

for tool in cam cat date fuser grep journalctl mktemp python3 readlink rm sleep sudo sync systemctl tee timeout uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this script as your normal user, not with sudo"
case " $(cat /proc/cmdline) " in
    *' a14_aos_f0_combined_test=1 '*) ;;
    *) fail "this is not the isolated A14 combined-F0 diagnostic boot" ;;
esac

grep -Eq '^qcom_camss[[:space:]]' /proc/modules || fail "qcom_camss is not loaded"
grep -Eq '^i2c_qcom_cci[[:space:]]' /proc/modules || fail "i2c_qcom_cci is not loaded"
if grep -Eq '^qcom_ssc_hpd[[:space:]]' /proc/modules; then
    fail "qcom_ssc_hpd is loaded; the combined diagnostic was not attempted"
fi

for link in /sys/bus/platform/drivers/qcom-camss/*; do
    [ -L "$link" ] || continue
    dev=$(readlink -f "$link")
    p="$dev/a14_f0_rate_diag/a14_f0_rate_probe"
    s="$dev/a14_f0_rate_diag/a14_f0_rate_status"
    if [ -e "$p" ] && [ -r "$s" ]; then
        camss_probe=$p
        camss_status=$s
        break
    fi
done
[ -n "$camss_probe" ] || fail "combined boot lacks the CAMSS F0 diagnostic"
for f in "$cci0_probe" "$cci1_probe" "$cci0_status" "$cci1_status"; do
    [ -e "$f" ] || fail "combined boot lacks CCI diagnostic attribute: $f"
done

validate_camss_status() {
    s=$(cat "$camss_status")
    case " $s " in *' ready=1 '*) ;; *) fail "CAMSS diagnostic is not ready: $s" ;; esac
    case " $s " in *' clock_get_status=0 '*) ;; *) fail "CAMSS clock lookup failed: $s" ;; esac
    case " $s " in *' round_status=0 '*) ;; *) fail "CAMSS exact F0 targets unsupported: $s" ;; esac
    case " $s " in *' failed_clock=none '*) ;; *) fail "CAMSS has a failed clock: $s" ;; esac
    printf 'camss_status=%s\n' "$s"
}

validate_cci_status() {
    dev=$1
    status_file=$2
    s=$(cat "$status_file")
    case " $s " in *' ready=1 '*) ;; *) fail "$dev diagnostic is not ready: $s" ;; esac
    case " $s " in *' clock_status=0 '*) ;; *) fail "$dev CCI clock lookup failed: $s" ;; esac
    case " $s " in *' round_status=0 '*) ;; *) fail "$dev exact 37.5 MHz unsupported: $s" ;; esac
    printf '%s_status=%s\n' "$dev" "$s"
}

wait_all_idle() {
    label=$1
    attempt=0
    while [ "$attempt" -lt 20 ]; do
        cs=$(cat "${camss_status%/a14_f0_rate_diag/a14_f0_rate_status}/power/runtime_status" 2>/dev/null || true)
        c0=$(cat "$cci0_dev/power/runtime_status" 2>/dev/null || true)
        c1=$(cat "$cci1_dev/power/runtime_status" 2>/dev/null || true)
        if [ "$cs" = suspended ] && [ "$c0" = suspended ] && [ "$c1" = suspended ]; then
            printf '%s_camss_runtime_status=%s\n' "$label" "$cs"
            printf '%s_cci0_runtime_status=%s\n' "$label" "$c0"
            printf '%s_cci1_runtime_status=%s\n' "$label" "$c1"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    printf '%s_camss_runtime_status=%s\n' "$label" "$cs"
    printf '%s_cci0_runtime_status=%s\n' "$label" "$c0"
    printf '%s_cci1_runtime_status=%s\n' "$label" "$c1"
    fail "CAMSS and both CCI controllers did not all reach runtime-suspended state"
}

camera_list() {
    label=$1
    cam_tmp=$(mktemp)
    set +e
    sudo timeout 25 cam -l >"$cam_tmp" 2>&1
    status=$?
    set -e
    cat "$cam_tmp"
    [ "$status" -eq 0 ] || fail "$label camera enumeration failed with status $status"
    grep -Eq '^[[:space:]]*[0-9]+:' "$cam_tmp" || fail "$label camera enumeration returned no accessible cameras"
    rm -f "$cam_tmp"
    cam_tmp=
}

validate_camss_status
validate_cci_status ac15000.cci "$cci0_status"
validate_cci_status ac16000.cci "$cci1_status"

sudo -v
systemctl --user stop pipewire-pulse.socket pipewire.socket 2>/dev/null || true
systemctl --user stop wireplumber.service pipewire-pulse.service pipewire.service 2>/dev/null || true
media_stopped=true
sleep 2
users=$(sudo fuser /dev/video* /dev/media* /dev/v4l-subdev* 2>/dev/null || true)
if [ -n "$users" ]; then
    sudo fuser -v /dev/video* /dev/media* /dev/v4l-subdev* 2>&1 || true
    fail "camera/media nodes remain busy; combined hold was not attempted"
fi

printf '%s\n' 'A14 combined Windows-F0 prerequisite diagnostic'
printf '%s\n' '==============================================='
printf 'kernel_release=%s\n' "$release"
printf '%s\n' 'camss_phase=3'
printf '%s\n' 'camss_targets=camnoc_rt_axi:300000000,camnoc_nrt_axi:300000000,cpas_ahb:80000000,core_ahb:80000000,cpas_fast_ahb:100000000'
printf '%s\n' 'cci0_target=37500000'
printf '%s\n' 'cci1_target=37500000'
printf '%s\n' 'per_probe_hold_ms=250'
printf '%s\n' 'direct_cpas_mmio=false'
printf '%s\n' 'ssc_contacted=false'
printf '%s\n' 'icp_clock_manipulation=false'
printf '%s\n' 'raw_interconnect_manipulation=false'
printf '%s\n' 'dtb_changes=false'
printf '%s\n' 'overlap_required=true'

printf '\n%s\n' '===== PRE-PROBE CAMERA BASELINE ====='
camera_list pre-probe
printf '%s\n' 'camera_baseline=validated-accessible-camera'
users=$(sudo fuser /dev/video* /dev/media* /dev/v4l-subdev* 2>/dev/null || true)
[ -z "$users" ] || fail "camera/media nodes reopened after baseline"

printf '\n%s\n' '===== WAIT FOR ALL THREE PLATFORM DEVICES TO IDLE ====='
wait_all_idle pre
validate_camss_status
validate_cci_status ac15000.cci "$cci0_status"
validate_cci_status ac16000.cci "$cci1_status"

boot_id=$(cat /proc/sys/kernel/random/boot_id)
started=$(date --iso-8601=ns)
cat > "$marker" <<EOF_MARKER
operation=platform-power-f0-combined-framework-only
boot_id=$boot_id
started=$started
status=started
camss_phase=3
cci0_target=37500000
cci1_target=37500000
per_probe_hold_ms=250
direct_cpas_mmio=false
ssc_contacted=false
icp_clock_manipulation=false
raw_interconnect_manipulation=false
dtb_changes=false
overlap_required=true
EOF_MARKER
sync "$marker"; sync

exec > >(tee "$report") 2>&1
printf '\n%s\n' '===== EXECUTE CONCURRENT FRAMEWORK-MANAGED HOLDS ====='
printf 'boot_id=%s\n' "$boot_id"
printf 'probe_started_at=%s\n' "$started"
printf '%s\n' 'launch_order=cci0,cci1,camss-phase3-background'
printf '%s\n' 'direct_cpas_mmio=false'
printf '%s\n' 'ssc_contacted=false'

# sudo credentials are already cached. Each sysfs store blocks for its 250 ms
# diagnostic hold, so backgrounding the three stores gives an actual overlap.
set +e
sudo sh -c 'printf "1\n" > "$1"' sh "$cci0_probe" & p0=$!
sudo sh -c 'printf "1\n" > "$1"' sh "$cci1_probe" & p1=$!
sudo sh -c 'printf "3\n" > "$1"' sh "$camss_probe" & pc=$!
wait "$p0"; cci0_rc=$?
wait "$p1"; cci1_rc=$?
wait "$pc"; camss_rc=$?
set -e

completed=$(date --iso-8601=ns)
printf 'cci0_write_status=%s\n' "$cci0_rc"
printf 'cci1_write_status=%s\n' "$cci1_rc"
printf 'camss_write_status=%s\n' "$camss_rc"

sudo journalctl -k -b --since "$started" --no-pager -o short-monotonic > "$klog"
printf '\n%s\n' '===== RELEVANT KERNEL LOG ====='
grep -E 'AON-F0-RATE-DIAG|AON-F0-CCI-RATE-DIAG|A14 F0 rate diagnostic|A14 F0 CCI rate diagnostic|qcom-camss|i2c-qcom-cci|watchdog|panic|SError|Call trace|Internal error|Oops' "$klog" || true

[ "$cci0_rc" -eq 0 ] || fail "CCI0 combined write failed"
[ "$cci1_rc" -eq 0 ] || fail "CCI1 combined write failed"
grep -Fq 'AON-F0-RATE-DIAG phase=3 targets-ok hold-ms=250' "$klog" || fail "CAMSS phase-3 target hold was not reached"
grep -Fq 'AON-F0-CCI-RATE-DIAG target-ok device=ac15000.cci hold-ms=250' "$klog" || fail "CCI0 target hold was not reached"
grep -Fq 'AON-F0-CCI-RATE-DIAG target-ok device=ac16000.cci hold-ms=250' "$klog" || fail "CCI1 target hold was not reached"

# CAMNOC's public rate table cannot reconstruct the pre-test 19.2 MHz parked
# value after explicit programming. The previous phase-3 test therefore may
# return -ERANGE solely on restore while still completing the safe target hold.
if [ "$camss_rc" -ne 0 ]; then
    grep -Eq 'AON-F0-RATE-DIAG complete phase=3 ret=-34 restore-ret=-34' "$klog" || \
        fail "CAMSS failed for a reason other than the known CAMNOC restore limitation"
    printf '%s\n' 'camss_return_class=known-camnoc-restore-erange-after-successful-hold'
else
    printf '%s\n' 'camss_return_class=success'
fi

if grep -Eq 'watchdog|panic|SError|Call trace|Internal error|Oops' "$klog"; then
    fail "kernel fault marker detected during combined hold"
fi

printf '\n%s\n' '===== VERIFY TARGET-HOLD OVERLAP ====='
set +e
python3 - "$klog" <<'PY'
import re
import sys

path = sys.argv[1]
patterns = {
    "camss": re.compile(r"^\[\s*([0-9]+(?:\.[0-9]+)?)\].*AON-F0-RATE-DIAG phase=3 targets-ok hold-ms=250"),
    "cci0": re.compile(r"^\[\s*([0-9]+(?:\.[0-9]+)?)\].*AON-F0-CCI-RATE-DIAG target-ok device=ac15000\.cci hold-ms=250"),
    "cci1": re.compile(r"^\[\s*([0-9]+(?:\.[0-9]+)?)\].*AON-F0-CCI-RATE-DIAG target-ok device=ac16000\.cci hold-ms=250"),
}
times = {}
with open(path, "r", encoding="utf-8", errors="replace") as fh:
    for line in fh:
        for key, pattern in patterns.items():
            match = pattern.search(line)
            if match and key not in times:
                times[key] = float(match.group(1))

missing = [key for key in patterns if key not in times]
if missing:
    print("overlap_status=missing-target-markers")
    print("overlap_missing=" + ",".join(missing))
    raise SystemExit(2)

span_ms = (max(times.values()) - min(times.values())) * 1000.0
overlap_ms = 250.0 - span_ms
for key in ("cci0", "cci1", "camss"):
    print(f"{key}_target_hold_start_monotonic={times[key]:.6f}")
print(f"target_hold_start_span_ms={span_ms:.3f}")
print(f"minimum_common_hold_overlap_ms={overlap_ms:.3f}")
if overlap_ms <= 0:
    print("overlap_status=none")
    raise SystemExit(3)
if overlap_ms < 100:
    print("overlap_status=too-short")
    raise SystemExit(4)
print("overlap_status=validated-at-least-100ms")
PY
overlap_rc=$?
set -e
[ "$overlap_rc" -eq 0 ] || fail "the three target holds did not overlap for at least 100 ms"

printf '\n%s\n' '===== VERIFY POST-PROBE IDLE / CAMERA RESTORE ====='
wait_all_idle post
validate_camss_status
validate_cci_status ac15000.cci "$cci0_status"
validate_cci_status ac16000.cci "$cci1_status"
camera_list post-probe
printf '%s\n' 'camera_restore_status=0'

cat > "$marker" <<EOF_MARKER
operation=platform-power-f0-combined-framework-only
boot_id=$boot_id
started=$started
completed=$completed
status=returned
cci0_write_status=$cci0_rc
cci1_write_status=$cci1_rc
camss_write_status=$camss_rc
direct_cpas_mmio=false
ssc_contacted=false
icp_clock_manipulation=false
raw_interconnect_manipulation=false
dtb_changes=false
overlap_validated=true
camera_restore_status=0
EOF_MARKER
sync "$marker"

printf '\nreport=%s\n' "$report"
printf 'kernel_log=%s\n' "$klog"
printf 'marker=%s\n' "$marker"
printf '%s\n' 'combined_f0_diagnostic_result=success'
printf '%s\n' 'authorization_for_cpas_mmio=false'
printf '%s\n' 'next_step=offline-resource-gap-analysis-before-any-ownership-mechanism'
