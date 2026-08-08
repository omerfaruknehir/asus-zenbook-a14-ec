#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Execute the isolated full-F0 ICP owner prerequisite hold. No CPAS MMIO/SSC.
set -Eeuo pipefail

release=${A14_KERNEL_RELEASE:-$(uname -r)}
report=${A14_AOS_F0_ICP_OWNER_REPORT:-"$HOME/Downloads/a14-aos-f0-icp-owner-report.txt"}
marker=${A14_AOS_F0_ICP_OWNER_MARKER:-"$HOME/Downloads/a14-aos-f0-icp-owner-last-run.txt"}
klog=${A14_AOS_F0_ICP_OWNER_KLOG:-"$HOME/Downloads/a14-aos-f0-icp-owner-kernel.log"}
camss_probe=
camss_status=
camss_dev=
cci0_dev=/sys/bus/platform/devices/ac15000.cci
cci1_dev=/sys/bus/platform/devices/ac16000.cci
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

for tool in cam cat date fuser grep journalctl mktemp readlink rm sleep sudo sync \
            systemctl tee timeout uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this script as your normal user, not with sudo"
case " $(cat /proc/cmdline) " in
    *' a14_aos_f0_icp_owner_test=1 '*) ;;
    *) fail "this is not the isolated A14 F0 ICP owner diagnostic boot" ;;
esac

grep -Eq '^qcom_camss[[:space:]]' /proc/modules || fail "qcom_camss is not loaded"
grep -Eq '^i2c_qcom_cci[[:space:]]' /proc/modules || fail "i2c_qcom_cci is not loaded"
if grep -Eq '^qcom_ssc_hpd[[:space:]]' /proc/modules; then
    fail "qcom_ssc_hpd is loaded; the ICP owner diagnostic was not attempted"
fi
[ -d "$cci0_dev" ] || fail "CCI0 platform device is missing"
[ -d "$cci1_dev" ] || fail "CCI1 platform device is missing"

for link in /sys/bus/platform/drivers/qcom-camss/*; do
    [ -L "$link" ] || continue
    dev=$(readlink -f "$link")
    p="$dev/a14_f0_icp_owner_diag/a14_f0_icp_owner_probe"
    s="$dev/a14_f0_icp_owner_diag/a14_f0_icp_owner_status"
    if [ -e "$p" ] && [ -r "$s" ]; then
        camss_dev=$dev
        camss_probe=$p
        camss_status=$s
        break
    fi
done
[ -n "$camss_probe" ] || fail "isolated boot lacks the Stage C CAMSS diagnostic"

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
    grep -Eq '^[[:space:]]*[0-9]+:' "$cam_tmp" || fail "$label camera enumeration returned no accessible cameras"
    rm -f "$cam_tmp"
    cam_tmp=
}

printf '%s\n' 'A14 full Windows-F0 ICP owner diagnostic'
printf '%s\n' '========================================'
printf 'kernel_release=%s\n' "$release"
printf '%s\n' 'cci0_target=37500000'
printf '%s\n' 'cci1_target=37500000'
printf '%s\n' 'camnoc_targets=300000000,300000000'
printf '%s\n' 'ahb_targets=80000000,80000000,100000000'
printf '%s\n' 'icp_targets=80000000,400000000'
printf '%s\n' 'hold_ms=250'
printf '%s\n' 'uses_production_icp_handles=true'
printf '%s\n' 'uses_production_cci_hold_api=true'
printf '%s\n' 'direct_cpas_mmio=false'
printf '%s\n' 'ssc_contacted=false'
validate_status

sudo -v
systemctl --user stop pipewire-pulse.socket pipewire.socket 2>/dev/null || true
systemctl --user stop wireplumber.service pipewire-pulse.service pipewire.service 2>/dev/null || true
media_stopped=true
sleep 2
users=$(sudo fuser /dev/video* /dev/media* /dev/v4l-subdev* 2>/dev/null || true)
if [ -n "$users" ]; then
    sudo fuser -v /dev/video* /dev/media* /dev/v4l-subdev* 2>&1 || true
    fail "camera/media nodes remain busy; ICP owner diagnostic was not attempted"
fi

printf '\n%s\n' '===== PRE-PROBE CAMERA BASELINE ====='
camera_list pre-probe
printf '%s\n' 'camera_baseline=validated-accessible-camera'
users=$(sudo fuser /dev/video* /dev/media* /dev/v4l-subdev* 2>/dev/null || true)
[ -z "$users" ] || fail "camera/media nodes reopened after baseline"

printf '\n%s\n' '===== WAIT FOR OWNERS TO IDLE ====='
wait_all_idle pre
validate_status

boot_id=$(cat /proc/sys/kernel/random/boot_id)
started=$(date --iso-8601=ns)
cat > "$marker" <<EOF_MARKER
operation=platform-power-f0-icp-real-owners-no-mmio-v1
boot_id=$boot_id
started=$started
status=started
cci0_target=37500000
cci1_target=37500000
icp_ahb_target=80000000
icp_target=400000000
hold_ms=250
direct_cpas_mmio=false
ssc_contacted=false
uses_production_icp_handles=true
uses_production_cci_hold_api=true
EOF_MARKER
sync "$marker"; sync

exec > >(tee "$report") 2>&1
printf '\n%s\n' '===== EXECUTE FIRST REAL-OWNER ICP F0 HOLD ====='
printf 'boot_id=%s\n' "$boot_id"
printf 'probe_started_at=%s\n' "$started"
printf '%s\n' 'direct_cpas_mmio=false'
printf '%s\n' 'ssc_contacted=false'

set +e
sudo sh -c 'printf "1\n" > "$1"' sh "$camss_probe"
probe_rc=$?
set -e
completed=$(date --iso-8601=ns)
printf 'probe_write_status=%s\n' "$probe_rc"

sudo journalctl -k -b --since "$started" --no-pager -o short-monotonic > "$klog"
printf '\n%s\n' '===== RELEVANT KERNEL LOG ====='
grep -E 'AON-F0-ICP-OWNER-DIAG|A14 isolated F0 ICP owner diagnostic|qcom-camss|i2c-qcom-cci|watchdog|panic|SError|Call trace|Internal error|Oops' "$klog" || true

# A target-hold marker proves both CCI holds, all five known CAMSS F0 rates and
# both ICP rates were established before the 250 ms sleep.
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
[ "$probe_rc" -eq 0 ] || fail "Stage C sysfs write returned $probe_rc despite reaching the target hold"

if grep -Eq 'watchdog|panic|SError|Call trace|Internal error|Oops' "$klog"; then
    fail "kernel fault marker detected during Stage C hold"
fi

printf '\n%s\n' '===== VERIFY POST-PROBE IDLE / CAMERA RESTORE ====='
wait_all_idle post
validate_status
camera_list post-probe
printf '%s\n' 'camera_restore_status=0'

cat > "$marker" <<EOF_MARKER
operation=platform-power-f0-icp-real-owners-no-mmio-v1
boot_id=$boot_id
started=$started
completed=$completed
status=returned
result=success
probe_write_status=$probe_rc
cci_restore_exact=true
icp_restore_exact=true
direct_cpas_mmio=false
ssc_contacted=false
EOF_MARKER
sync "$marker"; sync

printf '\n%s\n' '===== RESULT ====='
printf '%s\n' 'result=success-full-f0-icp-owner-hold-returned'
printf 'marker=%s\n' "$marker"
printf 'report=%s\n' "$report"
printf 'kernel_log=%s\n' "$klog"
printf '%s\n' 'direct_cpas_mmio=false'
printf '%s\n' 'ssc_contacted=false'
printf '%s\n' 'This validates only the F0 resource prerequisite. It does not authorize CPAS mux access.'
