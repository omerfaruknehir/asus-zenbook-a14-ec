#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Recover from a qcom_camss modalias/autoload race in the isolated A14 power
# diagnostic boot, load the validated staged module, then run the diagnostic.
set -Eeuo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
release=${A14_KERNEL_RELEASE:-$(uname -r)}
stage=${A14_AOS_POWER_DIAG_STAGE:-"$HOME/Downloads/a14-aos-power-diag-$release/artifacts"}
blocker=/run/modprobe.d/99-a14-aon-power-test.conf
blocker_installed=false
media_stopped=false
tmp=
attr=

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    set +e
    [ -z "$tmp" ] || rm -f "$tmp"
    if [ "$blocker_installed" = true ]; then
        sudo rm -f "$blocker" 2>/dev/null
    fi
    if [ "$media_stopped" = true ]; then
        systemctl --user start pipewire.socket pipewire-pulse.socket 2>/dev/null
        systemctl --user start pipewire.service pipewire-pulse.service wireplumber.service 2>/dev/null
    fi
}
trap cleanup EXIT INT TERM

for tool in fuser grep insmod install journalctl lsmod mktemp modinfo modprobe \
            readlink rm sha256sum sleep sudo systemctl tr uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done

[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this script as your normal user, not with sudo"
case " $(cat /proc/cmdline) " in
    *' a14_aos_power_test=1 '*) ;;
    *) fail "this is not the isolated A14 power-diagnostic boot" ;;
esac

if lsmod | grep -Eq '^qcom_ssc_hpd[[:space:]]'; then
    fail "qcom_ssc_hpd is loaded; the diagnostic was not attempted"
fi

find_diagnostic_attr() {
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
}

validate_staged_module() {
    [ -s "$stage/qcom-camss.ko" ] || fail "staged diagnostic CAMSS module is missing"
    [ -s "$stage/BUILD-INFO.txt" ] || fail "staged diagnostic BUILD-INFO.txt is missing"
    [ -s "$stage/SHA256SUMS" ] || fail "staged diagnostic SHA256SUMS is missing"

    (
        cd "$stage"
        sha256sum -c SHA256SUMS
    ) || fail "staged diagnostic artifact verification failed"

    grep -Fqx 'diagnostic_only=true' "$stage/BUILD-INFO.txt" || \
        fail "the staged module is not diagnostic-only"
    grep -Fqx 'diagnostic_generation=platform-power-stock-no-mmio-v2' \
        "$stage/BUILD-INFO.txt" || fail "the staged module has the wrong generation"
    grep -Fqx 'dtb_changes=false' "$stage/BUILD-INFO.txt" || \
        fail "the staged diagnostic unexpectedly requires DTB changes"
    grep -Fqx 'direct_cpas_mmio_allowed=false' "$stage/BUILD-INFO.txt" || \
        fail "the staged module does not prohibit direct CPAS MMIO"
    grep -Fqx 'ssc_activation_allowed=false' "$stage/BUILD-INFO.txt" || \
        fail "the staged module does not prohibit SSC activation"

    case "$(modinfo -F vermagic "$stage/qcom-camss.ko")" in
        "$release "*) ;;
        *) fail "staged CAMSS vermagic does not match $release" ;;
    esac

    grep -aFq 'AON-POWER-DIAG begin direct-mmio=false ssc=false' \
        "$stage/qcom-camss.ko" || fail "staged CAMSS lacks the non-MMIO probe"
    if grep -aEq 'AON-DIAG stage=3|ap-write-no-read|aon-switch-restore-no-read' \
            "$stage/qcom-camss.ko"; then
        fail "staged CAMSS contains a retired direct-MMIO diagnostic"
    fi
}

stop_media_and_require_idle() {
    systemctl --user stop pipewire-pulse.socket pipewire.socket 2>/dev/null || true
    systemctl --user stop wireplumber.service pipewire-pulse.service pipewire.service 2>/dev/null || true
    media_stopped=true
    sleep 2

    users=$(sudo fuser /dev/video* /dev/media* 2>/dev/null || true)
    if [ -n "$users" ]; then
        sudo fuser -v /dev/video* /dev/media* 2>&1 || true
        fail "camera/media nodes remain busy; CAMSS was not replaced or probed"
    fi
}

remove_unmarked_camss() {
    find_diagnostic_attr
    if [ -n "$attr" ]; then
        return 0
    fi
    if ! lsmod | grep -Eq '^qcom_camss[[:space:]]'; then
        return 0
    fi

    printf '%s\n' 'removing_raced_stock_qcom_camss=true'
    set +e
    sudo modprobe -r qcom_camss
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
        sudo journalctl -k -b --no-pager -n 140 -o short-monotonic |
            grep -E 'qcom-camss|qcom_camss|module|busy|in use|remove' || true
        fail "raced stock qcom_camss could not be removed with status $status"
    fi
    sleep 1
    lsmod | grep -Eq '^qcom_camss[[:space:]]' && \
        fail "qcom_camss reappeared despite the transient autoload block"
}

sudo -v
validate_staged_module
stop_media_and_require_idle

printf '%s\n' 'installing_transient_qcom_camss_autoload_block=true'
tmp=$(mktemp)
cat > "$tmp" <<'EOF_BLOCK'
# A14 isolated power diagnostic only. /run is cleared at reboot.
blacklist qcom_camss
install qcom_camss /bin/false
EOF_BLOCK
sudo install -d -m 0755 /run/modprobe.d
sudo install -m 0644 "$tmp" "$blocker"
blocker_installed=true
rm -f "$tmp"
tmp=

find_diagnostic_attr
if [ -n "$attr" ]; then
    printf '%s\n' 'diagnostic_qcom_camss_already_loaded=true'
else
    remove_unmarked_camss

    while IFS= read -r dependency; do
        dependency=${dependency//[[:space:]]/}
        [ -n "$dependency" ] || continue
        [ "$dependency" = qcom_camss ] && continue
        sudo modprobe "$dependency" || fail "could not load CAMSS dependency: $dependency"
    done < <(modinfo -F depends "$stage/qcom-camss.ko" | tr ',' '\n')

    # A final check after dependency loading closes the udev/modalias race.
    remove_unmarked_camss

    printf '%s\n' 'loading_validated_staged_qcom_camss=true'
    set +e
    sudo insmod "$stage/qcom-camss.ko"
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
        sleep 1
        find_diagnostic_attr
        if [ -z "$attr" ]; then
            sudo journalctl -k -b --no-pager -n 180 -o short-monotonic |
                grep -E 'qcom-camss|qcom_camss|module|Unknown symbol|verification|signature|File exists' || true
            fail "validated staged qcom_camss insertion failed with status $status"
        fi
    fi
fi

sleep 2
find_diagnostic_attr
[ -n "$attr" ] || {
    sudo journalctl -k -b --no-pager -n 180 -o short-monotonic |
        grep -E 'qcom-camss|qcom_camss|A14 power diagnostic|probe|defer|error|failed' || true
    fail "loaded qcom_camss does not expose the diagnostic-only attribute"
}

printf 'diagnostic_sysfs_attribute=%s\n' "$attr"
printf '%s\n' 'transient_autoload_block=/run/modprobe.d/99-a14-aon-power-test.conf'
printf '%s\n' 'direct_cpas_mmio=false'
printf '%s\n' 'ssc_contact=false'
printf '%s\n' 'diagnostic_module_load=validated'
printf '\n%s\n' '===== STARTING POWER DIAGNOSTIC ====='

# The block intentionally remains for this isolated boot. /run is ephemeral and
# is cleared automatically on reboot. The runner owns media-service restoration.
trap - EXIT INT TERM
exec bash "$repo/scripts/a14-aos-power-diag-run.sh"
