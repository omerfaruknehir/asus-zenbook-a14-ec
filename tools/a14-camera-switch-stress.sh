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

systemctl --user stop wireplumber pipewire 2>/dev/null || true
sleep 1

cleanup() {
    systemctl --user start pipewire wireplumber 2>/dev/null || true
}
trap cleanup EXIT

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
