#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo"

svc=a14-ssc-hexagonrpcd.service
cfg=/var/lib/a14-ssc/runtime/sensors/config

printf '%s\n' '[preflight] SSC/QSH reverse-filesystem environment'
if systemctl is-active --quiet "$svc" 2>/dev/null; then
    echo "[rfs] $svc: active"
else
    echo "[rfs] WARNING: $svc is not active"
    systemctl status "$svc" --no-pager -l 2>/dev/null | sed -n '1,14p' || true
fi

if [ -e /dev/fastrpc-adsp ]; then
    ls -l /dev/fastrpc-adsp
else
    echo '[rfs] WARNING: /dev/fastrpc-adsp is missing'
fi

check_hash() {
    file=$1
    expected=$2
    path="$cfg/$file"
    if [ ! -f "$path" ]; then
        echo "[rfs] WARNING: missing $path"
        return
    fi
    actual=$(sha256sum "$path" | awk '{print $1}')
    if [ "$actual" = "$expected" ]; then
        echo "[rfs] $file: exact known hash $actual"
    else
        echo "[rfs] WARNING: $file hash mismatch"
        echo "      expected=$expected"
        echo "      actual=$actual"
    fi
}

check_hash ov02c10_2.pb aab68860361e258ad70e68b53430910c2201b239849c3ac76304a175fcecb994
check_hash qsh_camera_ov02c10_2.json 0321ac0c0b0aef5ce3269ffded770114b73e75966dd13680029beff7e6ff2d9e
check_hash qsh_camera.json eb55def2d4f2cdf5af37112bada641bc2888b110b22b967e32d87410f7a3f847

echo '[build] building Windows-ABI-correct SSC HPD module'
make -C kernel/aos

echo '[module] establishing a fresh SSC client and waiting for SUID discovery'
sudo rmmod qcom_ssc_hpd 2>/dev/null || true
sudo insmod kernel/aos/qcom_ssc_hpd.ko
# The IIO device is registered before the asynchronous QRTR/QMI discovery work
# completes. Give that work time to connect and discover all required SUIDs so
# the event-enable write tests INIT 576 rather than merely returning -EAGAIN.
sleep 2

sudo python3 tools/a14-presence-test.py --no-build --no-reload --unload "$@"
