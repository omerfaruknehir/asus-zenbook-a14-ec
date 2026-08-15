#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo"

# Basic syntax and source-level regressions.
sh -n install.sh scripts/build-deb.sh scripts/asus-a14-control \
  scripts/asus-zenbook-a14-ec-load scripts/asus-zenbook-a14-ec-unload \
  scripts/asus-zenbook-a14-profile-integration \
  scripts/asus-zenbook-a14-enable-gnome-extension

python3 -m py_compile \
  scripts/prepare-a14-ec.py \
  scripts/apply-a14-ec-hardening.py \
  scripts/apply-a14-native-fan-profile.py \
  scripts/apply-a14-native-hardening-compat.py \
  scripts/apply-a14-native-max-power.py \
  scripts/apply-a14-native-fan-telemetry.py \
  scripts/apply-a14-native-mode-names-hotkey.py \
  scripts/apply-a14-whisper.py \
  scripts/apply-a14-hid-fnlock.py \
  scripts/apply-a14-hid-profile-hotkey.py \
  scripts/asus-zenbook-a14-ppd-bridge.py \
  scripts/asus-zenbook-a14-profile-service.py \
  desktop/resources/apply-a14-cpu-info.py \
  desktop/resources/repair-a14-cpu-info.py \
  desktop/resources/repair-a14-cpu-topology.py \
  desktop/resources/repair-a14-gpu-metrics.py

# Keep the existing desktop/resource regression coverage.
python3 desktop/resources/test-patcher.py
python3 desktop/resources/test-repair.py
python3 desktop/resources/test-topology-repair.py
python3 desktop/resources/test-gpu-metrics-repair.py

version=$(cat VERSION)
grep -q "PACKAGE_VERSION=\"$version\"" dkms.conf

test -s AOS-KERNEL-BRINGUP.md
test -s docs/aos/ARCHITECTURE.md
test -s docs/ec/2026-08-14-native-profile-validation.md
test -s kernel/aos/qcom_ssc_hpd.c
test -s kernel/aos/qcom_ssc_hpd_transport.c
test -s kernel/aos/PROTOCOL.md
# Preserve the most important SSC framing invariant while this branch changes EC policy.
grep -q 'elem_len = (u32)len' kernel/aos/qcom_ssc_hpd_transport.c
grep -A5 'elem_len = (u32)len' kernel/aos/qcom_ssc_hpd_transport.c | grep -q 'array_type = STATIC_ARRAY'
grep -q 'No `QMI_DATA_LEN` element is used for control requests' kernel/aos/PROTOCOL.md

# Desktop-facing order and names.
grep -Fq 'PROFILES = ("whisper", "quiet", "normal", "turbo", "full-speed")' \
  scripts/asus-zenbook-a14-profile-service.py
grep -Fq 'GPU_PERCENT = {0: 60, 1: 45, 2: 30, 3: 30}' \
  scripts/asus-zenbook-a14-profile-service.py
grep -Fq "const PROFILE_ORDER = ['whisper', 'quiet', 'normal', 'turbo', 'full-speed'];" \
  gnome-shell/asus-a14-modes@omerfaruknehir/extension.js
grep -q 'osdWindowManager.showAll' gnome-shell/asus-a14-modes@omerfaruknehir/extension.js
grep -q 'osdWindowManager.show' gnome-shell/asus-a14-modes@omerfaruknehir/extension.js
if grep -q 'Main.notify\|Main.notifyError' gnome-shell/asus-a14-modes@omerfaruknehir/extension.js; then
  echo 'profile changes must use OSD, not GNOME notifications' >&2
  exit 1
fi

# Compose exactly what DKMS will build.
make prepare

ec=asus_zenbook_a14_ec.c
hid=hid_asus_ec.c

grep -q '#define EC_FW_FAN_PROFILE_NORMAL         0x01' "$ec"
grep -q '#define EC_FW_FAN_PROFILE_QUIET          0x02' "$ec"
grep -q '#define EC_FW_FAN_PROFILE_TURBO          0x04' "$ec"
grep -q '#define EC_FW_FAN_PROFILE_FULL_SPEED     0x10' "$ec"
grep -q 'A14_NATIVE_MODE_NAMES_HOTKEY' "$ec"
grep -q 'A14_WHISPER_MODE' "$ec"
grep -q 'ASUS_EC_PROFILE_WHISPER' "$ec"
grep -q 'whisper quiet normal turbo full-speed' "$ec"
grep -q 'asus_ec_set_pwm_both(ec, 0)' "$ec"
grep -q 'whisper_cpu_cool_percent' "$ec"
grep -q 'whisper_cpu_warm_percent' "$ec"
grep -q 'whisper_cpu_hot_percent' "$ec"
grep -q 'whisper_fan_mc' "$ec"
grep -q 'whisper_recover_mc' "$ec"
grep -q 'DEVICE_ATTR_RO(whisper_level)' "$ec"
grep -q 'EXPORT_SYMBOL_GPL(asus_a14_cycle_native_profile)' "$ec"
grep -q 'case ASUS_EC_PROFILE_WHISPER: next = ASUS_EC_PROFILE_QUIET' "$ec"
grep -q 'case ASUS_EC_PROFILE_QUIET: next = ASUS_EC_PROFILE_BALANCED' "$ec"
grep -q 'case ASUS_EC_PROFILE_BALANCED: next = ASUS_EC_PROFILE_PERFORMANCE' "$ec"
grep -q 'case ASUS_EC_PROFILE_PERFORMANCE: next = ASUS_EC_PROFILE_FULL_SPEED' "$ec"
grep -q 'default: next = ASUS_EC_PROFILE_WHISPER' "$ec"

grep -q 'A14_HID_NATIVE_PROFILE_HOTKEY' "$hid"
grep -q 'asus_a14_cycle_native_profile();' "$hid"
grep -q 'schedule_work(&data->profile_work)' "$hid"

# Removed policies may still exist as repository history/helper files, but must
# never appear in the final generated driver source.
for forbidden in \
  A14_PROFILE_POLICY_V2 A14_QUIET_FANLESS A14_THERMAL_SAFETY A14_QOS_COMPLETE \
  ASUS_EC_PROFILE_POWER_SAVER power_saver_max_percent quiet_fan_pwm \
  'asus_ec_enter_manual_locked(ec, 255)'; do
  if grep -Fq "$forbidden" "$ec"; then
    echo "obsolete synthetic named policy leaked into EC source: $forbidden" >&2
    exit 1
  fi
done

# If runner headers match, compile both DKMS modules and catch cross-module
# symbol/workqueue mistakes in Fn+F and Whisper.
if [ -e "/lib/modules/$(uname -r)/build/Makefile" ]; then
  make clean >/dev/null 2>&1 || true
  make -j2
fi

# Package and inspect the artifact.
./scripts/build-deb.sh >/dev/null
deb="dist/asus-zenbook-a14-ec-dkms_${version}_all.deb"
test -s "$deb"
dpkg-deb --info "$deb" >/dev/null
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT INT TERM
dpkg-deb -x "$deb" "$root"
src="$root/usr/src/asus-zenbook-a14-ec-$version"
test -s "$src/asus_zenbook_a14_ec.c"
test -s "$src/hid_asus_ec.c"
test -x "$root/usr/libexec/asus-zenbook-a14-profile-service"
test -s "$root/usr/share/gnome-shell/extensions/asus-a14-modes@omerfaruknehir/extension.js"

# A composed source package must be independently re-preparable even if a
# repository-only transform is not present in an installed source tree.
make -C "$src" prepare

grep -q 'A14_WHISPER_MODE' "$src/asus_zenbook_a14_ec.c"
grep -q 'A14_HID_NATIVE_PROFILE_HOTKEY' "$src/hid_asus_ec.c"
grep -Fq 'PROFILES = ("whisper", "quiet", "normal", "turbo", "full-speed")' \
  "$root/usr/libexec/asus-zenbook-a14-profile-service"

echo 'Validation passed: Whisper < Quiet < Normal < Turbo < Full Speed'
