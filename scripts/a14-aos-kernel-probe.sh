#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Read-only Linux discovery for the ASUS Zenbook A14 always-on camera path.
set -eu

usage() {
    cat <<'USAGE'
Usage: sudo ./scripts/a14-aos-kernel-probe.sh [--output-dir DIR]

Collects a small, targeted report for kernel/device-tree/firmware development.
It does not load or unload modules, restart remote processors, write registers,
or modify firmware files.
USAGE
}

output_dir=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output-dir)
            [ "$#" -ge 2 ] || { echo "--output-dir requires a value" >&2; exit 2; }
            output_dir=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    owner=$SUDO_USER
    owner_home=$(getent passwd "$owner" | awk -F: '{print $6}')
else
    owner=$(id -un)
    owner_home=${HOME:-/tmp}
fi

[ -n "$output_dir" ] || output_dir="$owner_home/Downloads"
mkdir -p "$output_dir"

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
report_name="a14-aos-kernel-probe-$timestamp"
work=$(mktemp -d "${TMPDIR:-/tmp}/${report_name}.XXXXXX")
report="$work/$report_name"
archive="$output_dir/$report_name.tar.gz"
mkdir -p "$report"

cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

if [ -r /proc/device-tree/model ]; then
    model=$(tr -d '\000' </proc/device-tree/model 2>/dev/null || true)
else
    model=
fi
if [ -r /proc/device-tree/compatible ]; then
    compatible=$(tr '\000' '\n' </proc/device-tree/compatible 2>/dev/null || true)
else
    compatible=
fi

{
    echo "ASUS Zenbook A14 kernel AOS discovery"
    echo "======================================"
    echo "timestamp_utc=$timestamp"
    echo "model=${model:-unknown}"
    echo "kernel=$(uname -r)"
    echo "architecture=$(uname -m)"
    echo "uid=$(id -u)"
    echo "read_only=true"
    echo "remoteproc_restart=false"
    echo "module_changes=false"
    echo "firmware_changes=false"
    case "$model" in
        *"ASUS Zenbook A14"*"UX3407RA"*) echo "target=UX3407RA" ;;
        *"ASUS Zenbook A14"*"UX3407QA"*) echo "target=UX3407QA" ;;
        *) echo "target=unrecognised" ;;
    esac
} >"$report/SUMMARY.txt"

{
    echo "=== uname ==="
    uname -a
    echo
    echo "=== model ==="
    printf '%s\n' "${model:-unknown}"
    echo
    echo "=== compatible ==="
    printf '%s\n' "${compatible:-unknown}"
    echo
    echo "=== os-release ==="
    cat /etc/os-release 2>/dev/null || true
    echo
    echo "=== command line ==="
    cat /proc/cmdline 2>/dev/null || true
} >"$report/system.txt"

config_tmp="$work/kernel-config"
if [ -r /proc/config.gz ] && command -v zcat >/dev/null 2>&1; then
    zcat /proc/config.gz >"$config_tmp" 2>/dev/null || true
elif [ -r "/boot/config-$(uname -r)" ]; then
    cp "/boot/config-$(uname -r)" "$config_tmp"
elif [ -r "/lib/modules/$(uname -r)/build/.config" ]; then
    cp "/lib/modules/$(uname -r)/build/.config" "$config_tmp"
else
    : >"$config_tmp"
fi

grep -E '^(CONFIG_(ARCH_QCOM|QCOM_Q6V5|QCOM_QMI|QCOM_RPROC|RPMSG|QRTR|VIDEO_QCOM_CAMSS|VIDEO_OV02C10|MEDIA_SUPPORT|MEDIA_CONTROLLER|V4L2_FWNODE|IIO|IIO_BUFFER|IIO_TRIGGER|HID_SENSOR|SENSORS|REGULATOR|PM|PM_SLEEP|DEBUG_FS|KALLSYMS))=' \
    "$config_tmp" >"$report/kernel-config.txt" 2>/dev/null || true

{
    echo "=== relevant loaded modules ==="
    lsmod 2>/dev/null | grep -Ei '(^Module|qcom|qrtr|rpmsg|remoteproc|camss|ov02c10|libcamera|iio|sensor)' || true
    echo
    echo "=== module metadata ==="
    for module in ov02c10 qcom_camss qcom_q6v5_adsp qcom_q6v5_pas qrtr ns qrtr_mhi rpmsg_char; do
        echo "--- $module ---"
        modinfo "$module" 2>&1 | sed -n '1,100p' || true
    done
} >"$report/modules.txt"

{
    echo "path,state,name,firmware,recovery,autoboot"
    for node in /sys/class/remoteproc/remoteproc*; do
        [ -d "$node" ] || continue
        state=$(cat "$node/state" 2>/dev/null || true)
        remote_name=$(cat "$node/name" 2>/dev/null || true)
        firmware=$(cat "$node/firmware" 2>/dev/null || true)
        recovery=$(cat "$node/recovery" 2>/dev/null || true)
        autoboot=$(cat "$node/autoboot" 2>/dev/null || true)
        printf '%s,%s,%s,%s,%s,%s\n' "$node" "$state" "$remote_name" "$firmware" "$recovery" "$autoboot"
    done
} >"$report/remoteproc.csv"

{
    echo "=== QRTR tools ==="
    if command -v qrtr-lookup >/dev/null 2>&1; then
        timeout 5 qrtr-lookup 2>&1 || true
    else
        echo "qrtr-lookup not installed"
    fi
    echo
    echo "=== QRTR sockets ==="
    if command -v ss >/dev/null 2>&1; then
        ss -a -A qrtr 2>&1 || true
    fi
    echo
    echo "=== RPMSG devices ==="
    find /sys/bus/rpmsg/devices -maxdepth 2 -type f -print 2>/dev/null | sort | while IFS= read -r path; do
        printf '%s=' "$path"
        tr '\000' ' ' <"$path" 2>/dev/null || true
        echo
    done
} >"$report/qrtr-rpmsg.txt"

python3 - "$report/device-tree.txt" <<'PY'
from __future__ import annotations
import os
import struct
import sys
from pathlib import Path

out = Path(sys.argv[1])
roots = [Path('/sys/firmware/devicetree/base'), Path('/proc/device-tree')]
root = next((p for p in roots if p.is_dir()), None)
keywords = (
    'camera', 'camss', 'cci', 'csiphy', 'csid', 'ov02c10', 'hm1092',
    'adsp', 'slpi', 'remoteproc', 'qrtr', 'rpmsg', 'sensor', 'aon', 'aoc',
)
props = {
    'compatible', 'status', 'reg', 'interrupts', 'interrupts-extended',
    'clock-names', 'clocks', 'firmware-name', 'memory-region', 'power-domains',
    'reset-gpios', 'data-lanes', 'link-frequencies', 'qcom,remote-pid',
    'qcom,glink-channels', 'qcom,smem-states', 'qcom,smem-state-names',
}

def strings(data: bytes) -> list[str] | None:
    if not data or any((b < 0x20 and b != 0) or b > 0x7e for b in data):
        return None
    vals = [v.decode('ascii', 'replace') for v in data.rstrip(b'\0').split(b'\0') if v]
    return vals or None

def decode(data: bytes) -> str:
    vals = strings(data)
    if vals is not None:
        return ' | '.join(vals)
    if len(data) % 4 == 0 and len(data) <= 128:
        cells = struct.unpack('>' + 'I' * (len(data) // 4), data)
        return ' '.join(f'0x{x:08x}' for x in cells)
    return data.hex()

if root is None:
    out.write_text('device tree filesystem not available\n')
    raise SystemExit

lines: list[str] = []
for current, _dirs, files in os.walk(root):
    path = Path(current)
    rel = '/' + str(path.relative_to(root)) if path != root else '/'
    compat = ''
    cp = path / 'compatible'
    if cp.is_file():
        try:
            compat = decode(cp.read_bytes())
        except OSError:
            pass
    haystack = (rel + ' ' + compat).lower()
    if not any(k in haystack for k in keywords):
        continue
    lines.append(f'[{rel}]')
    if compat:
        lines.append(f'compatible={compat}')
    for prop_name in sorted(files):
        if prop_name not in props and not prop_name.endswith('-supply'):
            continue
        prop_path = path / prop_name
        try:
            data = prop_path.read_bytes()
        except OSError as exc:
            lines.append(f'{prop_name}=<unreadable: {exc}>')
            continue
        lines.append(f'{prop_name}={decode(data)}')
    lines.append('')
out.write_text('\n'.join(lines) + ('\n' if lines else 'no matching nodes\n'))
PY

{
    echo "=== media devices ==="
    ls -l /dev/media* /dev/video* /dev/v4l-subdev* 2>&1 || true
    echo
    echo "=== media-ctl ==="
    if command -v media-ctl >/dev/null 2>&1; then
        for dev in /dev/media*; do
            [ -e "$dev" ] || continue
            echo "--- $dev ---"
            media-ctl -d "$dev" -p 2>&1 || true
        done
    else
        echo "media-ctl not installed"
    fi
    echo
    echo "=== v4l2 devices ==="
    if command -v v4l2-ctl >/dev/null 2>&1; then
        v4l2-ctl --list-devices 2>&1 || true
        for dev in /dev/v4l-subdev*; do
            [ -e "$dev" ] || continue
            echo "--- $dev ---"
            v4l2-ctl -d "$dev" --all 2>&1 | sed -n '1,160p' || true
        done
    else
        echo "v4l2-ctl not installed"
    fi
} >"$report/media.txt"

{
    echo "=== IIO devices ==="
    for node in /sys/bus/iio/devices/iio:device*; do
        [ -d "$node" ] || continue
        echo "[$node]"
        for attr in name label in_proximity_raw in_proximity_input in_distance_input sampling_frequency; do
            [ -r "$node/$attr" ] && printf '%s=%s\n' "$attr" "$(cat "$node/$attr" 2>/dev/null || true)"
        done
    done
    echo
    echo "=== input devices mentioning presence/proximity/camera ==="
    grep -Ei -B2 -A5 'presence|proximity|camera|sensor' /proc/bus/input/devices 2>/dev/null || true
} >"$report/sensor-interfaces.txt"

find /lib/firmware /usr/lib/firmware -xdev -type f \
    \( -ipath '*x1e80100*' -o -iname '*qcadsp*' -o -iname '*adsp*dtb*' \
       -o -iname '*qsh*' -o -iname '*ov02c10*' -o -iname '*hm1092*' \
       -o -iname '*camera*icp*' \) -print 2>/dev/null | sort -u | sed -n '1,400p' \
    >"$report/firmware-files.txt"

{
    while IFS= read -r path; do
        [ -f "$path" ] || continue
        size=$(wc -c <"$path" 2>/dev/null || echo 0)
        hash=$(sha256sum "$path" 2>/dev/null | awk '{print $1}')
        printf '%s,%s,%s\n' "$hash" "$size" "$path"
    done <"$report/firmware-files.txt"
} >"$report/firmware-hashes.csv"

{
    build="/lib/modules/$(uname -r)/build"
    echo "kernel_build=$build"
    [ -e "$build" ] && readlink -f "$build" || true
    for rel in \
        drivers/media/i2c/ov02c10.c \
        drivers/media/platform/qcom/camss \
        drivers/remoteproc/qcom_q6v5_adsp.c \
        drivers/soc/qcom/qmi_interface.c \
        include/linux/soc/qcom/qmi.h \
        arch/arm64/boot/dts/qcom/x1-asus-zenbook-a14.dtsi; do
        if [ -e "$build/$rel" ]; then
            printf 'present=%s\n' "$build/$rel"
        else
            printf 'missing=%s\n' "$build/$rel"
        fi
    done
} >"$report/kernel-source-layout.txt"

{
    dmesg --ctime 2>&1 | grep -Ei 'adsp|remoteproc|q6v5|qrtr|rpmsg|qmi|camss|camera|cci|csiphy|csid|ov02c10|hm1092|sensor|firmware' | tail -n 1600 || true
} >"$report/kernel-log.txt"

{
    echo "=== relevant symbols ==="
    if [ -r /proc/kallsyms ]; then
        grep -Ei ' (qmi_|qrtr_|qcom_q6v5|qcom_scm_pas|camss_|ov02c10|rpmsg_)' /proc/kallsyms | tail -n 2000 || true
    else
        echo "/proc/kallsyms is not readable"
    fi
} >"$report/kernel-symbols.txt"

cat >"$report/README.txt" <<'REPORT_README'
This archive is a read-only, targeted kernel bring-up report.

It intentionally excludes user files, browser data, memory dumps, complete
system logs, complete firmware trees, and unfiltered hardware inventory.

The collector does not load/unload modules, restart remote processors, write
camera or sensor registers, or install firmware.
REPORT_README

tar -C "$work" -czf "$archive" "$report_name"
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
    chown "$SUDO_UID:$SUDO_GID" "$archive" 2>/dev/null || true
fi
printf 'Created: %s\n' "$archive"
