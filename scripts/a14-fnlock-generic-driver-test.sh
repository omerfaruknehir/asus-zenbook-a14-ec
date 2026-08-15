#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 2
fi

DIR=$(cd "$(dirname "$0")" && pwd)
TARGET=
for dev in /sys/bus/hid/devices/*; do
  [[ -r "$dev/uevent" ]] || continue
  if grep -q '^HID_ID=0018:00000B05:00000220$' "$dev/uevent" 2>/dev/null; then
    TARGET=$dev
    break
  fi
done

if [[ -z "$TARGET" ]]; then
  echo "A14_HID_GENERIC_TEST=NO_0B05_0220_DEVICE" >&2
  exit 3
fi

HID_ID=$(basename "$TARGET")
ORIG_DRIVER=unbound
if [[ -L "$TARGET/driver" ]]; then
  ORIG_DRIVER=$(basename "$(readlink -f "$TARGET/driver")")
fi

if [[ "$ORIG_DRIVER" == hid-generic ]]; then
  echo "A14_HID_GENERIC_TEST=ALREADY_GENERIC"
else
  echo "===== A14 FN-LOCK DRIVER-NEUTRAL A/B ====="
  echo "hid_device=$HID_ID"
  echo "original_driver=$ORIG_DRIVER"
  echo "temporary_driver=hid-generic"
  echo "This does not unload the I2C-HID transport or EC driver."
  echo "It only removes the custom A14 HID client driver from 0B05:0220 while testing."
fi

RESTORE_NEEDED=0
restore_driver() {
  local current=unbound
  if [[ -L "$TARGET/driver" ]]; then
    current=$(basename "$(readlink -f "$TARGET/driver")")
  fi

  if [[ $RESTORE_NEEDED -eq 1 ]]; then
    echo
    echo "===== RESTORE ORIGINAL HID DRIVER ====="
    if [[ "$current" == hid-generic && -w /sys/bus/hid/drivers/hid-generic/unbind ]]; then
      printf '%s\n' "$HID_ID" >/sys/bus/hid/drivers/hid-generic/unbind || true
    fi
    modprobe hid_asus_ec 2>/dev/null || true
    if [[ "$ORIG_DRIVER" != unbound && -w "/sys/bus/hid/drivers/$ORIG_DRIVER/bind" ]]; then
      printf '%s\n' "$HID_ID" >"/sys/bus/hid/drivers/$ORIG_DRIVER/bind" 2>/dev/null || true
    fi
    if [[ -L "$TARGET/driver" ]]; then
      current=$(basename "$(readlink -f "$TARGET/driver")")
    else
      current=unbound
    fi
    echo "restored_driver=$current"
  fi
}
trap restore_driver EXIT INT TERM

if [[ "$ORIG_DRIVER" != hid-generic ]]; then
  modprobe hid-generic

  if [[ "$ORIG_DRIVER" != unbound && ! -w "/sys/bus/hid/drivers/$ORIG_DRIVER/unbind" ]]; then
    echo "A14_HID_GENERIC_TEST=ORIGINAL_UNBIND_NOT_WRITABLE" >&2
    exit 4
  fi
  if [[ ! -w /sys/bus/hid/drivers/hid-generic/bind ]]; then
    echo "A14_HID_GENERIC_TEST=GENERIC_BIND_NOT_WRITABLE" >&2
    exit 4
  fi

  # Do not use the per-device driver_override attribute here. On this A14's
  # HID device the kernel exposes it but rejects writes with EACCES even as
  # root. A manual driver's bind node already performs the driver's normal
  # match check, and hid-generic matches this HID device, so direct
  # unbind/bind is sufficient and closer to the test we actually need.
  RESTORE_NEEDED=1
  if [[ "$ORIG_DRIVER" != unbound ]]; then
    printf '%s\n' "$HID_ID" >"/sys/bus/hid/drivers/$ORIG_DRIVER/unbind"
  fi
  printf '%s\n' "$HID_ID" >/sys/bus/hid/drivers/hid-generic/bind
fi

CURRENT_DRIVER=unbound
if [[ -L "$TARGET/driver" ]]; then
  CURRENT_DRIVER=$(basename "$(readlink -f "$TARGET/driver")")
fi
echo "active_test_driver=$CURRENT_DRIVER"
if [[ "$CURRENT_DRIVER" != hid-generic ]]; then
  echo "A14_HID_GENERIC_TEST=FAILED_TO_BIND_GENERIC" >&2
  exit 4
fi

sleep 0.2

echo
echo "===== GENERIC HID STATE=0 ====="
python3 "$DIR/a14-fnlock-probe.py" win-off
echo "Test the SAME F-row key and Fn+key form now. There is NO time limit."
IFS= read -r -p "Describe STATE=0 behavior (or no-change): " STATE0
while [[ -z "${STATE0//[[:space:]]/}" ]]; do
  IFS= read -r -p "Blank is ambiguous; describe STATE=0 or type no-change: " STATE0
done

echo
echo "===== GENERIC HID STATE=1 ====="
python3 "$DIR/a14-fnlock-probe.py" win-on
echo "Test the SAME F-row key and Fn+key form now. There is NO time limit."
IFS= read -r -p "Describe STATE=1 behavior (or no-change): " STATE1
while [[ -z "${STATE1//[[:space:]]/}" ]]; do
  IFS= read -r -p "Blank is ambiguous; describe STATE=1 or type no-change: " STATE1
done

echo
echo "===== RESULT ====="
echo "GENERIC_STATE_0=$STATE0"
echo "GENERIC_STATE_1=$STATE1"
echo "A14_HID_GENERIC_TEST=COMPLETE"
