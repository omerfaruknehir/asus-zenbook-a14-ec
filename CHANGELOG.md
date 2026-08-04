# Changelog

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
