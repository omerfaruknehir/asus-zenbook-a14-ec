#!/usr/bin/env bash
set -euo pipefail

mode=${1:-all}
case "$mode" in
  all|flash|led-torch|v4l2-torch) ;;
  *) echo "usage: sudo $0 [all|flash|led-torch|v4l2-torch]" >&2; exit 2 ;;
esac

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run this test as root: sudo bash $0 $mode" >&2
  exit 2
fi

LED=/sys/class/leds/ir:flash-0
if [[ ! -e "$LED/flash_strobe" ]]; then
  LED=
  for candidate in /sys/class/leds/*; do
    [[ -e "$candidate/flash_strobe" ]] || continue
    LED=$candidate
    break
  done
fi
[[ -n "$LED" && -e "$LED/flash_strobe" ]] || {
  echo "No LED-class flash device found." >&2
  exit 3
}

FLASH=
if command -v v4l2-ctl >/dev/null 2>&1; then
  for dev in /dev/v4l-subdev*; do
    [[ -e "$dev" ]] || continue
    controls=$(v4l2-ctl -d "$dev" --list-ctrls-menus 2>/dev/null || true)
    if grep -q 'led_mode' <<<"$controls" && grep -q 'intensity_torch_mode' <<<"$controls"; then
      FLASH=$dev
      break
    fi
  done
fi

original_flash_brightness=$(cat "$LED/flash_brightness" 2>/dev/null || true)
original_flash_timeout=$(cat "$LED/flash_timeout" 2>/dev/null || true)

cleanup() {
  echo 0 >"$LED/brightness" 2>/dev/null || true
  echo 0 >"$LED/flash_strobe" 2>/dev/null || true
  if [[ -n "$FLASH" ]]; then
    v4l2-ctl -d "$FLASH" --set-ctrl=led_mode=0 >/dev/null 2>&1 || true
  fi
  [[ -n "$original_flash_brightness" ]] && echo "$original_flash_brightness" >"$LED/flash_brightness" 2>/dev/null || true
  [[ -n "$original_flash_timeout" ]] && echo "$original_flash_timeout" >"$LED/flash_timeout" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

read_field() {
  local field=$1
  if [[ -r "$LED/$field" ]]; then
    printf '%-24s %s\n' "$field" "$(cat "$LED/$field" 2>/dev/null || true)"
  fi
}

show_state() {
  echo "LED=$LED"
  echo "V4L2_FLASH=${FLASH:-not-found}"
  for field in brightness max_brightness flash_brightness max_flash_brightness flash_timeout max_flash_timeout flash_strobe flash_fault; do
    read_field "$field"
  done
  if [[ -n "$FLASH" ]]; then
    v4l2-ctl -d "$FLASH" --get-ctrl=led_mode,intensity_torch_mode,faults 2>/dev/null || true
  fi
}

countdown() {
  local label=$1
  echo
  echo "=== $label ==="
  echo "Aim a camera at the IR emitter. Do NOT look directly into the emitter."
  echo "Starting in 3 seconds..."
  sleep 3
}

flash_test() {
  countdown "A: LED-CLASS SOFTWARE FLASH — positive control"
  # Conservative, previously useful pulse shape: 100 mA, 50 ms, five pulses.
  echo 0 >"$LED/brightness"
  echo 0 >"$LED/flash_strobe"
  echo 100000 >"$LED/flash_brightness"
  echo 50000 >"$LED/flash_timeout"
  echo "flash_current_uA=$(cat "$LED/flash_brightness") timeout_us=$(cat "$LED/flash_timeout")"
  for n in 1 2 3 4 5; do
    echo "FLASH_PULSE=$n/5"
    echo 1 >"$LED/flash_strobe"
    sleep 0.30
  done
  sleep 0.20
  echo "FLASH_CONTROL_PATH=COMMANDS_ACCEPTED"
  read_field flash_fault
}

led_torch_test() {
  countdown "B: DIRECT LED-CLASS TORCH"
  local max level
  max=$(cat "$LED/max_brightness")
  # qcom-flash exposes 0..255. About 20% corresponds to roughly 100 mA
  # when led-max-microamp is 500 mA.
  level=$(( (max * 20 + 50) / 100 ))
  (( level < 1 )) && level=1
  echo 0 >"$LED/flash_strobe"
  echo "$level" >"$LED/brightness"
  echo "requested_brightness=$level readback_brightness=$(cat "$LED/brightness") max_brightness=$max"
  sleep 3
  echo "readback_after_3s=$(cat "$LED/brightness")"
  echo 0 >"$LED/brightness"
  echo "LED_TORCH_CONTROL_PATH=COMMAND_ACCEPTED_NO_OPTICAL_VERIFICATION"
  read_field flash_fault
}

v4l2_torch_test() {
  countdown "C: V4L2 TORCH"
  [[ -n "$FLASH" ]] || {
    echo "V4L2_TORCH_CONTROL_PATH=SKIPPED_NO_FLASH_SUBDEV"
    return
  }
  v4l2-ctl -d "$FLASH" --set-ctrl=led_mode=0
  v4l2-ctl -d "$FLASH" --set-ctrl=intensity_torch_mode=100000
  v4l2-ctl -d "$FLASH" --set-ctrl=led_mode=2
  echo "V4L2 readback immediately:"
  v4l2-ctl -d "$FLASH" --get-ctrl=led_mode,intensity_torch_mode,faults || true
  sleep 3
  echo "V4L2 readback after 3s:"
  v4l2-ctl -d "$FLASH" --get-ctrl=led_mode,intensity_torch_mode,faults || true
  v4l2-ctl -d "$FLASH" --set-ctrl=led_mode=0
  echo "V4L2_TORCH_CONTROL_PATH=COMMAND_ACCEPTED_NO_OPTICAL_VERIFICATION"
}

echo "===== A14 IR OUTPUT A/B TEST ====="
echo "kernel=$(uname -r)"
show_state

case "$mode" in
  flash) flash_test ;;
  led-torch) led_torch_test ;;
  v4l2-torch) v4l2_torch_test ;;
  all)
    flash_test
    led_torch_test
    v4l2_torch_test
    ;;
esac

cleanup
trap - EXIT INT TERM

echo
echo "===== FINAL STATE ====="
show_state
echo "A14_IR_AB_TEST=COMPLETE"
echo "Report which sections were physically visible in the camera: A, B, C, or none."
