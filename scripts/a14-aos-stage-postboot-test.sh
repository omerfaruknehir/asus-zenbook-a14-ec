#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Validate the one-shot A14 AOS/CPAS boot and optionally run a bounded HPD test.
set -Eeuo pipefail

mode=${1:---discover}
case "$mode" in
    --discover|--activate) ;;
    *)
        echo "Usage: $0 [--discover|--activate]" >&2
        exit 2
        ;;
esac

release=${A14_KERNEL_RELEASE:-$(uname -r)}
stage=${A14_AOS_STAGE:-"$HOME/Downloads/a14-aos-stage-$release/artifacts"}
report=${A14_AOS_REPORT:-"$HOME/Downloads/a14-aos-postboot-${mode#--}.txt"}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

for tool in cam cat date find grep insmod journalctl lsmod modinfo python3 rmmod seq sleep sudo tail tee timeout; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done

[ -s "$stage/qcom_ssc_hpd.ko" ] || fail "staged SSC module is missing"
case "$(modinfo -F vermagic "$stage/qcom_ssc_hpd.ko")" in
    "$release "*) ;;
    *) fail "staged SSC vermagic does not match $release" ;;
esac

exec > >(tee "$report") 2>&1

printf '%s\n' 'A14 AOS/CPAS post-boot validation'
printf '%s\n' '================================='
printf 'mode=%s\n' "$mode"
printf 'kernel_release=%s\n' "$release"
printf 'cmdline=%s\n' "$(cat /proc/cmdline)"

case " $(cat /proc/cmdline) " in
    *' a14_aos_cpas_test=1 '*) ;;
    *) fail "this is not the one-shot AOS/CPAS test boot" ;;
esac

printf '\n%s\n' '===== LIVE DEVICE TREE ====='
camss_node=/sys/firmware/devicetree/base/soc@0/isp@acb7000
[ -d "$camss_node" ] || fail "live CAMSS node is missing"
python3 <<'PY'
from pathlib import Path
import struct
node = Path('/sys/firmware/devicetree/base/soc@0/isp@acb7000')
names = [p.decode() for p in node.joinpath('reg-names').read_bytes().rstrip(b'\0').split(b'\0')]
raw = node.joinpath('reg').read_bytes()
cells = struct.unpack('>' + 'I' * (len(raw) // 4), raw)
entries = []
for i in range(0, len(cells), 4):
    address = (cells[i] << 32) | cells[i + 1]
    size = (cells[i + 2] << 32) | cells[i + 3]
    entries.append((address, size))
print(f'camss_resource_count={len(entries)}')
for i, (address, size) in enumerate(entries):
    name = names[i] if i < len(names) else f'unnamed-{i}'
    print(f'camss_resource_{i:02d}={name},0x{address:08x},0x{size:x}')
if len(entries) != 18 or len(names) != 18:
    raise SystemExit('expected 18 CAMSS resources')
if names[-1] != 'cpas-top' or entries[-1] != (0x0ac19000, 0xc000):
    raise SystemExit('live cpas-top resource is incorrect')
PY
printf '%s\n' 'live_dtb=validated'

printf '\n%s\n' '===== PATCHED CAMSS MODULE ====='
lsmod | grep -E '^qcom_camss[[:space:]]' || fail "qcom_camss is not loaded"
grep -wq 'qcom_camss_aon_acquire' /proc/kallsyms || fail "loaded CAMSS lacks AON acquire symbol"
grep -wq 'qcom_camss_aon_release' /proc/kallsyms || fail "loaded CAMSS lacks AON release symbol"
printf 'qcom_camss_refcnt=%s\n' "$(cat /sys/module/qcom_camss/refcnt 2>/dev/null || echo N/A)"
printf '%s\n' 'patched_camss=validated'

printf '\n%s\n' '===== NORMAL CAMERA BASELINE ====='
timeout 25 cam -l 2>&1 || fail "camera enumeration failed before SSC loading"
printf '%s\n' 'normal_camera_enumeration=completed'

printf '\n%s\n' '===== LOAD SSC HPD CONSUMER ====='
sudo rmmod qcom_ssc_hpd 2>/dev/null || true
sudo insmod "$stage/qcom_ssc_hpd.ko"
sleep 6
lsmod | grep -E '^qcom_ssc_hpd[[:space:]]' || fail "qcom_ssc_hpd did not load"

sudo journalctl -k -b --since '2 minutes ago' --no-pager |
    grep -E 'qcom-ssc-hpd|CAMSS AON|SSC datatype|camera_handshake|human_presence|camera_face' |
    tail -n 160 || true

dev=
for candidate in /sys/bus/iio/devices/iio:device*; do
    [ -r "$candidate/name" ] || continue
    [ "$(cat "$candidate/name")" = qcom-ssc-human-presence ] || continue
    dev=$candidate
    break
done
[ -n "$dev" ] || fail "human-presence IIO device was not registered"
printf 'iio_device=%s\n' "$dev"
printf '%s\n' 'ssc_discovery=validated'

if [ "$mode" = --discover ]; then
    printf '\nDiscovery-only validation completed. No camera ownership request was sent.\n'
    printf 'report=%s\n' "$report"
    exit 0
fi

printf '\n%s\n' '===== BOUNDED HUMAN-PRESENCE ACTIVATION ====='
event=$(find "$dev/events" -maxdepth 1 -type f -name '*proximity*change*en' -print -quit)
[ -n "$event" ] || fail "IIO proximity event control is missing"
printf 'event_control=%s\n' "$event"

cleanup() {
    set +e
    echo 0 | sudo tee "$event" >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

set +e
printf '1\n' | sudo tee "$event"
activate_status=${PIPESTATUS[1]}
set -e
printf 'activation_status=%s\n' "$activate_status"

if [ "$activate_status" -eq 0 ]; then
    for _ in $(seq 1 24); do
        printf '%s presence=' "$(date +%T)"
        cat "$dev/in_proximity_raw" 2>&1 || true
        sleep 0.5
    done
fi

cleanup
trap - EXIT INT TERM
sleep 2

printf '\n%s\n' '===== ACTIVATION LOG ====='
sudo journalctl -k -b --since '3 minutes ago' --no-pager |
    grep -E 'qcom-ssc-hpd|CAMSS camera path|AON|camera handshake|ACK|SSC rejected|SSC sensor|presence' |
    tail -n 240 || true

printf '\n%s\n' '===== AP CAMERA RESTORE CHECK ====='
timeout 25 cam -l 2>&1 || fail "camera enumeration failed after AOS release"
printf '%s\n' 'normal_camera_restore=validated'
printf 'report=%s\n' "$report"

if [ "$activate_status" -ne 0 ]; then
    exit "$activate_status"
fi
