#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo"

quiesce_media=0
pass_args=''
for arg in "$@"; do
    case "$arg" in
        --quiesce-media) quiesce_media=1 ;;
        *)
            # Remaining arguments are currently simple tester flags/values.
            # Preserve them for the Python test after our own option handling.
            pass_args="$pass_args $(printf '%s' "$arg" | sed "s/'/'\\''/g")"
            ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo '[privilege] Re-running AP-camera release A/B with sudo...'
    exec sudo env A14_TEST_USER="$(id -un)" A14_TEST_UID="$(id -u)" -- "$0" "$@"
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
media_quiesced=0
media_restore_units=''

user_systemctl() {
    uid=${A14_TEST_UID:-}
    user=${A14_TEST_USER:-}
    [ -n "$uid" ] && [ -n "$user" ] || return 1
    env XDG_RUNTIME_DIR="/run/user/$uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        runuser -u "$user" -- systemctl --user "$@"
}

restore_media() {
    [ "$media_quiesced" -eq 1 ] || return 0
    echo '[cleanup] restoring user PipeWire/WirePlumber units'
    for unit in $media_restore_units; do
        user_systemctl start "$unit" >/dev/null 2>&1 || true
    done
    media_quiesced=0
}

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
    restore_media
    exit "$rc"
}
trap cleanup EXIT INT TERM HUP

echo '[A/B] This test does NOT touch CPAS/AON mux MMIO.'
echo '[A/B] It temporarily unbinds only the Linux OV02C10 sensor driver,'
echo '      retries the corrected SSC handshake, then always rebinds the sensor.'
echo "[sensor] bound OV02C10=$sensor"

if [ "$quiesce_media" -eq 1 ]; then
    [ -n "${A14_TEST_UID:-}" ] && [ -n "${A14_TEST_USER:-}" ] || {
        echo 'FAIL: --quiesce-media must be launched as the normal desktop user (not directly as root).' >&2
        exit 2
    }
    command -v runuser >/dev/null 2>&1 || {
        echo 'FAIL: runuser is required for --quiesce-media' >&2
        exit 2
    }

    echo "[media] temporarily quiescing PipeWire/WirePlumber for ${A14_TEST_USER}"
    for unit in wireplumber.service pipewire-pulse.service pipewire.service pipewire-pulse.socket pipewire.socket; do
        if user_systemctl is-active --quiet "$unit" 2>/dev/null; then
            media_restore_units="$media_restore_units $unit"
        fi
    done

    # Stop services first, then their activation sockets, so they cannot respawn
    # while the camera sensor is handed to SSC. Units absent on a given desktop
    # are harmlessly ignored.
    for unit in wireplumber.service pipewire-pulse.service pipewire.service; do
        user_systemctl stop "$unit" >/dev/null 2>&1 || true
    done
    for unit in pipewire-pulse.socket pipewire.socket; do
        user_systemctl stop "$unit" >/dev/null 2>&1 || true
    done
    media_quiesced=1
    sleep 1
fi

# Refuse if a normal camera/media node is still open. This is intentionally
# broad: disrupting an active camera or face-auth session is worse than
# skipping the test.
if command -v fuser >/dev/null 2>&1; then
    busy=$(fuser /dev/video* /dev/media* 2>/dev/null || true)
    if [ -n "$busy" ]; then
        echo "FAIL: camera/media nodes are in use by PID(s): $busy" >&2
        if [ "$quiesce_media" -eq 1 ]; then
            echo 'PipeWire/WirePlumber were quiesced, so another camera holder remains.' >&2
        else
            echo 'Close camera/face-auth applications or rerun with --quiesce-media.' >&2
        fi
        echo 'Processes:'
        pids=$(printf '%s\n' "$busy" | xargs 2>/dev/null | tr ' ' ',')
        [ -z "$pids" ] || ps -o pid,user,comm,args -p "$pids" 2>/dev/null || true
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
# shellcheck disable=SC2086
sh -c "exec ./tools/a14-presence-test-v2.sh --duration 15 $pass_args"
