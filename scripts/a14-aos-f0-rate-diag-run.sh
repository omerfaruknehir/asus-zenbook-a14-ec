#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Run exactly one staged F0-rate subset phase from the isolated diagnostic boot.
# Phase 1 must be validated before phase 2; phase 2 before phase 3.
set -Eeuo pipefail

phase=${1:-}
case "$phase" in
    1|2|3) ;;
    *) printf 'usage: %s PHASE\n  PHASE=1  CAMNOC RT/NRT -> 300 MHz\n  PHASE=2  CPAS/core/fast AHB -> 80/80/100 MHz\n  PHASE=3  combined five targets\n' "$0" >&2; exit 2 ;;
esac

release=${A14_KERNEL_RELEASE:-$(uname -r)}
report=${A14_AOS_F0_RATE_REPORT:-"$HOME/Downloads/a14-aos-f0-rate-phase${phase}-report.txt"}
marker=${A14_AOS_F0_RATE_MARKER:-"$HOME/Downloads/a14-aos-f0-rate-phase${phase}-last-run.txt"}
probe_attr=
status_attr=
diag_status=
media_stopped=false
cam_tmp=

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    set +e
    [ -z "$cam_tmp" ] || rm -f "$cam_tmp"
    if [ "$media_stopped" = true ]; then
        systemctl --user start pipewire.socket pipewire-pulse.socket 2>/dev/null
        systemctl --user start pipewire.service pipewire-pulse.service wireplumber.service 2>/dev/null
    fi
}
trap cleanup EXIT INT TERM

for tool in cam cat date fuser grep journalctl mktemp readlink rm sleep sudo \
            sync systemctl tee timeout uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done

[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this script as your normal user, not with sudo"
case " $(cat /proc/cmdline) " in
    *' a14_aos_f0_rate_test=1 '*) ;;
    *) fail "this is not the isolated A14 F0-rate diagnostic boot" ;;
esac

grep -Eq '^qcom_camss[[:space:]]' /proc/modules || fail "qcom_camss is not loaded"
if grep -Eq '^qcom_ssc_hpd[[:space:]]' /proc/modules; then
    fail "qcom_ssc_hpd is loaded; the diagnostic was not attempted"
fi

for link in /sys/bus/platform/drivers/qcom-camss/*; do
    [ -L "$link" ] || continue
    dev=$(readlink -f "$link")
    candidate="$dev/a14_f0_rate_diag/a14_f0_rate_probe"
    candidate_status="$dev/a14_f0_rate_diag/a14_f0_rate_status"
    if [ -e "$candidate" ] && [ -r "$candidate_status" ]; then
        probe_attr=$candidate
        status_attr=$candidate_status
        break
    fi
done
[ -n "$probe_attr" ] || fail "rebuilt staged F0-rate CAMSS diagnostic was not found"

validate_static_status() {
    status=$1
    case " $status " in *' ready=1 '*) ;; *) fail "diagnostic module is not ready" ;; esac
    case " $status " in *' clock_get_status=0 '*) ;; *) fail "diagnostic clock lookup is not valid" ;; esac
    case " $status " in *' round_status=0 '*) ;; *) fail "one or more exact target rates are unsupported" ;; esac
    case " $status " in *' failed_clock=none '*) ;; *) fail "diagnostic has a failed clock" ;; esac
    case " $status " in *' initialization=post-probe-success '*) ;; *) fail "diagnostic initialization is invalid" ;; esac
    case " $status " in *' phases=1,2,3 '*) ;; *) fail "diagnostic phase contract is invalid" ;; esac
}

read_diag_status() {
    diag_status=$(cat "$status_attr")
    validate_static_status "$diag_status"
}

wait_camss_runtime_idle() {
    label=$1
    attempt=0
    while [ "$attempt" -lt 15 ]; do
        read_diag_status
        case " $diag_status " in
            *' runtime_suspended=1 '*)
                printf '%s_runtime_idle_status=%s\n' "$label" "$diag_status"
                return 0
                ;;
        esac
        attempt=$((attempt + 1))
        sleep 1
    done
    printf '%s_runtime_idle_status=%s\n' "$label" "$diag_status"
    fail "CAMSS did not reach runtime-suspended state ($label)"
}

camera_list() {
    label=$1
    cam_tmp=$(mktemp)
    set +e
    sudo timeout 25 cam -l >"$cam_tmp" 2>&1
    status=$?
    set -e
    cat "$cam_tmp"
    if [ "$status" -ne 0 ]; then
        fail "$label camera enumeration failed with status $status"
    fi
    if ! grep -Eq '^[[:space:]]*[0-9]+:' "$cam_tmp"; then
        fail "$label camera enumeration returned no accessible cameras"
    fi
    rm -f "$cam_tmp"
    cam_tmp=
}

read_diag_status
printf 'diagnostic_status=%s\n' "$diag_status"

sudo -v
systemctl --user stop pipewire-pulse.socket pipewire.socket 2>/dev/null || true
systemctl --user stop wireplumber.service pipewire-pulse.service pipewire.service 2>/dev/null || true
media_stopped=true
sleep 2

users=$(sudo fuser /dev/video* /dev/media* /dev/v4l-subdev* 2>/dev/null || true)
if [ -n "$users" ]; then
    sudo fuser -v /dev/video* /dev/media* /dev/v4l-subdev* 2>&1 || true
    fail "camera/media nodes remain busy; phase $phase was not attempted"
fi

printf '%s\n' 'A14 staged Windows-F0 clock-rate subset diagnostic'
printf '%s\n' '================================================='
printf 'kernel_release=%s\n' "$release"
printf 'phase=%s\n' "$phase"
printf 'sysfs_probe=%s\n' "$probe_attr"
printf 'sysfs_status=%s\n' "$status_attr"
printf '%s\n' 'ssc_loaded=false'
printf '%s\n' 'direct_cpas_mmio=false'
printf '%s\n' 'dtb_changes=false'
printf '%s\n' 'platform_clock_count=7'
printf '%s\n' 'exact_round_rate_required=true'
printf '%s\n' 'restore_original_rates=true'
printf '%s\n' 'idle_guard=runtime-suspended'
case "$phase" in
    1) printf '%s\n' 'phase_targets=camnoc_rt_axi:300000000,camnoc_nrt_axi:300000000' ;;
    2) printf '%s\n' 'phase_targets=cpas_ahb:80000000,core_ahb:80000000,cpas_fast_ahb:100000000' ;;
    3) printf '%s\n' 'phase_targets=combined-phase-1-and-phase-2' ;;
esac

printf '\n%s\n' '===== PRE-PROBE CAMERA BASELINE ====='
camera_list pre-probe
printf '%s\n' 'camera_baseline=validated-accessible-camera'

users=$(sudo fuser /dev/video* /dev/media* /dev/v4l-subdev* 2>/dev/null || true)
if [ -n "$users" ]; then
    sudo fuser -v /dev/video* /dev/media* /dev/v4l-subdev* 2>&1 || true
    fail "camera/media nodes reopened after baseline; phase $phase was not attempted"
fi

printf '\n%s\n' '===== WAIT FOR CAMSS RUNTIME IDLE ====='
wait_camss_runtime_idle pre

boot_id=$(cat /proc/sys/kernel/random/boot_id)
started=$(date --iso-8601=seconds)
cat > "$marker" <<EOF_MARKER
operation=platform-power-f0-rate-subset-no-mmio
phase=$phase
boot_id=$boot_id
started=$started
status=started
module_load_mode=isolated-initramfs-post-probe-init
ssc_contacted=false
direct_cpas_mmio=false
dtb_changes=false
platform_clock_count=7
exact_round_rate_required=true
restore_original_rates=true
idle_guard=runtime-suspended
EOF_MARKER
sync "$marker"
sync

exec > >(tee "$report") 2>&1

printf '\n%s\n' '===== EXECUTE STAGED F0-RATE PHASE ====='
printf 'boot_id=%s\n' "$boot_id"
printf 'probe_started_at=%s\n' "$started"
printf 'phase=%s\n' "$phase"
printf 'diagnostic_status=%s\n' "$diag_status"
printf 'sysfs_write=%s\n' "$phase"
printf '%s\n' 'direct_cpas_mmio=false'
printf '%s\n' 'ssc_contacted=false'

set +e
sudo sh -c 'printf "%s\n" "$1" > "$2"' sh "$phase" "$probe_attr"
probe_status=$?
set -e

completed=$(date --iso-8601=seconds)
cat > "$marker" <<EOF_MARKER
operation=platform-power-f0-rate-subset-no-mmio
phase=$phase
boot_id=$boot_id
started=$started
completed=$completed
status=returned
return_status=$probe_status
module_load_mode=isolated-initramfs-post-probe-init
ssc_contacted=false
direct_cpas_mmio=false
dtb_changes=false
platform_clock_count=7
exact_round_rate_required=true
restore_original_rates=true
idle_guard=runtime-suspended
EOF_MARKER
sync "$marker"

printf 'probe_return_status=%s\n' "$probe_status"
printf '\n%s\n' '===== KERNEL F0-RATE DIAGNOSTIC LOG ====='
sudo journalctl -k -b --since "$started" --no-pager -o short-monotonic |
    grep -E 'AON-F0-RATE-DIAG|A14 F0 rate diagnostic|qcom-camss|qcom_camss|watchdog|panic|SError|abort|Call trace' || true

if [ "$probe_status" -eq 0 ]; then
    printf '\n%s\n' '===== VERIFY POST-PROBE RUNTIME IDLE ====='
    wait_camss_runtime_idle post

    printf '\n%s\n' '===== POST-PROBE CAMERA RESTORE ====='
    camera_list post-probe
    printf '%s\n' 'camera_restore_status=0'
else
    printf '%s\n' 'camera_restore_status=not-attempted-after-probe-error'
fi

printf '\nreport=%s\n' "$report"
printf 'marker=%s\n' "$marker"

if [ "$probe_status" -ne 0 ]; then
    exit "$probe_status"
fi
printf '%s\n' 'f0_rate_diagnostic_result=success'
