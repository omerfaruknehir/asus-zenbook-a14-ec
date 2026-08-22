#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo"

if [ "$(id -u)" -ne 0 ]; then
    echo '[privilege] Re-running AP-camera release A/B with sudo...'
    exec sudo -- "$0" "$@"
fi

DRV=/sys/bus/i2c/drivers/ov02c10
if [ ! -d "$DRV" ]; then
    echo "FAIL: OV02C10 I2C driver is not present at $DRV" >&2
    exit 2
fi

sensor=''
for p in "$DRV"/*-*; do
    [ -L "$p" ] || continue
    id=$(basename "$p")
    case "$id" in
        *-0036)
            if [ -n "$sensor" ]; then
                echo "FAIL: more than one bound OV02C10 device found ($sensor, $id); refusing ambiguous unbind" >&2
                exit 2
            fi
            sensor=$id
            ;;
    esac
done

if [ -z "$sensor" ]; then
    echo 'FAIL: no bound OV02C10 *-0036 device found' >&2
    exit 2
fi

unbound=0
cleanup() {
    rc=$?
    trap - EXIT INT TERM HUP
    if [ "$unbound" -eq 1 ]; then
        echo "[cleanup] rebinding OV02C10 $sensor to Linux"
        if printf '%s\n' "$sensor" > "$DRV/bind"; then
            unbound=0
            echo "[cleanup] rebound $sensor"
        else
            echo "[cleanup] ERROR: failed to rebind $sensor; run: echo $sensor | sudo tee $DRV/bind" >&2
        fi
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM HUP

echo '[A/B] This test does NOT touch CPAS/AON mux MMIO.'
echo '[A/B] It temporarily unbinds only the Linux OV02C10 sensor driver,'
echo '      retries the corrected SSC handshake, then always rebinds the sensor.'
echo "[sensor] bound OV02C10=$sensor"

# Refuse if a normal camera/media node is currently open. This is intentionally
# broad: disrupting an active camera or face-auth session is worse than
# skipping the test.
if command -v fuser >/dev/null 2>&1; then
    busy=$(fuser /dev/video* /dev/media* 2>/dev/null || true)
    if [ -n "$busy" ]; then
        echo "FAIL: camera/media nodes are in use by PID(s): $busy" >&2
        echo 'Close camera/face-auth applications and rerun.' >&2
        echo 'Processes:'
        pids=$(printf '%s\n' "$busy" | xargs 2>/dev/null | tr ' ' ',')
        [ -z "$pids" ] || ps -o pid,comm,args -p "$pids" 2>/dev/null || true
        exit 2
    fi
fi

echo "[sensor] unbinding $sensor"
printf '%s\n' "$sensor" > "$DRV/unbind"
unbound=1
sleep 1

if [ -e "/sys/bus/i2c/devices/$sensor/driver" ]; then
    echo 'FAIL: OV02C10 still has a driver after unbind' >&2
    exit 2
fi

echo '[sensor] Linux OV02C10 driver released; testing SSC presence handshake'
# Use the v2 tester so QSH/RFS hashes, corrected QMI framing, module lifecycle,
# and IIO monitoring are identical to the preceding hardware test.
./tools/a14-presence-test-v2.sh --duration 15 "$@"
