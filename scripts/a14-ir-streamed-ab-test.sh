#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 2
fi

command -v cam >/dev/null 2>&1 || {
  echo "cam is required (libcamera-tools)." >&2
  exit 2
}

DIR=$(cd "$(dirname "$0")" && pwd)
LED=/sys/class/leds/ir:flash-0
[[ -e "$LED/flash_strobe" ]] || {
  echo "Missing $LED/flash_strobe" >&2
  exit 3
}

TMP=$(mktemp -d /tmp/a14-ir-streamed.XXXXXX)
CAM_LOG="$TMP/cam.log"
CAM_PID=

cleanup() {
  echo 0 >"$LED/brightness" 2>/dev/null || true
  echo 0 >"$LED/flash_strobe" 2>/dev/null || true
  if [[ -n "$CAM_PID" ]] && kill -0 "$CAM_PID" 2>/dev/null; then
    kill -INT "$CAM_PID" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$CAM_PID" 2>/dev/null || break
      sleep 0.1
    done
    kill -TERM "$CAM_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

CAM_LIST=$(cam -l 2>&1 || true)
printf '%s\n' "$CAM_LIST"
IR_INDEX=$(printf '%s\n' "$CAM_LIST" | awk '/camera@24/ { gsub(":", "", $1); print $1; exit }')
[[ -n "$IR_INDEX" ]] || {
  echo "Could not find HM1092 camera@24 in cam -l." >&2
  exit 3
}

echo
echo "===== START HM1092 STREAM ====="
echo "ir_camera_index=$IR_INDEX"
# Keep one real libcamera stream alive. No -F is used, so this does not dump
# hundreds of RAW frames to disk.
cam -c "$IR_INDEX" --capture=1800 >"$CAM_LOG" 2>&1 &
CAM_PID=$!
echo "cam_pid=$CAM_PID"

STREAM_READY=0
for _ in $(seq 1 50); do
  if ! kill -0 "$CAM_PID" 2>/dev/null; then
    break
  fi
  if grep -qE 'seq:[[:space:]]*[0-9]+|Capture [0-9]+ frames|configuring streams' "$CAM_LOG"; then
    STREAM_READY=1
    break
  fi
  sleep 0.1
done

if ! kill -0 "$CAM_PID" 2>/dev/null; then
  echo "HM1092 stream exited before the IR test." >&2
  tail -80 "$CAM_LOG" >&2 || true
  exit 4
fi

if [[ $STREAM_READY -eq 1 ]]; then
  echo "HM1092_STREAM=READY"
else
  echo "HM1092_STREAM=ALIVE_READINESS_NOT_CONFIRMED"
fi

if command -v fuser >/dev/null 2>&1; then
  echo "flash_subdev_holders:"
  fuser -v /dev/v4l-subdev27 2>&1 || true
fi

echo
echo "===== RUN THE SAME OPTICAL A/B/C CONTROLS WITH HM1092 ACTIVE ====="
echo "This is the missing condition from the previous standalone test."
echo "Use a camera to observe the emitter; do not look directly into it."

# The existing test restores all LED/V4L2 controls after each run. Running it
# here while the HM1092 stream is alive tells us whether camera pipeline power /
# media ownership is the prerequisite that the Manual Camera app satisfies.
bash "$DIR/a14-ir-output-ab-test.sh" all || {
  rc=$?
  echo "A14_IR_STREAMED_INNER_TEST_RC=$rc"
  echo "The inner V4L2 test may be rejected if libcamera owns the flash subdevice."
}

echo
echo "===== HM1092 STREAM STILL ALIVE? ====="
if kill -0 "$CAM_PID" 2>/dev/null; then
  echo "HM1092_STREAM_AFTER_TEST=ALIVE"
else
  echo "HM1092_STREAM_AFTER_TEST=EXITED"
fi

echo
echo "===== CAM LOG TAIL ====="
tail -80 "$CAM_LOG" || true

echo
echo "A14_IR_STREAMED_AB_TEST=COMPLETE"
echo "Report which sections A/B/C were physically visible while this stream was active."
