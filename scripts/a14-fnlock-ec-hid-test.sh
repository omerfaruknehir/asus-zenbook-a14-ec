#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo bash $0 [all|off|on]" >&2
  exit 2
fi

MODE=${1:-all}
case "$MODE" in
  all|off|on) ;;
  *) echo "usage: sudo bash $0 [all|off|on]" >&2; exit 2 ;;
esac

DIR=$(cd "$(dirname "$0")" && pwd)
ATTR=
for candidate in /sys/bus/platform/devices/asus_zenbook_a14_ec*/fnlock_firmware_stage; do
  if [[ -e "$candidate" ]]; then
    ATTR=$candidate
    break
  fi
done

if [[ -z "$ATTR" ]]; then
  echo "FNLOCK_EC_STAGE_SYSFS=NOT_FOUND" >&2
  echo "The running asus_zenbook_a14_ec module does not contain the new DSDT-stage probe." >&2
  echo "Install/reload the current branch first, then rerun this test." >&2
  exit 3
fi

run_state() {
  local state=$1
  local action
  local label
  if [[ "$state" == 0 ]]; then
    action=win-off
    label=ASUS-action-keys-primary
  else
    action=win-on
    label=F1-F12-primary
  fi

  echo
  echo "===== DSDT EC STAGE + WINDOWS HID STATE=$state ====="
  echo "sysfs=$ATTR"
  echo "firmware_stage=ECCW(0x02,0x84,$([[ $state == 0 ]] && printf '0x04' || printf '0x08'))"
  printf '%s\n' "$state" >"$ATTR"
  sleep 0.05
  python3 "$DIR/a14-fnlock-probe.py" "$action"
  echo "requested_mode=$label"
}

echo "===== A14 FN-LOCK DSDT EC + HID A/B ====="
echo "This reproduces the BIOS DEVS(0x00100023,state) EC mailbox side effect"
echo "observed with KFSK != 0x80, then performs the full FF31:0076 Windows HID"
echo "init/config/get/Fn-switch transaction. There is NO timer for key testing."

if [[ "$MODE" == off || "$MODE" == all ]]; then
  run_state 0
  if [[ "$MODE" == all ]]; then
    echo
    echo "Test the SAME ordinary F-row key and Fn+key form now."
    echo "Press Enter only when you are finished testing STATE=0."
    IFS= read -r _
  fi
fi

if [[ "$MODE" == on || "$MODE" == all ]]; then
  run_state 1
  if [[ "$MODE" == all ]]; then
    echo
    echo "Test the SAME ordinary F-row key and Fn+key form now."
    echo "Press Enter only when you are finished testing STATE=1."
    IFS= read -r _
  fi
fi

echo
echo "===== EC DRIVER LOG TAIL ====="
dmesg --ctime 2>/dev/null | grep -E 'asus_zenbook_a14_ec|Fn-lock DSDT firmware stage' | tail -n 30 || true

echo
echo "A14_FNLOCK_EC_HID_TEST=COMPLETE"
echo "Report whether STATE=0 and STATE=1 physically produced different F-row modes."
