#!/usr/bin/env bash
set -euo pipefail

# Hardware smoke-test for the PM8550 V4L2 Torch path used by Aegis Hello.
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

echo "flash=$flash torch_range=${min}..${max} step=$step target=${target}uA"
cleanup() { sudo v4l2-ctl -d "$flash" --set-ctrl=led_mode=0 >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
sudo v4l2-ctl -d "$flash" --set-ctrl=led_mode=0
sudo v4l2-ctl -d "$flash" --set-ctrl=intensity_torch_mode="$target"
sudo v4l2-ctl -d "$flash" --set-ctrl=led_mode=2
v4l2-ctl -d "$flash" --get-ctrl=led_mode,intensity_torch_mode

echo "Torch is enabled for ${duration}s"
sleep "$duration"
cleanup
trap - EXIT INT TERM
echo "A14_IR_TORCH_SMOKE=PASS"
