#!/usr/bin/env bash
set -u

ITERATIONS="${1:-40}"
FRAMES="${2:-3}"
OPEN_TIMEOUT="${3:-5}"
OUT="${OUT:-/tmp/a14-camera-switch-stress-$(date +%Y%m%d-%H%M%S).log}"
START="$(date --iso-8601=seconds)"

exec > >(tee "$OUT") 2>&1

echo '===== A14 CAMERA SWITCH STRESS ====='
date -Ins
uname -r
printf 'iterations=%s frames_per_open=%s open_timeout=%ss\n' \
    "$ITERATIONS" "$FRAMES" "$OPEN_TIMEOUT"

cleanup() {
    echo '[cleanup] restoring PipeWire/WirePlumber'
    timeout 5s systemctl --user unmask --runtime pipewire.service pipewire.socket >/dev/null 2>&1 || true
    timeout 8s systemctl --user start pipewire.socket pipewire.service wireplumber.service >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo '[preflight] closing Snapshot'
pkill -x snapshot 2>/dev/null || true
pkill -f 'org\.gnome\.Snapshot' 2>/dev/null || true

echo '[preflight] stopping WirePlumber'
timeout 5s systemctl --user stop wireplumber.service >/dev/null 2>&1 || true

echo '[preflight] stopping PipeWire service/socket'
timeout 5s systemctl --user stop pipewire.service pipewire.socket >/dev/null 2>&1 || true

echo '[preflight] masking PipeWire service/socket'
timeout 5s systemctl --user mask --runtime pipewire.service pipewire.socket >/dev/null 2>&1 || true

echo '[preflight] stopping PipeWire again after mask'
timeout 5s systemctl --user stop pipewire.service pipewire.socket >/dev/null 2>&1 || true

# A service stop job can outlive a timed-out systemctl client. Ensure no
# userspace camera broker remains before direct libcamera testing.
echo '[preflight] terminating lingering camera brokers'
pkill -TERM -x wireplumber 2>/dev/null || true
pkill -TERM -x pipewire 2>/dev/null || true
for _ in {1..20}; do
    if ! pgrep -x wireplumber >/dev/null 2>&1 && ! pgrep -x pipewire >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done
pgrep -x wireplumber >/dev/null 2>&1 && pkill -KILL -x wireplumber 2>/dev/null || true
pgrep -x pipewire >/dev/null 2>&1 && pkill -KILL -x pipewire 2>/dev/null || true
sleep 0.2

camera_holders() {
    local nodes=()
    shopt -s nullglob
    nodes+=(/dev/video* /dev/v4l-subdev* /dev/media*)
    shopt -u nullglob
    ((${#nodes[@]})) || return 0
    timeout 5s fuser -v "${nodes[@]}" 2>&1 || true
}

echo '[preflight] checking camera holders'
HOLDERS="$(camera_holders)"
if grep -Eq '[[:space:]][0-9]+[[:space:]]' <<<"$HOLDERS"; then
    echo '===== ERROR: CAMERA PIPELINE STILL IN USE ====='
    printf '%s\n' "$HOLDERS"
    echo
    echo '===== PIPEWIRE UNIT/PROCESS STATE ====='
    timeout 5s systemctl --user --no-pager --full status pipewire.service pipewire.socket wireplumber.service 2>&1 | tail -100 || true
    ps -eo pid,ppid,state,comm,args | grep -E '[p]ipewire|[w]ireplumber|[s]napshot' || true
    echo 'No stress iterations were started.'
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

        timeout --signal=INT --kill-after=2s "${OPEN_TIMEOUT}s" \
            cam -c "$idx" --capture="$FRAMES" >"$log" 2>&1
        rc=$?

        if ((rc == 124)); then
            echo "TIMEOUT=${OPEN_TIMEOUT}s"
            echo "===== FIRST FAILURE: iteration=$i camera=$name frame-wait-timeout ====="
            tail -100 "$log"
            FAIL=124
            break 2
        fi

        echo "RC=$rc"
        if ((rc != 0)); then
            echo "===== FIRST FAILURE: iteration=$i camera=$name rc=$rc ====="
            tail -100 "$log"
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
    grep -Ei 'camss|csid|csiphy|vfe|cci|hm1092|ov02c10|stream|timeout|error|call_s_stream|WARNING' |
    tail -400 || true

echo
echo "STRESS_RC=$FAIL"
echo "FULL_LOG=$OUT"
exit "$FAIL"
