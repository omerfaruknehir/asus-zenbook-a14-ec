#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Recover/validate a Stage C attempt that returned from the hardware probe but
# whose userspace post-processing failed. This script never writes the probe.
set -Eeuo pipefail

marker=${A14_AOS_F0_ICP_OWNER_MARKER:-"$HOME/Downloads/a14-aos-f0-icp-owner-last-run.txt"}
report=${A14_AOS_F0_ICP_OWNER_REPORT:-"$HOME/Downloads/a14-aos-f0-icp-owner-report.txt"}
klog=${A14_AOS_F0_ICP_OWNER_KLOG:-"$HOME/Downloads/a14-aos-f0-icp-owner-kernel.log"}
camss_status=
camss_dev=
cci0_dev=/sys/bus/platform/devices/ac15000.cci
cci1_dev=/sys/bus/platform/devices/ac16000.cci
media_stopped=false
cam_tmp=
journal_json=
journal_meta=

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
cleanup() {
    set +e
    [ -z "$cam_tmp" ] || rm -f "$cam_tmp"
    [ -z "$journal_json" ] || rm -f "$journal_json"
    [ -z "$journal_meta" ] || rm -f "$journal_meta"
    if [ "$media_stopped" = true ]; then
        systemctl --user start pipewire.socket pipewire-pulse.socket 2>/dev/null
        systemctl --user start pipewire.service pipewire-pulse.service wireplumber.service 2>/dev/null
    fi
}
trap cleanup EXIT INT TERM

for tool in cam cat date fuser grep journalctl mktemp python3 readlink rm sleep sudo sync \
            systemctl tee timeout; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this recovery as your normal user, not with sudo"
case " $(cat /proc/cmdline) " in
    *' a14_aos_f0_icp_owner_test=1 '*) ;;
    *) fail "this is not the isolated A14 F0 ICP owner diagnostic boot" ;;
esac

grep -Eq '^qcom_camss[[:space:]]' /proc/modules || fail "qcom_camss is not loaded"
grep -Eq '^i2c_qcom_cci[[:space:]]' /proc/modules || fail "i2c_qcom_cci is not loaded"
if grep -Eq '^qcom_ssc_hpd[[:space:]]' /proc/modules; then
    fail "qcom_ssc_hpd is loaded; refusing Stage C recovery"
fi
[ -s "$marker" ] || fail "persistent Stage C marker is missing: $marker"
grep -Fqx 'operation=platform-power-f0-icp-real-owners-no-mmio-v1' "$marker" || \
    fail "persistent marker is not a Stage C owner attempt"
grep -Fqx 'status=started' "$marker" || \
    fail "marker is not an interrupted post-processing attempt (expected status=started)"

boot_id=$(cat /proc/sys/kernel/random/boot_id)
marker_boot_id=$(sed -n 's/^boot_id=//p' "$marker" | head -n 1)
[ "$marker_boot_id" = "$boot_id" ] || \
    fail "marker belongs to boot $marker_boot_id, current boot is $boot_id"
started=$(sed -n 's/^started=//p' "$marker" | head -n 1)
[ -n "$started" ] || fail "marker lacks the original start timestamp"

[ -d "$cci0_dev" ] || fail "CCI0 platform device is missing"
[ -d "$cci1_dev" ] || fail "CCI1 platform device is missing"
for link in /sys/bus/platform/drivers/qcom-camss/*; do
    [ -L "$link" ] || continue
    dev=$(readlink -f "$link")
    s="$dev/a14_f0_icp_owner_diag/a14_f0_icp_owner_status"
    if [ -r "$s" ]; then
        camss_dev=$dev
        camss_status=$s
        break
    fi
done
[ -n "$camss_status" ] || fail "isolated boot lacks the Stage C CAMSS diagnostic status"

validate_status() {
    s=$(cat "$camss_status")
    case " $s " in *' ready=1 '*) ;; *) fail "diagnostic is not ready: $s" ;; esac
    case " $s " in *' clock_get_status=0 '*) ;; *) fail "clock lookup failed: $s" ;; esac
    case " $s " in *' round_status=0 '*) ;; *) fail "an exact F0 target is unsupported: $s" ;; esac
    case " $s " in *' failed_clock=none '*) ;; *) fail "a prerequisite clock failed: $s" ;; esac
    case " $s " in *' icp_ahb_handle=1 '*) ;; *) fail "ICP AHB owner handle is missing: $s" ;; esac
    case " $s " in *' icp_handle=1 '*) ;; *) fail "ICP owner handle is missing: $s" ;; esac
    case " $s " in *' direct_mmio=0 '*) ;; *) fail "diagnostic does not declare direct-MMIO prohibition: $s" ;; esac
    case " $s " in *' ssc=0 '*) ;; *) fail "diagnostic does not declare SSC prohibition: $s" ;; esac
    printf 'camss_status=%s\n' "$s"
}

wait_all_idle() {
    label=$1
    attempt=0
    while [ "$attempt" -lt 20 ]; do
        cs=$(cat "$camss_dev/power/runtime_status" 2>/dev/null || true)
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
    fail "CAMSS and both CCI controllers did not all become runtime-suspended"
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
    grep -Eq '^[[:space:]]*[0-9]+:' "$cam_tmp" || \
        fail "$label camera enumeration returned no accessible cameras"
    rm -f "$cam_tmp"
    cam_tmp=
}

printf '%s\n' 'A14 Stage C post-processing recovery'
printf '%s\n' '===================================='
printf 'boot_id=%s\n' "$boot_id"
printf 'original_started=%s\n' "$started"
printf '%s\n' 'hardware_probe_write=false'
printf '%s\n' 'direct_cpas_mmio=false'
printf '%s\n' 'ssc_contacted=false'

printf '\n%s\n' '===== RECOVER MARKER-CORRELATED KERNEL ATTEMPT ====='
journal_json=$(mktemp)
journal_meta=$(mktemp)
sudo journalctl -k -b --no-pager -o json > "$journal_json"
python3 - "$journal_json" "$started" "$klog" "$journal_meta" <<'PY'
import datetime as dt
import json
import sys

journal_path, started_text, out_path, meta_path = sys.argv[1:]
begin_marker = 'AON-F0-ICP-OWNER-DIAG begin direct-mmio=false ssc=false'
complete_marker = 'AON-F0-ICP-OWNER-DIAG complete '

try:
    marker_dt = dt.datetime.fromisoformat(started_text.replace(',', '.'))
except ValueError as exc:
    raise SystemExit(f'ERROR: could not parse persistent marker timestamp: {started_text}: {exc}')
if marker_dt.tzinfo is None:
    raise SystemExit('ERROR: persistent marker timestamp lacks timezone')
marker_us = int(marker_dt.timestamp() * 1_000_000)

entries = []
with open(journal_path, encoding='utf-8') as fh:
    for lineno, line in enumerate(fh, 1):
        try:
            obj = json.loads(line)
        except json.JSONDecodeError as exc:
            raise SystemExit(f'ERROR: invalid journal JSON at line {lineno}: {exc}')
        msg = obj.get('MESSAGE', '')
        ts = obj.get('__REALTIME_TIMESTAMP')
        if isinstance(msg, list):
            msg = ''.join(chr(x) for x in msg)
        if not isinstance(msg, str) or ts is None:
            continue
        try:
            ts_us = int(ts)
        except (TypeError, ValueError):
            continue
        entries.append((ts_us, msg))

begin_indices = [i for i, (_, msg) in enumerate(entries) if begin_marker in msg]
candidate_indices = [i for i in begin_indices if entries[i][0] >= marker_us]

with open(meta_path, 'w', encoding='utf-8') as meta:
    meta.write(f'marker_realtime_us={marker_us}\n')
    meta.write(f'boot_begin_count={len(begin_indices)}\n')
    for n, i in enumerate(begin_indices, 1):
        meta.write(f'begin_{n}_realtime_us={entries[i][0]}\n')
        meta.write(f'begin_{n}_delta_us={entries[i][0] - marker_us}\n')
    meta.write(f'begin_at_or_after_marker_count={len(candidate_indices)}\n')

if len(candidate_indices) != 1:
    raise SystemExit(
        'ERROR: expected exactly one Stage C begin at/after the persistent marker; '
        f'found {len(candidate_indices)} (boot total {len(begin_indices)})'
    )

begin_i = candidate_indices[0]
next_begin_i = next((i for i in begin_indices if i > begin_i), None)
limit = next_begin_i if next_begin_i is not None else len(entries)
complete_i = next(
    (i for i in range(begin_i, limit) if complete_marker in entries[i][1]),
    None,
)
if complete_i is None:
    raise SystemExit('ERROR: marker-correlated Stage C attempt has no complete marker before the next attempt/end of journal')

with open(out_path, 'w', encoding='utf-8') as out:
    for ts_us, msg in entries[begin_i:complete_i + 1]:
        out.write(f'{ts_us} {msg}\n')

with open(meta_path, 'a', encoding='utf-8') as meta:
    meta.write(f'selected_begin_realtime_us={entries[begin_i][0]}\n')
    meta.write(f'selected_begin_delta_us={entries[begin_i][0] - marker_us}\n')
    meta.write(f'selected_complete_realtime_us={entries[complete_i][0]}\n')
    meta.write(f'selected_duration_us={entries[complete_i][0] - entries[begin_i][0]}\n')
PY
cat "$journal_meta"
[ -s "$klog" ] || fail "could not isolate the marker-correlated Stage C kernel log"

grep -Fq 'AON-F0-ICP-OWNER-DIAG targets-ok hold-ms=250' "$klog" || \
    fail "full F0 target hold was not reached"
grep -Fq 'AON-F0-ICP-OWNER-DIAG icp-restore-ok' "$klog" || \
    fail "ICP clocks did not restore exactly"
grep -Fq 'AON-F0-ICP-OWNER-DIAG cci-put device=ac15000.cci ret=0' "$klog" || \
    fail "CCI0 owner did not restore/release exactly"
grep -Fq 'AON-F0-ICP-OWNER-DIAG cci-put device=ac16000.cci ret=0' "$klog" || \
    fail "CCI1 owner did not restore/release exactly"
grep -Eq 'AON-F0-ICP-OWNER-DIAG complete ret=0 camnoc-limited=[01]' "$klog" || \
    fail "Stage C cleanup did not complete successfully"
if grep -Eq 'watchdog|panic|SError|Call trace|Internal error|Oops' "$klog"; then
    fail "kernel fault marker detected inside the marker-correlated Stage C attempt"
fi
printf '%s\n' 'kernel_result=validated-full-f0-hold-and-cleanup'
printf '\n%s\n' '===== RELEVANT KERNEL LOG ====='
grep -E 'AON-F0-ICP-OWNER-DIAG|watchdog|panic|SError|Call trace|Internal error|Oops' "$klog" || true

printf '\n%s\n' '===== VERIFY POST-ATTEMPT OWNERS / CAMERA ====='
sudo -v
systemctl --user stop pipewire-pulse.socket pipewire.socket 2>/dev/null || true
systemctl --user stop wireplumber.service pipewire-pulse.service pipewire.service 2>/dev/null || true
media_stopped=true
sleep 2
users=$(sudo fuser /dev/video* /dev/media* /dev/v4l-subdev* 2>/dev/null || true)
if [ -n "$users" ]; then
    sudo fuser -v /dev/video* /dev/media* /dev/v4l-subdev* 2>&1 || true
    fail "camera/media nodes remain busy during recovery verification"
fi
wait_all_idle post-recovery
validate_status
camera_list post-recovery
printf '%s\n' 'camera_restore_status=0'

completed=$(date --iso-8601=ns)
cat > "$marker" <<EOF_MARKER
operation=platform-power-f0-icp-real-owners-no-mmio-v1
boot_id=$boot_id
started=$started
completed=$completed
status=returned
result=success
result_recovered_from_kernel_log=true
attempt_selection=marker-realtime-correlated
shell_probe_write_status=not-persisted
kernel_complete_ret=0
cci_restore_exact=true
icp_restore_exact=true
direct_cpas_mmio=false
ssc_contacted=false
EOF_MARKER
sync "$marker"; sync

cat > "$report" <<EOF_REPORT
A14 Stage C recovery result
===========================
boot_id=$boot_id
started=$started
completed=$completed
hardware_probe_write_during_recovery=false
attempt_selection=marker-realtime-correlated
kernel_result=validated-full-f0-hold-and-cleanup
camera_restore_status=0
cci_restore_exact=true
icp_restore_exact=true
direct_cpas_mmio=false
ssc_contacted=false
result=success-full-f0-icp-owner-hold-recovered
kernel_log=$klog
marker=$marker
EOF_REPORT

printf '\n%s\n' '===== RESULT ====='
printf '%s\n' 'result=success-full-f0-icp-owner-hold-recovered'
printf '%s\n' 'hardware_probe_write_during_recovery=false'
printf '%s\n' 'attempt_selection=marker-realtime-correlated'
printf 'marker=%s\n' "$marker"
printf 'report=%s\n' "$report"
printf 'kernel_log=%s\n' "$klog"
printf '%s\n' 'This validates only the F0 resource prerequisite. It does not authorize CPAS mux access.'
