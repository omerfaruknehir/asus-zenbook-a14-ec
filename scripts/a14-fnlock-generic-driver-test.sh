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

CUSTOM_DRIVER=hid_asus_zenbook_a14_ec
CUSTOM_MODULE=hid_asus_ec

if [[ "$ORIG_DRIVER" == hid-generic ]]; then
  echo "A14_HID_GENERIC_TEST=ALREADY_GENERIC"
else
  echo "===== A14 FN-LOCK DRIVER-NEUTRAL A/B ====="
  echo "hid_device=$HID_ID"
  echo "original_driver=$ORIG_DRIVER"
  echo "temporary_driver=hid-generic"
  echo "This leaves the I2C-HID transport and EC driver loaded."
  echo "The custom A14 HID client module is temporarily unloaded because"
  echo "hid-generic deliberately refuses devices while any special HID driver"
  echo "registered on the bus matches them."
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

    modprobe "$CUSTOM_MODULE" 2>/dev/null || true

    # Driver registration normally probes matching unbound devices immediately.
    # If this kernel leaves it unbound, request one ordinary HID-bus reprobe.
    if [[ ! -L "$TARGET/driver" && -w /sys/bus/hid/drivers_probe ]]; then
      printf '%s\n' "$HID_ID" >/sys/bus/hid/drivers_probe 2>/dev/null || true
    fi

    if [[ -L "$TARGET/driver" ]]; then
      current=$(basename "$(readlink -f "$TARGET/driver")")
    else
      current=unbound
    fi
    echo "restored_driver=$current"

    if [[ "$ORIG_DRIVER" != unbound && "$current" != "$ORIG_DRIVER" ]]; then
      echo "WARNING: original HID driver was not restored automatically." >&2
      echo "Try: sudo modprobe $CUSTOM_MODULE" >&2
    fi
  fi
}
trap restore_driver EXIT INT TERM

if [[ "$ORIG_DRIVER" != hid-generic ]]; then
  if [[ "$ORIG_DRIVER" != "$CUSTOM_DRIVER" ]]; then
    echo "A14_HID_GENERIC_TEST=UNEXPECTED_ORIGINAL_DRIVER:$ORIG_DRIVER" >&2
    exit 4
  fi

  modprobe hid-generic
  RESTORE_NEEDED=1

  # Important: direct binding to hid-generic fails with ENODEV while our
  # registered special HID driver still matches 0B05:0220. hid-generic's match
  # callback intentionally yields to every matching non-generic driver. Remove
  # only our A14 HID client module, leaving the underlying i2c-hid transport
  # untouched, then reprobe the HID device.
  if ! modprobe -r "$CUSTOM_MODULE"; then
    echo "A14_HID_GENERIC_TEST=CUSTOM_MODULE_UNLOAD_FAILED" >&2
    exit 4
  fi

  if [[ -L "$TARGET/driver" ]]; then
    current=$(basename "$(readlink -f "$TARGET/driver")")
  else
    current=unbound
  fi
  echo "after_custom_module_unload=$current"

  if [[ "$current" == unbound && -w /sys/bus/hid/drivers_probe ]]; then
    printf '%s\n' "$HID_ID" >/sys/bus/hid/drivers_probe
  fi
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
