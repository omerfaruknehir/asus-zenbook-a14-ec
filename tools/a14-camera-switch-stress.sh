#!/usr/bin/env bash
set -u

ITERATIONS="${1:-40}"
FRAMES="${2:-3}"
OUT="${OUT:-/tmp/a14-camera-switch-stress-$(date +%Y%m%d-%H%M%S).log}"
START="$(date --iso-8601=seconds)"

exec > >(tee "$OUT") 2>&1

echo '===== A14 CAMERA SWITCH STRESS ====='
date -Ins
uname -r
printf 'iterations=%s frames_per_open=%s\n' "$ITERATIONS" "$FRAMES"

# Snapshot itself can keep a libcamera pipeline acquired even after PipeWire is
# stopped. Close it so this test measures CAMSS/libcamera teardown/startup only.
pkill -x snapshot 2>/dev/null || true

# Stop both services and the PipeWire socket to prevent socket activation while
# the direct libcamera stress test is running.
systemctl --user stop wireplumber.service pipewire.service pipewire.socket 2>/dev/null || true
sleep 1

cleanup() {
    systemctl --user start pipewire.socket pipewire.service wireplumber.service 2>/dev/null || true
}
trap cleanup EXIT

camera_holders() {
    local nodes=()
    shopt -s nullglob
    nodes+=(/dev/video* /dev/v4l-subdev* /dev/media*)
    shopt -u nullglob
    ((${#nodes[@]})) || return 0
    fuser -v "${nodes[@]}" 2>&1 || true
}

HOLDERS="$(camera_holders)"
if grep -Eq '[[:space:]][0-9]+[[:space:]]' <<<"$HOLDERS"; then
    echo '===== ERROR: CAMERA PIPELINE STILL IN USE ====='
    printf '%s\n' "$HOLDERS"
    echo 'Close the listed process(es) and rerun. No stress iterations were started.'
    exit 3
fi

echo '===== EXCLUSIVE CAMERA ACCESS CONFIRMED ====='

CAMLIST="$(cam -l 2>&1)"
printf '%s\n' "$CAMLIST"

RGB="$(printf '%s\n' "$CAMLIST" | awk '/^[[:space:]]*[0-9]+: .*camera@36/ {gsub(":", "", $1); print $1; exit}')"
IR="$(printf '%s\n' "$CAMLIST" | awk '/^[[:space:]]*[0-9]+: .*camera@24/ {gsub(":", "", $1); print $1; exit}')"

echo "RGB_INDEX=${RGB:-NOT_FOUND}"
echo "IR_INDEX=${IR:-NOT_FOUND}"

if [[ -z "$RGB" || -z "$IR" ]]; then
    echo 'ERROR: both cameras must enumerate before the test.'
    exit 2
fi

FAIL=0
for ((i=1; i<=ITERATIONS; i++)); do
    for pair in "RGB:$RGB" "IR:$IR"; do
        name="${pair%%:*}"
        idx="${pair##*:}"
        log="/tmp/a14-switch-${name,,}-${i}.log"
        printf 'ITER=%02d CAMERA=%s INDEX=%s ... ' "$i" "$name" "$idx"
        cam -c "$idx" --capture="$FRAMES" >"$log" 2>&1
        rc=$?
        echo "RC=$rc"
        if ((rc != 0)); then
            echo "===== FIRST FAILURE: iteration=$i camera=$name rc=$rc ====="
            tail -80 "$log"
            FAIL=$rc
            break 2
        fi
    done
done

echo
echo '===== POST-STRESS ENUMERATION ====='
cam -l 2>&1 | tail -60 || true

echo
echo '===== VIDEO MODES ====='
for f in /dev/video* /dev/media*; do
    [[ -e "$f" ]] || continue
    stat -c '%A %a %U:%G %n' "$f"
done

echo
echo '===== KERNEL CAMERA EVENTS ====='
journalctl -k --since "$START" --no-pager |
    grep -Ei 'camss|csid|csiphy|vfe|cci|hm1092|ov02c10|stream|timeout|error' |
    tail -300 || true

echo
echo "STRESS_RC=$FAIL"
echo "FULL_LOG=$OUT"
exit "$FAIL"
