#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Discriminate whether SSC camera-handshake can succeed under the already
# validated full Windows-F0 owner state without touching the CPAS ownership mux.
set -Eeuo pipefail

release=${A14_KERNEL_RELEASE:-$(uname -r)}
work=${A14_AOS_F0_ICP_OWNER_WORK:-"$HOME/Downloads/a14-aos-f0-icp-owner-diag-$release"}
stage=${A14_AOS_F0_SSC_STAGE:-"$work/ssc-handshake-artifacts"}
report=${A14_AOS_F0_SSC_REPORT:-"$HOME/Downloads/a14-aos-f0-ssc-handshake-report.txt"}
klog=${A14_AOS_F0_SSC_KLOG:-"$HOME/Downloads/a14-aos-f0-ssc-handshake-kernel.log"}
marker=${A14_AOS_F0_SSC_MARKER:-"$HOME/Downloads/a14-aos-f0-ssc-handshake-last-run.txt"}
hold_ms=${A14_AOS_F0_SSC_HOLD_MS:-4500}
camss_probe=
camss_hold=
camss_status=
camss_dev=
iio_dev=
event_enable=
hold_pid=
media_stopped=false
hpd_loaded=false
tmp_camera=

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
cleanup() {
    set +e
    if [ -n "$hold_pid" ]; then
        wait "$hold_pid" 2>/dev/null || true
    fi
    if [ -n "$event_enable" ] && [ -e "$event_enable" ]; then
        sudo sh -c 'printf "0\n" > "$1"' sh "$event_enable" 2>/dev/null || true
    fi
    if [ "$hpd_loaded" = true ]; then
        # This module is loaded with insmod from the staging directory, so use
        # the symmetric direct unload path rather than relying on /lib/modules
        # indexing through modprobe.
        sudo rmmod qcom_ssc_hpd 2>/dev/null || true
    fi
    [ -z "$tmp_camera" ] || rm -f "$tmp_camera"
    if [ "$media_stopped" = true ]; then
        systemctl --user start pipewire.socket pipewire-pulse.socket 2>/dev/null || true
        systemctl --user start pipewire.service pipewire-pulse.service wireplumber.service 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

for tool in awk cam cat date find fuser grep insmod journalctl lsmod mktemp rmmod \
            readlink rm seq sleep sort sudo sync systemctl tee timeout uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this script as your normal user, not with sudo"
case " $(cat /proc/cmdline) " in
    *' a14_aos_f0_icp_owner_test=1 '*) ;;
    *) fail "this is not the isolated full-F0 owner test boot" ;;
esac
case "$hold_ms" in
    *[!0-9]*|'') fail "hold duration must be an integer" ;;
esac
[ "$hold_ms" -ge 3500 ] && [ "$hold_ms" -le 5000 ] || \
    fail "hold duration must be 3500..5000 ms for this discriminator"

[ -s "$stage/qcom_ssc_hpd.ko" ] || fail "diagnostic HPD module is missing: $stage/qcom_ssc_hpd.ko"
grep -Eq '^qcom_camss[[:space:]]' /proc/modules || fail "diagnostic qcom_camss is not loaded"
grep -Eq '^i2c_qcom_cci[[:space:]]' /proc/modules || fail "diagnostic i2c_qcom_cci is not loaded"
if grep -Eq '^qcom_ssc_hpd[[:space:]]' /proc/modules; then
    fail "qcom_ssc_hpd is already loaded; start from a clean isolated boot"
fi

for link in /sys/bus/platform/drivers/qcom-camss/*; do
    [ -L "$link" ] || continue
    dev=$(readlink -f "$link")
    p="$dev/a14_f0_icp_owner_diag/a14_f0_icp_owner_probe"
    h="$dev/a14_f0_icp_owner_diag/a14_f0_icp_owner_hold_ms"
    s="$dev/a14_f0_icp_owner_diag/a14_f0_icp_owner_status"
    if [ -e "$p" ] && [ -e "$h" ] && [ -r "$s" ]; then
        camss_dev=$dev
        camss_probe=$p
        camss_hold=$h
        camss_status=$s
        break
    fi
done
[ -n "$camss_probe" ] || fail "extended full-F0 CAMSS diagnostic was not found"

printf '%s\n' 'A14 full-F0 + SSC camera-handshake discriminator'
printf '%s\n' '================================================='
printf 'kernel_release=%s\n' "$release"
printf 'hold_ms=%s\n' "$hold_ms"
printf 'stage=%s\n' "$stage"
printf '%s\n' 'cpas_ownership_mux_access=false'
printf '%s\n' 'direct_cpas_mmio=false'
printf '%s\n' 'ssc_handshake=true'
printf '%s\n' 'hpd_config_if_handshake_succeeds=true'
printf 'camss_status=%s\n' "$(cat "$camss_status")"

boot_id=$(cat /proc/sys/kernel/random/boot_id)
if [ -s "$marker" ] && grep -Fqx "boot_id=$boot_id" "$marker"; then
    fail "this discriminator was already attempted in the current boot; reboot before repeating it"
fi

sudo -v
systemctl --user stop pipewire-pulse.socket pipewire.socket 2>/dev/null || true
systemctl --user stop wireplumber.service pipewire-pulse.service pipewire.service 2>/dev/null || true
media_stopped=true
sleep 2
users=$(sudo fuser /dev/video* /dev/media* /dev/v4l-subdev* 2>/dev/null || true)
if [ -n "$users" ]; then
    sudo fuser -v /dev/video* /dev/media* /dev/v4l-subdev* 2>&1 || true
    fail "camera/media nodes remain busy; SSC discriminator was not attempted"
fi

printf '\n%s\n' '===== PRE-TEST CAMERA BASELINE ====='
tmp_camera=$(mktemp)
sudo timeout 25 cam -l >"$tmp_camera" 2>&1 || { cat "$tmp_camera"; fail "camera baseline failed"; }
cat "$tmp_camera"
grep -Eq '^[[:space:]]*[0-9]+:' "$tmp_camera" || fail "camera baseline returned no accessible cameras"
rm -f "$tmp_camera"; tmp_camera=

for dev in "$camss_dev" /sys/bus/platform/devices/ac15000.cci /sys/bus/platform/devices/ac16000.cci; do
    [ "$(cat "$dev/power/runtime_status" 2>/dev/null || true)" = suspended ] || \
        fail "owner is not runtime-suspended before test: $dev"
done

started=$(date --iso-8601=ns)
cat > "$marker" <<EOF_MARKER
operation=full-f0-ssc-handshake-no-cpas-mux-v1
boot_id=$boot_id
started=$started
status=started
hold_ms=$hold_ms
cpas_ownership_mux_access=false
direct_cpas_mmio=false
ssc_handshake=true
EOF_MARKER
sync "$marker"; sync

exec > >(tee "$report") 2>&1

printf '\n%s\n' '===== LOAD MANUALLY-GATED HPD MODULE ====='
sudo insmod "$stage/qcom_ssc_hpd.ko" allow_unrouted_handshake_probe=1
hpd_loaded=true

# Locate the IIO frontend produced by this exact module instance.
for _ in $(seq 1 50); do
    for d in /sys/bus/iio/devices/iio:device*; do
        [ -r "$d/name" ] || continue
        if [ "$(cat "$d/name")" = qcom-ssc-human-presence ]; then
            iio_dev=$d
            break 2
        fi
    done
    sleep 0.1
done
[ -n "$iio_dev" ] || fail "HPD IIO device did not appear"
printf 'iio_device=%s\n' "$iio_dev"

# Wait for the three already-known SUIDs so the test discriminates the camera
# handshake itself rather than QRTR discovery timing.
for _ in $(seq 1 60); do
    discovery=$(sudo journalctl -k -b --no-pager -o cat | \
        grep -E 'SSC datatype (camera_handshake|human_presence_detect|camera_face_detect) SUID' || true)
    if grep -q 'camera_handshake' <<<"$discovery" && \
       grep -q 'human_presence_detect' <<<"$discovery" && \
       grep -q 'camera_face_detect' <<<"$discovery"; then
        break
    fi
    sleep 0.1
done
discovery=$(sudo journalctl -k -b --no-pager -o cat | \
    grep -E 'SSC datatype (camera_handshake|human_presence_detect|camera_face_detect) SUID' || true)
grep -q 'camera_handshake' <<<"$discovery" || fail "camera_handshake SUID was not discovered"
grep -q 'human_presence_detect' <<<"$discovery" || fail "human_presence_detect SUID was not discovered"
grep -q 'camera_face_detect' <<<"$discovery" || fail "camera_face_detect SUID was not discovered"
printf '%s\n' "$discovery"

mapfile -t event_attrs < <(find "$iio_dev/events" -maxdepth 1 -type f -name '*_en' -print 2>/dev/null | sort)
[ "${#event_attrs[@]}" -eq 1 ] || fail "expected exactly one IIO event-enable attribute, found ${#event_attrs[@]}"
event_enable=${event_attrs[0]}
printf 'event_enable=%s\n' "$event_enable"

printf '\n%s\n' '===== ESTABLISH FULL-F0 OWNER HOLD ====='
sudo sh -c 'printf "%s\n" "$1" > "$2"' sh "$hold_ms" "$camss_hold"
printf 'configured_hold_ms=%s\n' "$(cat "$camss_hold")"

sudo sh -c 'printf "1\n" > "$1"' sh "$camss_probe" &
hold_pid=$!

hold_ready=false
for _ in $(seq 1 40); do
    # Do not use journalctl | grep -q under pipefail: grep exits on the first
    # match and journalctl can then report SIGPIPE, falsely making the pipeline
    # fail. Capture the finite recent log first.
    recent_klog=$(sudo journalctl -k -b -n 160 --no-pager -o cat)
    if grep -Fq "AON-F0-ICP-OWNER-DIAG targets-ok hold-ms=$hold_ms" <<< "$recent_klog"; then
        hold_ready=true
        break
    fi
    sleep 0.05
done
[ "$hold_ready" = true ] || fail "full-F0 target marker did not appear before handshake"
printf '%s\n' 'full_f0_hold=active'
printf '%s\n' 'cpas_ownership_mux_access=false'

printf '\n%s\n' '===== ATTEMPT REAL SSC CAMERA HANDSHAKE ====='
set +e
sudo sh -c 'printf "1\n" > "$1"' sh "$event_enable"
enable_rc=$?
set -e
printf 'event_enable_write_status=%s\n' "$enable_rc"

# If the handshake/config succeeded, give the first HPD report a brief window,
# inspect the raw value, then tear the SSC client down while F0 is still held.
sleep 0.35
raw_status=unavailable
raw_value=
if [ -r "$iio_dev/in_proximity_raw" ]; then
    set +e
    raw_value=$(cat "$iio_dev/in_proximity_raw" 2>/dev/null)
    raw_rc=$?
    set -e
    if [ "$raw_rc" -eq 0 ]; then
        raw_status=valid
    else
        raw_status=no-data
    fi
fi
printf 'presence_raw_status=%s\n' "$raw_status"
[ -z "$raw_value" ] || printf 'presence_raw=%s\n' "$raw_value"

set +e
sudo sh -c 'printf "0\n" > "$1"' sh "$event_enable"
disable_rc=$?
set -e
printf 'event_disable_write_status=%s\n' "$disable_rc"

set +e
wait "$hold_pid"
hold_rc=$?
set -e
hold_pid=
printf 'full_f0_hold_status=%s\n' "$hold_rc"

printf '\n%s\n' '===== CAPTURE DISCRIMINATING KERNEL LOG ====='
# Keep ordinary watchdog initialization messages out of the diagnostic log.
# They previously caused a false fault result merely because the word
# "watchdog" appeared during boot.
sudo journalctl -k -b --no-pager -o short-monotonic | \
    grep -E 'AON-F0-ICP-OWNER-DIAG|qcom-ssc-hpd|qcom_ssc_hpd|SSC datatype|camera handshake|presence activation|SSC sensor error|DIAGNOSTIC: attempting SSC handshake|panic|SError|Call trace|Internal error|Oops|soft lockup|hard LOCKUP|watchdog: BUG' \
    > "$klog" || true
cat "$klog"

result=indeterminate
if grep -Fq 'camera handshake ACK error_state=0' "$klog"; then
    result=handshake-ack-with-full-f0-no-mux
elif grep -Fq 'camera handshake ACK 832 timed out' "$klog"; then
    result=handshake-timeout-full-f0-no-mux
elif grep -Eq 'camera handshake ACK error_state=[1-9]' "$klog"; then
    result=handshake-rejected-full-f0-no-mux
elif [ "$enable_rc" -ne 0 ]; then
    result=handshake-or-config-failed-no-ack
fi
printf 'discriminator_result=%s\n' "$result"

fault_detected=false
if grep -Eq 'Kernel panic|panic:|SError|Call trace:|Internal error:|Oops:|soft lockup|hard LOCKUP|watchdog: BUG' "$klog"; then
    fault_detected=true
    printf '%s\n' 'kernel_fault_detected=true'
else
    printf '%s\n' 'kernel_fault_detected=false'
fi
[ "$hold_rc" -eq 0 ] || fail "full-F0 owner hold failed with status $hold_rc"

printf '\n%s\n' '===== CLEANUP / CAMERA RESTORE ====='
sudo rmmod qcom_ssc_hpd
hpd_loaded=false
for _ in $(seq 1 30); do
    cs=$(cat "$camss_dev/power/runtime_status" 2>/dev/null || true)
    c0=$(cat /sys/bus/platform/devices/ac15000.cci/power/runtime_status 2>/dev/null || true)
    c1=$(cat /sys/bus/platform/devices/ac16000.cci/power/runtime_status 2>/dev/null || true)
    [ "$cs" = suspended ] && [ "$c0" = suspended ] && [ "$c1" = suspended ] && break
    sleep 0.2
done
printf 'post_camss_runtime=%s\n' "$cs"
printf 'post_cci0_runtime=%s\n' "$c0"
printf 'post_cci1_runtime=%s\n' "$c1"
[ "$cs" = suspended ] && [ "$c0" = suspended ] && [ "$c1" = suspended ] || \
    fail "one or more platform owners did not return to runtime suspend"

tmp_camera=$(mktemp)
sudo timeout 25 cam -l >"$tmp_camera" 2>&1 || { cat "$tmp_camera"; fail "camera restore enumeration failed"; }
cat "$tmp_camera"
grep -Eq '^[[:space:]]*[0-9]+:' "$tmp_camera" || fail "camera restore returned no accessible cameras"
rm -f "$tmp_camera"; tmp_camera=
printf '%s\n' 'camera_restore=validated'

completed=$(date --iso-8601=ns)
cat > "$marker" <<EOF_MARKER
operation=full-f0-ssc-handshake-no-cpas-mux-v1
boot_id=$boot_id
started=$started
completed=$completed
status=returned
result=$result
event_enable_write_status=$enable_rc
full_f0_hold_status=$hold_rc
presence_raw_status=$raw_status
kernel_fault_detected=$fault_detected
cpas_ownership_mux_access=false
direct_cpas_mmio=false
EOF_MARKER
sync "$marker"; sync

printf '\n%s\n' '===== RESULT ====='
printf 'result=%s\n' "$result"
printf 'kernel_fault_detected=%s\n' "$fault_detected"
printf 'report=%s\n' "$report"
printf 'kernel_log=%s\n' "$klog"
printf 'marker=%s\n' "$marker"
printf '%s\n' 'cpas_ownership_mux_access=false'
printf '%s\n' 'direct_cpas_mmio=false'

if [ "$fault_detected" = true ]; then
    fail "kernel fault marker detected during discriminator"
fi
