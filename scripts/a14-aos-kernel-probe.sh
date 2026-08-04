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

cleanup() { rm -rf "$work"; }
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
    echo "=== uname ==="; uname -a
    echo; echo "=== version signature ==="; cat /proc/version_signature 2>/dev/null || true
    echo; echo "=== model ==="; printf '%s\n' "${model:-unknown}"
    echo; echo "=== compatible ==="; printf '%s\n' "${compatible:-unknown}"
    echo; echo "=== os-release ==="; cat /etc/os-release 2>/dev/null || true
    echo; echo "=== command line ==="; cat /proc/cmdline 2>/dev/null || true
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
    lsmod 2>/dev/null | grep -Ei '(^Module|qcom|qrtr|rpmsg|remoteproc|camss|ov02c10|iio|sensor)' || true
    echo
    echo "=== module metadata ==="
    for module in ov02c10 qcom_camss qcom_q6v5_adsp qcom_q6v5_pas qmi_helpers qrtr qrtr_smd rpmsg_char; do
        echo "--- $module ---"
        modinfo "$module" 2>&1 | sed -n '1,120p' || true
    done
} >"$report/modules.txt"

{
    echo "path,state,name,firmware,recovery,autoboot"
    for node in /sys/class/remoteproc/remoteproc*; do
        [ -d "$node" ] || continue
        printf '%s,%s,%s,%s,%s,%s\n' \
            "$node" \
            "$(cat "$node/state" 2>/dev/null || true)" \
            "$(cat "$node/name" 2>/dev/null || true)" \
            "$(cat "$node/firmware" 2>/dev/null || true)" \
            "$(cat "$node/recovery" 2>/dev/null || true)" \
            "$(cat "$node/autoboot" 2>/dev/null || true)"
    done
} >"$report/remoteproc.csv"

{
    echo "=== QRTR service lookup ==="
    if command -v qrtr-lookup >/dev/null 2>&1; then
        timeout 5 qrtr-lookup 2>&1 || true
    else
        echo "qrtr-lookup not installed"
    fi
    echo
    echo "=== SSC service 400 ==="
    if command -v qrtr-lookup >/dev/null 2>&1; then
        timeout 5 qrtr-lookup 2>&1 | grep -Ei '(^|[[:space:]])400([[:space:]]|$)|sensor core|ssc' || true
    fi
    echo
    echo "=== /proc/net/qrtr ==="
    cat /proc/net/qrtr 2>/dev/null || echo "not available"
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
import os, struct, sys
from pathlib import Path

out = Path(sys.argv[1])
root = next((p for p in (Path('/sys/firmware/devicetree/base'), Path('/proc/device-tree')) if p.is_dir()), None)
keywords = ('camera', 'camss', 'cci', 'csiphy', 'csid', 'ov02c10', 'hm1092', 'adsp', 'slpi', 'remoteproc', 'qrtr', 'rpmsg', 'sensor', 'aon', 'aoc')
props = {
    'compatible', 'status', 'reg', 'interrupts', 'interrupts-extended',
    'clock-names', 'clocks', 'firmware-name', 'memory-region', 'power-domains',
    'reset-gpios', 'data-lanes', 'link-frequencies', 'qcom,remote-pid',
    'qcom,glink-channels', 'qcom,smem-states', 'qcom,smem-state-names',
}
string_props = {
    'compatible', 'status', 'model', 'clock-names', 'firmware-name',
    'qcom,glink-channels', 'qcom,smem-state-names', 'label', 'name',
}

def decode_strings(data: bytes) -> str:
    values = [v.decode('ascii', 'replace') for v in data.rstrip(b'\0').split(b'\0') if v]
    return ' | '.join(values)

def decode(prop: str, data: bytes) -> str:
    if prop in string_props or prop.endswith('-names'):
        return decode_strings(data)
    if len(data) % 8 == 0 and prop == 'link-frequencies':
        vals = struct.unpack('>' + 'Q' * (len(data) // 8), data)
        return ' '.join(f'0x{x:016x}' for x in vals)
    if len(data) % 4 == 0 and len(data) <= 256:
        vals = struct.unpack('>' + 'I' * (len(data) // 4), data)
        return ' '.join(f'0x{x:08x}' for x in vals)
    return data.hex()

if root is None:
    out.write_text('device tree filesystem not available\n')
    raise SystemExit

lines: list[str] = []
for current, _dirs, files in os.walk(root):
    path = Path(current)
    rel = '/' if path == root else '/' + str(path.relative_to(root))
    compat = ''
    try:
        compat = decode_strings((path / 'compatible').read_bytes())
    except OSError:
        pass
    if not any(k in (rel + ' ' + compat).lower() for k in keywords):
        continue
    lines.append(f'[{rel}]')
    if compat:
        lines.append(f'compatible={compat}')
    for prop in sorted(files):
        if prop not in props and not prop.endswith('-supply'):
            continue
        try:
            data = (path / prop).read_bytes()
            lines.append(f'{prop}={decode(prop, data)}')
        except OSError as exc:
            lines.append(f'{prop}=<unreadable: {exc}>')
    lines.append('')
out.write_text('\n'.join(lines) + ('\n' if lines else 'no matching nodes\n'))
PY

{
    echo "=== media devices ==="
    ls -l /dev/media* /dev/video* /dev/v4l-subdev* 2>&1 || true
    echo; echo "=== media-ctl ==="
    if command -v media-ctl >/dev/null 2>&1; then
        for dev in /dev/media*; do [ -e "$dev" ] && { echo "--- $dev ---"; media-ctl -d "$dev" -p 2>&1 || true; }; done
    else
        echo "media-ctl not installed"
    fi
    echo; echo "=== v4l2 devices ==="
    if command -v v4l2-ctl >/dev/null 2>&1; then
        v4l2-ctl --list-devices 2>&1 || true
        for dev in /dev/v4l-subdev*; do [ -e "$dev" ] && { echo "--- $dev ---"; v4l2-ctl -d "$dev" --all 2>&1 | sed -n '1,180p' || true; }; done
    else
        echo "v4l2-ctl not installed"
    fi
} >"$report/media.txt"

{
    echo "=== IIO devices ==="
    for node in /sys/bus/iio/devices/iio:device*; do
        [ -d "$node" ] || continue
        echo "[$node]"
        find "$node" -maxdepth 2 -type f \( -name 'name' -o -name 'label' -o -name 'in_proximity*' -o -name 'in_distance*' -o -path '*/events/*' \) -print 2>/dev/null | sort | while IFS= read -r attr; do
            printf '%s=%s\n' "$attr" "$(cat "$attr" 2>/dev/null || true)"
        done
    done
    echo; echo "=== input devices mentioning presence/proximity/camera ==="
    grep -Ei -B2 -A5 'presence|proximity|camera|sensor' /proc/bus/input/devices 2>/dev/null || true
} >"$report/sensor-interfaces.txt"

{
    for base in /lib/firmware /usr/lib/firmware; do
        [ -d "$base" ] || continue
        find "$base/qcom/x1e80100/ASUSTeK/zenbook-a14" -maxdepth 2 -type f -print 2>/dev/null || true
        find "$base" -xdev -type f \( -iname 'qsh_camera*.json' -o -iname 'ov02c10_2.pb' \
            -o -iname 'com.qti.sensormodule.ov02c10.bin' -o -iname 'com.qti.tuned.ov02c10*.bin' \
            -o -iname 'com.qti.sensormodule.hm1092.bin' -o -iname 'com.qti.tuned.hm1092*.bin' \) \
            -print 2>/dev/null || true
    done
} | sort -u | sed -n '1,300p' >"$report/firmware-files.txt"

while IFS= read -r path; do
    [ -f "$path" ] || continue
    printf '%s,%s,%s\n' "$(sha256sum "$path" | awk '{print $1}')" "$(wc -c <"$path")" "$path"
done <"$report/firmware-files.txt" >"$report/firmware-hashes.csv"

{
    kernel=$(uname -r)
    build="/lib/modules/$kernel/build"
    source="/lib/modules/$kernel/source"
    echo "kernel=$kernel"
    echo "kernel_build=$build"
    [ -e "$build" ] && readlink -f "$build" || true
    echo "kernel_source=$source"
    [ -e "$source" ] && readlink -f "$source" || true
    echo "kheaders_archive=$([ -r /sys/kernel/kheaders.tar.xz ] && echo present || echo absent)"
    echo
    echo "=== installed kernel packages ==="
    if command -v dpkg-query >/dev/null 2>&1; then
        dpkg-query -W -f='${binary:Package}\t${Version}\t${Status}\n' 2>/dev/null | grep -E '^(linux-(image|modules|headers|source|tools)|ubuntu-x1e|hwe-qcom)' | sort || true
    fi
    echo
    echo "=== source files in build tree ==="
    for rel in drivers/media/i2c/ov02c10.c drivers/media/platform/qcom/camss \
        drivers/remoteproc/qcom_q6v5_adsp.c drivers/soc/qcom/qmi_interface.c \
        include/linux/soc/qcom/qmi.h arch/arm64/boot/dts/qcom/x1-asus-zenbook-a14.dtsi; do
        [ -e "$build/$rel" ] && echo "present=$build/$rel" || echo "missing=$build/$rel"
    done
    echo
    echo "=== active A14 DTBs ==="
    find /boot /usr/lib/firmware /lib/firmware -type f \( -name '*asus-zenbook-a14*.dtb' -o -name '*asus-zenbook-a14*.dtbo' \) -print 2>/dev/null | sort -u | while IFS= read -r dtb; do
        printf '%s  %s\n' "$(sha256sum "$dtb" | awk '{print $1}')" "$dtb"
    done
} >"$report/kernel-source-provenance.txt"

{
    dmesg --ctime 2>&1 | grep -Ei 'adsp|cdsp|remoteproc|q6v5|qrtr|rpmsg|qmi|camss|camera|cci|csiphy|csid|ov02c10|hm1092|sensor|firmware' | tail -n 1800 || true
} >"$report/kernel-log.txt"

{
    echo "=== relevant symbols ==="
    if [ -r /proc/kallsyms ]; then
        grep -Ei ' (qmi_|qrtr_|qcom_q6v5|qcom_scm_pas|camss_|ov02c10|rpmsg_)' /proc/kallsyms | tail -n 2200 || true
    else
        echo "/proc/kallsyms is not readable"
    fi
} >"$report/kernel-symbols.txt"

cat >"$report/README.txt" <<'REPORT_README'
This archive is a read-only, targeted kernel bring-up report.
It excludes user files, memory dumps, complete system logs, and unfiltered
firmware trees. The collector does not load modules, restart remote processors,
write camera/sensor registers, or install firmware.
REPORT_README

tar -C "$work" -czf "$archive" "$report_name"
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
    chown "$SUDO_UID:$SUDO_GID" "$archive" 2>/dev/null || true
fi
printf 'Created: %s\n' "$archive"
