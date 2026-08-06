#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Execute the non-MMIO CAMSS power probe after the diagnostic module and its
# private sysfs attribute have already been validated by the recovery launcher.
set -Eeuo pipefail

release=${A14_KERNEL_RELEASE:-$(uname -r)}
report=${A14_AOS_POWER_DIAG_REPORT:-"$HOME/Downloads/a14-aos-power-diag-report.txt"}
marker=${A14_AOS_POWER_DIAG_MARKER:-"$HOME/Downloads/a14-aos-power-diag-last-run.txt"}
attr=
media_stopped=false

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

restore_media() {
    set +e
    if [ "$media_stopped" = true ]; then
        systemctl --user start pipewire.socket pipewire-pulse.socket 2>/dev/null
        systemctl --user start pipewire.service pipewire-pulse.service wireplumber.service 2>/dev/null
    fi
}
trap restore_media EXIT INT TERM

for tool in cam cat date fuser grep journalctl readlink sleep sudo sync \
            systemctl timeout uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done

[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this script as your normal user, not with sudo"
case " $(cat /proc/cmdline) " in
    *' a14_aos_power_test=1 '*) ;;
    *) fail "this is not the isolated A14 power-diagnostic boot" ;;
esac

# Read /proc/modules directly. Pipelines such as `lsmod | grep -q` are unsafe
# under pipefail because grep can exit early and make the producer report
# SIGPIPE even when the module was found.
grep -Eq '^qcom_camss[[:space:]]' /proc/modules || \
    fail "qcom_camss is not loaded"
if grep -Eq '^qcom_ssc_hpd[[:space:]]' /proc/modules; then
    fail "qcom_ssc_hpd is loaded; the power diagnostic was not attempted"
fi

for link in /sys/bus/platform/drivers/qcom-camss/*; do
    [ -L "$link" ] || continue
    dev=$(readlink -f "$link")
    candidate="$dev/a14_aon_power_diag/a14_aon_power_probe"
    if [ -e "$candidate" ]; then
        attr=$candidate
        break
    fi
done
[ -n "$attr" ] || fail "the loaded CAMSS module lacks the diagnostic-only attribute"

sudo -v
systemctl --user stop pipewire-pulse.socket pipewire.socket 2>/dev/null || true
systemctl --user stop wireplumber.service pipewire-pulse.service pipewire.service 2>/dev/null || true
media_stopped=true
sleep 2

users=$(sudo fuser /dev/video* /dev/media* 2>/dev/null || true)
if [ -n "$users" ]; then
    sudo fuser -v /dev/video* /dev/media* 2>&1 || true
    fail "camera/media nodes remain busy; the power probe was not attempted"
fi

boot_id=$(cat /proc/sys/kernel/random/boot_id)
started=$(date --iso-8601=seconds)
cat > "$marker" <<EOF_MARKER
operation=platform-power-stock-no-mmio-v2
boot_id=$boot_id
started=$started
status=started
module_load_mode=prevalidated-loaded-diagnostic
ssc_contacted=false
direct_cpas_mmio=false
dtb_changes=false
platform_clock_count=7
EOF_MARKER
sync "$marker"
sync

exec > >(tee "$report") 2>&1

printf '%s\n' 'A14 CAMSS stock-source platform-power diagnostic'
printf '%s\n' '================================================'
printf 'kernel_release=%s\n' "$release"
printf 'boot_id=%s\n' "$boot_id"
printf '%s\n' 'module_load_mode=prevalidated-loaded-diagnostic'
printf 'sysfs_attribute=%s\n' "$attr"
printf '%s\n' 'ssc_loaded=false'
printf '%s\n' 'direct_cpas_mmio=false'
printf '%s\n' 'dtb_changes=false'
printf '%s\n' 'platform_clock_count=7'
printf 'marker=%s\n' "$marker"

printf '\n%s\n' '===== PRE-PROBE CAMERA BASELINE ====='
timeout 25 cam -l 2>&1 || fail "camera enumeration failed before the power probe"
printf '%s\n' 'camera_baseline=validated'

sleep 1
users=$(sudo fuser /dev/video* /dev/media* 2>/dev/null || true)
if [ -n "$users" ]; then
    sudo fuser -v /dev/video* /dev/media* 2>&1 || true
    fail "camera/media nodes reopened after baseline; the power probe was not attempted"
fi

printf '\n%s\n' '===== EXECUTE NON-MMIO POWER PROBE ====='
printf 'probe_started_at=%s\n' "$started"
printf '%s\n' 'sysfs_write=1'
printf '%s\n' 'direct_cpas_mmio=false'
printf '%s\n' 'ssc_contacted=false'

set +e
sudo sh -c 'printf "1\n" > "$1"' sh "$attr"
probe_status=$?
set -e

completed=$(date --iso-8601=seconds)
cat > "$marker" <<EOF_MARKER
operation=platform-power-stock-no-mmio-v2
boot_id=$boot_id
started=$started
completed=$completed
status=returned
return_status=$probe_status
module_load_mode=prevalidated-loaded-diagnostic
ssc_contacted=false
direct_cpas_mmio=false
dtb_changes=false
platform_clock_count=7
EOF_MARKER
sync "$marker"

printf 'probe_return_status=%s\n' "$probe_status"
printf '\n%s\n' '===== KERNEL POWER-DIAGNOSTIC LOG ====='
sudo journalctl -k -b --since "$started" --no-pager -o short-monotonic |
    grep -E 'AON-POWER-DIAG|A14 power diagnostic|qcom-camss|qcom_camss|watchdog|panic|SError|abort|Call trace' || true

printf '\n%s\n' '===== POST-PROBE CAMERA RESTORE ====='
set +e
timeout 25 cam -l 2>&1
camera_status=$?
set -e
printf 'camera_restore_status=%s\n' "$camera_status"

printf '\nreport=%s\n' "$report"
printf 'marker=%s\n' "$marker"

if [ "$probe_status" -ne 0 ]; then
    exit "$probe_status"
fi
if [ "$camera_status" -ne 0 ]; then
    exit "$camera_status"
fi
printf '%s\n' 'power_diagnostic_result=success'
