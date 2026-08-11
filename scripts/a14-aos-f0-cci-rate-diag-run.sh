#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Exercise one CCI controller at the Windows F0 37.5 MHz clock rate.
set -Eeuo pipefail

index=${1:-}
case "$index" in
    0) device=ac15000.cci ;;
    1) device=ac16000.cci ;;
    *) printf 'usage: %s CCI_INDEX\n  CCI_INDEX=0  ac15000.cci\n  CCI_INDEX=1  ac16000.cci\n' "$0" >&2; exit 2 ;;
esac

release=${A14_KERNEL_RELEASE:-$(uname -r)}
report=${A14_AOS_F0_CCI_RATE_REPORT:-"$HOME/Downloads/a14-aos-f0-cci${index}-rate-report.txt"}
marker=${A14_AOS_F0_CCI_RATE_MARKER:-"$HOME/Downloads/a14-aos-f0-cci${index}-rate-last-run.txt"}
dev="/sys/bus/platform/devices/$device"
status_attr="$dev/a14_f0_cci_rate_diag/a14_f0_cci_rate_status"
probe_attr="$dev/a14_f0_cci_rate_diag/a14_f0_cci_rate_probe"
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

for tool in cam cat date fuser grep journalctl mktemp rm sleep sudo sync systemctl tee timeout uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this script as your normal user, not with sudo"
case " $(cat /proc/cmdline) " in *' a14_aos_f0_cci_rate_test=1 '*) ;; *) fail "this is not the isolated A14 F0 CCI-rate diagnostic boot" ;; esac
grep -Eq '^i2c_qcom_cci[[:space:]]' /proc/modules || fail "i2c_qcom_cci is not loaded"
if grep -Eq '^qcom_ssc_hpd[[:space:]]' /proc/modules; then fail "qcom_ssc_hpd is loaded; the diagnostic was not attempted"; fi

for d in ac15000.cci ac16000.cci; do
    [ -r "/sys/bus/platform/devices/$d/a14_f0_cci_rate_diag/a14_f0_cci_rate_status" ] || fail "rebuilt CCI diagnostic attribute is missing on $d"
done

validate_status() {
    d=$1
    s=$(cat "/sys/bus/platform/devices/$d/a14_f0_cci_rate_diag/a14_f0_cci_rate_status")
    case " $s " in *' ready=1 '*) ;; *) fail "$d diagnostic is not ready: $s" ;; esac
    case " $s " in *' clock_status=0 '*) ;; *) fail "$d CCI clock lookup failed: $s" ;; esac
    case " $s " in *' round_status=0 '*) ;; *) fail "$d does not support exact 37.5 MHz: $s" ;; esac
    printf '%s_status=%s\n' "$d" "$s"
}

wait_all_idle() {
    label=$1
    attempt=0
    s0=unknown; s1=unknown
    while [ "$attempt" -lt 15 ]; do
        s0=$(cat /sys/bus/platform/devices/ac15000.cci/power/runtime_status)
        s1=$(cat /sys/bus/platform/devices/ac16000.cci/power/runtime_status)
        if [ "$s0" = suspended ] && [ "$s1" = suspended ]; then
            printf '%s_cci0_runtime_status=%s\n' "$label" "$s0"
            printf '%s_cci1_runtime_status=%s\n' "$label" "$s1"
            return 0
        fi
        attempt=$((attempt + 1)); sleep 1
    done
    printf '%s_cci0_runtime_status=%s\n' "$label" "$s0"
    printf '%s_cci1_runtime_status=%s\n' "$label" "$s1"
    fail "both CCI controllers did not reach runtime-suspended state"
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
    rm -f "$cam_tmp"; cam_tmp=
}

validate_status ac15000.cci
validate_status ac16000.cci
sudo -v
systemctl --user stop pipewire-pulse.socket pipewire.socket 2>/dev/null || true
systemctl --user stop wireplumber.service pipewire-pulse.service pipewire.service 2>/dev/null || true
media_stopped=true
sleep 2
users=$(sudo fuser /dev/video* /dev/media* /dev/v4l-subdev* 2>/dev/null || true)
if [ -n "$users" ]; then
    sudo fuser -v /dev/video* /dev/media* /dev/v4l-subdev* 2>&1 || true
    fail "camera/media nodes remain busy; CCI$index test was not attempted"
fi

printf '%s\n' 'A14 Windows-F0 CCI clock-rate diagnostic'
printf '%s\n' '========================================'
printf 'kernel_release=%s\n' "$release"
printf 'cci_index=%s\n' "$index"
printf 'device=%s\n' "$device"
printf '%s\n' 'target_rate=37500000'
printf '%s\n' 'hold_ms=250'
printf '%s\n' 'runtime_pm=existing-i2c-qcom-cci'
printf '%s\n' 'direct_cpas_mmio=false'
printf '%s\n' 'ssc_contacted=false'
printf '%s\n' 'dtb_changes=false'

printf '\n%s\n' '===== PRE-PROBE CAMERA BASELINE ====='
camera_list pre-probe
printf '%s\n' 'camera_baseline=validated-accessible-camera'
printf '\n%s\n' '===== WAIT FOR BOTH CCI CONTROLLERS TO IDLE ====='
wait_all_idle pre
validate_status "$device"

boot_id=$(cat /proc/sys/kernel/random/boot_id)
started=$(date --iso-8601=seconds)
cat > "$marker" <<EOF_MARKER
operation=platform-power-f0-cci-rate-no-cpas-mmio
cci_index=$index
device=$device
boot_id=$boot_id
started=$started
status=started
target_rate=37500000
hold_ms=250
ssc_contacted=false
direct_cpas_mmio=false
dtb_changes=false
restore_original_rate=true
idle_guard=both-cci-runtime-suspended
EOF_MARKER
sync "$marker"; sync

exec > >(tee "$report") 2>&1
printf '\n%s\n' '===== EXECUTE CCI RATE PROBE ====='
printf 'boot_id=%s\n' "$boot_id"
printf 'probe_started_at=%s\n' "$started"
printf 'cci_index=%s\n' "$index"
printf 'device=%s\n' "$device"
printf '%s\n' 'sysfs_write=1'
printf '%s\n' 'direct_cpas_mmio=false'
printf '%s\n' 'ssc_contacted=false'

set +e
sudo sh -c 'printf "1\n" > "$1"' sh "$probe_attr"
probe_status=$?
set -e
completed=$(date --iso-8601=seconds)
cat > "$marker" <<EOF_MARKER
operation=platform-power-f0-cci-rate-no-cpas-mmio
cci_index=$index
device=$device
boot_id=$boot_id
started=$started
completed=$completed
status=returned
return_status=$probe_status
target_rate=37500000
hold_ms=250
ssc_contacted=false
direct_cpas_mmio=false
dtb_changes=false
restore_original_rate=true
idle_guard=both-cci-runtime-suspended
EOF_MARKER
sync "$marker"

printf 'probe_return_status=%s\n' "$probe_status"
printf '\n%s\n' '===== KERNEL CCI-RATE DIAGNOSTIC LOG ====='
sudo journalctl -k -b --since "$started" --no-pager -o short-monotonic | grep -E 'AON-F0-CCI-RATE-DIAG|A14 F0 CCI rate diagnostic|i2c-qcom-cci|watchdog|panic|SError|abort|Call trace' || true

if [ "$probe_status" -eq 0 ]; then
    printf '\n%s\n' '===== VERIFY CCI IDLE / CAMERA RESTORE ====='
    wait_all_idle post
    validate_status "$device"
    camera_list post-probe
    printf '%s\n' 'camera_restore_status=0'
else
    printf '%s\n' 'camera_restore_status=not-attempted-after-probe-error'
fi
printf '\nreport=%s\n' "$report"
printf 'marker=%s\n' "$marker"
[ "$probe_status" -eq 0 ] || exit "$probe_status"
printf '%s\n' 'f0_cci_rate_diagnostic_result=success'
