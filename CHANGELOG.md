# Changelog

## Unreleased

- Started the always-on camera and human-presence work as proper kernel,
  device-tree, firmware and standard sensor-subsystem support.
- Added a read-only Linux probe covering OV02C10/CAMSS, ADSP remoteproc,
  QRTR/QMI/RPMSG, device tree, firmware hashes, media topology and IIO state.
- Added provenance and known-good hashes for the machine-matched QSH camera,
  OV02C10 and HM1092 firmware/configuration files without redistributing them.
- Documented the planned upstream patch split and acceptance criteria.
- Explicitly separated optional GNOME/KDE indicators from core hardware support;
  desktop helpers may consume standard interfaces but may not implement the
  camera, QSH transport or sensor ABI.

## 0.2.0 — 2026-08-04

- Added a shutdown/quiesce path for orderly warm reboot and poweroff.
- Replaced early module autoloading with a late systemd service.
- Added strict device-tree model gating for UX3407RA and UX3407QA.
- Added retryable EC transfers and checked probe-time reads.
- Removed dead/non-existent `0x76` fan-controller handling from the A14 path.
- Changed quiet mode from fan-off to the EC automatic curve plus CPU cap.
- Replaced the hard-coded uncapped CPU frequency with the QoS default.
- Added a manual-mode thermal/read-failure safety fallback.
- Rejected below-spin-floor manual PWM values instead of permitting fan-off control.
- Added compatibility for kernels before the modern 6.14 `platform_profile` API.
- Added a permanent local profile sysfs interface.
- Fixed keyboard-backlight suspend restore.
- Moved Fn+F4 HID writes out of the raw-event path.
- Gated raw HID commands behind a root-only, opt-in module parameter.
- Added DKMS, DEB packaging, a one-command installer, systemd integration,
  GitHub Actions package builds, and `asus-a14-control`.
- Restored the original power-profile bridge as a current, packaged, optional
  systemd D-Bus fallback instead of a manually launched raw-hwmon daemon.
- Added `asus-a14-control ppd-bridge` management and automatic restoration of
  the distribution `power-profiles-daemon` when the fallback is disabled or
  the package is removed.
- Documented the separate EC lifecycle and optional power-profile bridge units,
  including their conflict and restoration behavior.
