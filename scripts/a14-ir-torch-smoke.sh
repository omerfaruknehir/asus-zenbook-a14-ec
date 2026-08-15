#!/usr/bin/env bash
set -euo pipefail

# Hardware-control smoke-test for the PM8550 V4L2 Torch path used by Aegis
# Hello. IMPORTANT: successful control readback does not prove that the IR LED
# emitted photons; use a camera or scripts/a14-ir-output-ab-test.sh for that.
# Default 35% of the observed 500000 uA max is 175000 uA.
percent=${1:-35}
duration=${2:-2}

command -v v4l2-ctl >/dev/null 2>&1 || {
  echo "v4l2-ctl is required (package: v4l-utils)" >&2
  exit 2
}

flash=
controls=
for dev in /dev/v4l-subdev*; do
  [[ -e "$dev" ]] || continue
  out=$(v4l2-ctl -d "$dev" --list-ctrls-menus 2>/dev/null || true)
  if grep -q 'led_mode' <<<"$out" && grep -q 'intensity_torch_mode' <<<"$out"; then
    flash=$dev
    controls=$out
    break
  fi
done
[[ -n "$flash" ]] || { echo "no V4L2 flash subdevice with Torch mode found" >&2; exit 3; }

line=$(v4l2-ctl -d "$flash" --list-ctrls | grep 'intensity_torch_mode' | head -1 || true)
[[ $line =~ min=([0-9]+).*max=([0-9]+).*step=([0-9]+) ]] || {
  echo "cannot parse Torch current range on $flash" >&2
  exit 3
}
min=${BASH_REMATCH[1]}
max=${BASH_REMATCH[2]}
step=${BASH_REMATCH[3]}

(( percent < 1 )) && percent=1
(( percent > 100 )) && percent=100
target=$(( max * percent / 100 ))
(( target < min )) && target=$min
target=$(( min + ((target - min + step / 2) / step) * step ))
(( target > max )) && target=$max

gate=
for path in /sys/bus/platform/drivers/i2c-qcom-cci/*/hm1092_ir/force_off; do
  [[ -e "$path" ]] || continue
  gate=$path
  break
done

echo "flash=$flash torch_range=${min}..${max} step=$step target=${target}uA"
echo "force_off_gate=${gate:-not-found}"

cleanup() {
  sudo v4l2-ctl -d "$flash" --set-ctrl=led_mode=0 >/dev/null 2>&1 || true
  if [[ -n "$gate" ]]; then
    printf '1\n' | sudo tee "$gate" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

# Establish a known-safe OFF state first when the optional HM1092 gate exists.
# Some current kernels expose no such gate; in that case this script tests only
# the standard V4L2/LED-class PM8550 control path.
if [[ -n "$gate" ]]; then
  printf '1\n' | sudo tee "$gate" >/dev/null
fi
sudo v4l2-ctl -d "$flash" --set-ctrl=led_mode=0
sudo v4l2-ctl -d "$flash" --set-ctrl=intensity_torch_mode="$target"
if [[ -n "$gate" ]]; then
  printf '0\n' | sudo tee "$gate" >/dev/null
fi
sudo v4l2-ctl -d "$flash" --set-ctrl=led_mode=2

sleep 0.20
echo "Torch readback after 200 ms:"
v4l2-ctl -d "$flash" --get-ctrl=led_mode,intensity_torch_mode
if [[ -n "$gate" ]]; then
  printf 'force_off=' && cat "$gate"
fi

echo "Torch control is requested for ${duration}s"
sleep "$duration"
echo "Torch readback before shutdown:"
v4l2-ctl -d "$flash" --get-ctrl=led_mode,intensity_torch_mode
cleanup
trap - EXIT INT TERM
echo "A14_IR_TORCH_CONTROL_PATH=ACCEPTED_NO_OPTICAL_VERIFICATION"
