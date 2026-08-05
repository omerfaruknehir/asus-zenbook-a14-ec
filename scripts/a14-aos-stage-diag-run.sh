#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Run exactly one isolated CAMSS AON diagnostic stage. Never contacts SSC.
set -Eeuo pipefail

stage=${1:-}
confirm=${2:-}
release=${A14_KERNEL_RELEASE:-$(uname -r)}
report=${A14_AOS_DIAG_REPORT:-"$HOME/Downloads/a14-aos-diag-stage-${stage:-unknown}.txt"}
marker=${A14_AOS_DIAG_MARKER:-"$HOME/Downloads/a14-aos-diag-last-stage.txt"}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

case "$stage" in
    1) stage_name=runtime-pm ;;
    2) stage_name=cpas-clocks ;;
    3) stage_name=cpas-read ;;
    4) stage_name=write-current ;;
    5)
        stage_name=aon-switch-restore
        [ "$confirm" = --confirm-aon-switch ] || \
            fail "stage 5 requires the explicit second argument --confirm-aon-switch"
        ;;
    *)
        echo "Usage: $0 {1|2|3|4|5} [--confirm-aon-switch]" >&2
        exit 2
        ;;
esac

for tool in cam cat date find fuser journalctl lsmod readlink sleep sudo sync systemctl timeout; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done

[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this script as your normal user, not with sudo"
case " $(cat /proc/cmdline) " in
    *' a14_aos_cpas_test=1 '*) ;;
    *) fail "this is not the isolated CAMSS diagnostic boot" ;;
esac

modules=$(mktemp)
trap 'rm -f "$modules"' EXIT
lsmod > "$modules"
grep -Eq '^qcom_camss[[:space:]]' "$modules" || fail "qcom_camss is not loaded"
if grep -Eq '^qcom_ssc_hpd[[:space:]]' "$modules"; then
    fail "qcom_ssc_hpd is loaded; unload it before diagnostics"
fi

attr=
for link in /sys/bus/platform/drivers/qcom-camss/*; do
    [ -L "$link" ] || continue
    dev=$(readlink -f "$link")
    candidate="$dev/aon_diag/aon_diag_stage"
    if [ -e "$candidate" ]; then
        attr=$candidate
        break
    fi
done
[ -n "$attr" ] || fail "diagnostic CAMSS sysfs attribute was not found"

restore_media() {
    set +e
    systemctl --user start pipewire.socket pipewire-pulse.socket 2>/dev/null
    systemctl --user start pipewire.service pipewire-pulse.service wireplumber.service 2>/dev/null
}
trap 'restore_media; rm -f "$modules"' EXIT INT TERM

sudo -v

systemctl --user stop pipewire-pulse.socket pipewire.socket 2>/dev/null || true
systemctl --user stop wireplumber.service pipewire-pulse.service pipewire.service 2>/dev/null || true
sleep 2

users=$(sudo fuser /dev/video* /dev/media* 2>/dev/null || true)
if [ -n "$users" ]; then
    sudo fuser -v /dev/video* /dev/media* 2>&1 || true
    fail "camera/media nodes remain busy; no diagnostic operation was attempted"
fi

boot_id=$(cat /proc/sys/kernel/random/boot_id)
started=$(date --iso-8601=seconds)
cat > "$marker" <<EOF
stage=$stage
stage_name=$stage_name
boot_id=$boot_id
started=$started
status=started
ssc_contacted=false
EOF
sync "$marker"
sync

exec > >(tee "$report") 2>&1

printf '%s\n' 'A14 CAMSS isolated AON diagnostic'
printf '%s\n' '=================================='
printf 'stage=%s\n' "$stage"
printf 'stage_name=%s\n' "$stage_name"
printf 'kernel_release=%s\n' "$release"
printf 'boot_id=%s\n' "$boot_id"
printf 'sysfs_attribute=%s\n' "$attr"
printf 'ssc_loaded=false\n'
printf 'camera_nodes=free\n'
printf 'marker=%s\n' "$marker"

printf '\n%s\n' '===== PRE-STAGE CAMERA BASELINE ====='
timeout 25 cam -l 2>&1 || fail "camera enumeration failed before diagnostic stage"
printf '%s\n' 'camera_baseline=validated'

# cam -l can cause the desktop media stack to reopen nodes after it exits.
sleep 1
users=$(sudo fuser /dev/video* /dev/media* 2>/dev/null || true)
if [ -n "$users" ]; then
    sudo fuser -v /dev/video* /dev/media* 2>&1 || true
    fail "camera/media nodes reopened after baseline; no diagnostic write was attempted"
fi

printf '\n%s\n' '===== EXECUTE ONE DIAGNOSTIC STAGE ====='
printf 'stage_started_at=%s\n' "$started"
printf 'sysfs_write=%s\n' "$stage"

set +e
sudo sh -c 'printf "%s\n" "$1" > "$2"' sh "$stage" "$attr"
stage_status=$?
set -e

completed=$(date --iso-8601=seconds)
cat > "$marker" <<EOF
stage=$stage
stage_name=$stage_name
boot_id=$boot_id
started=$started
completed=$completed
status=returned
return_status=$stage_status
ssc_contacted=false
EOF
sync "$marker"

printf 'stage_return_status=%s\n' "$stage_status"

printf '\n%s\n' '===== KERNEL DIAGNOSTIC LOG ====='
sudo journalctl -k -b --since "$started" --no-pager -o short-monotonic |
    grep -E 'AON-DIAG|qcom-camss|qcom_camss|watchdog|panic|SError|abort|Call trace' || true

printf '\n%s\n' '===== POST-STAGE CAMERA RESTORE ====='
timeout 25 cam -l 2>&1
camera_status=$?
printf 'camera_restore_status=%s\n' "$camera_status"

printf '\nreport=%s\n' "$report"
printf 'marker=%s\n' "$marker"

if [ "$stage_status" -ne 0 ]; then
    exit "$stage_status"
fi
if [ "$camera_status" -ne 0 ]; then
    exit "$camera_status"
fi
printf '%s\n' 'diagnostic_stage_result=success'
