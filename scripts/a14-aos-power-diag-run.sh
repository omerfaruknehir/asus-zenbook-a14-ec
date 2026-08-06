#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Exercise only the CAMSS platform-power prerequisite. No CPAS MMIO and no SSC.
set -Eeuo pipefail

release=${A14_KERNEL_RELEASE:-$(uname -r)}
stage=${A14_AOS_POWER_DIAG_STAGE:-"$HOME/Downloads/a14-aos-power-diag-$release/artifacts"}
report=${A14_AOS_POWER_DIAG_REPORT:-"$HOME/Downloads/a14-aos-power-diag-report.txt"}
marker=${A14_AOS_POWER_DIAG_MARKER:-"$HOME/Downloads/a14-aos-power-diag-last-run.txt"}
module_load_mode=initramfs

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

for tool in cam cat date fuser grep insmod journalctl lsmod modinfo modprobe \
            readlink sha256sum sleep sudo sync systemctl timeout tr uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done

[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this script as your normal user, not with sudo"
case " $(cat /proc/cmdline) " in
    *' a14_aos_power_test=1 '*) ;;
    *) fail "this is not the isolated A14 power-diagnostic boot" ;;
esac

if lsmod | grep -Eq '^qcom_ssc_hpd[[:space:]]'; then
    fail "qcom_ssc_hpd is loaded; unload it before the power diagnostic"
fi

sudo -v

# Some initramfs-tools configurations include the replacement module but do not
# process /conf/modules before switching to the real root. In that case, load
# the already validated staged module directly. This remains diagnostic-only:
# it does not install into /lib/modules, contact SSC, or access CPAS MMIO.
if ! lsmod | grep -Eq '^qcom_camss[[:space:]]'; then
    [ -s "$stage/qcom-camss.ko" ] || \
        fail "staged power-diagnostic CAMSS module is missing"
    [ -s "$stage/BUILD-INFO.txt" ] || \
        fail "staged power-diagnostic BUILD-INFO.txt is missing"
    [ -s "$stage/SHA256SUMS" ] || \
        fail "staged power-diagnostic SHA256SUMS is missing"

    (
        cd "$stage"
        sha256sum -c SHA256SUMS
    ) || fail "staged power-diagnostic artifact verification failed"

    grep -Fqx 'diagnostic_only=true' "$stage/BUILD-INFO.txt" || \
        fail "the staged CAMSS module is not diagnostic-only"
    grep -Fqx 'diagnostic_generation=platform-power-stock-no-mmio-v2' \
        "$stage/BUILD-INFO.txt" || \
        fail "the staged CAMSS module has the wrong diagnostic generation"
    grep -Fqx 'direct_cpas_mmio_allowed=false' "$stage/BUILD-INFO.txt" || \
        fail "the staged CAMSS module does not prohibit direct CPAS MMIO"
    grep -Fqx 'ssc_activation_allowed=false' "$stage/BUILD-INFO.txt" || \
        fail "the staged CAMSS module does not prohibit SSC activation"

    case "$(modinfo -F vermagic "$stage/qcom-camss.ko")" in
        "$release "*) ;;
        *) fail "staged CAMSS vermagic does not match $release" ;;
    esac
    grep -aFq 'AON-POWER-DIAG begin direct-mmio=false ssc=false' \
        "$stage/qcom-camss.ko" || \
        fail "staged CAMSS lacks the non-MMIO power probe"
    if grep -aEq 'AON-DIAG stage=3|ap-write-no-read|aon-switch-restore-no-read' \
            "$stage/qcom-camss.ko"; then
        fail "staged CAMSS contains a retired direct-MMIO diagnostic"
    fi

    printf '%s\n' 'qcom_camss_initramfs_autoload=false'
    printf '%s\n' 'loading_staged_diagnostic_module=true'

    while IFS= read -r dependency; do
        [ -n "$dependency" ] || continue
        sudo modprobe "$dependency" || \
            fail "could not load CAMSS dependency: $dependency"
    done < <(modinfo -F depends "$stage/qcom-camss.ko" | tr ',' '\n')

    set +e
    sudo insmod "$stage/qcom-camss.ko"
    module_status=$?
    set -e
    if [ "$module_status" -ne 0 ]; then
        sudo journalctl -k -b --no-pager -n 120 -o short-monotonic |
            grep -E 'qcom-camss|qcom_camss|module|Unknown symbol|verification|signature' || true
        fail "staged qcom_camss insertion failed with status $module_status"
    fi
    sleep 2
    module_load_mode=runner-validated-insmod
fi

lsmod | grep -Eq '^qcom_camss[[:space:]]' || fail "qcom_camss is not loaded"

attr=
for link in /sys/bus/platform/drivers/qcom-camss/*; do
    [ -L "$link" ] || continue
    dev=$(readlink -f "$link")
    candidate="$dev/a14_aon_power_diag/a14_aon_power_probe"
    if [ -e "$candidate" ]; then
        attr=$candidate
        break
    fi
done
[ -n "$attr" ] || {
    sudo journalctl -k -b --no-pager -n 160 -o short-monotonic |
        grep -E 'qcom-camss|qcom_camss|A14 power diagnostic|probe|defer|error|failed' || true
    fail "the stock-source CAMSS power-diagnostic attribute was not found"
}

restore_media() {
    set +e
    systemctl --user start pipewire.socket pipewire-pulse.socket 2>/dev/null
    systemctl --user start pipewire.service pipewire-pulse.service wireplumber.service 2>/dev/null
}
trap restore_media EXIT INT TERM

systemctl --user stop pipewire-pulse.socket pipewire.socket 2>/dev/null || true
systemctl --user stop wireplumber.service pipewire-pulse.service pipewire.service 2>/dev/null || true
sleep 2

users=$(sudo fuser /dev/video* /dev/media* 2>/dev/null || true)
if [ -n "$users" ]; then
    sudo fuser -v /dev/video* /dev/media* 2>&1 || true
    fail "camera/media nodes remain busy; the power diagnostic was not attempted"
fi

boot_id=$(cat /proc/sys/kernel/random/boot_id)
started=$(date --iso-8601=seconds)
cat > "$marker" <<EOF_MARKER
operation=platform-power-stock-no-mmio-v2
boot_id=$boot_id
started=$started
status=started
module_load_mode=$module_load_mode
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
printf 'module_load_mode=%s\n' "$module_load_mode"
printf 'sysfs_attribute=%s\n' "$attr"
printf 'ssc_loaded=false\n'
printf 'direct_cpas_mmio=false\n'
printf 'dtb_changes=false\n'
printf 'platform_clock_count=7\n'
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
printf 'sysfs_write=1\n'
printf 'direct_cpas_mmio=false\n'
printf 'ssc_contacted=false\n'

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
module_load_mode=$module_load_mode
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
