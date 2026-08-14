# Changelog

## 0.3.0 — 2026-08-15

- Reworked the A14 power-profile contract into five distinct named policies:
  `quiet`, `power-saver`, `balanced`, `performance`, and `full-speed`.
- Kept the recovered ASUS firmware modes intact: Normal `0x01`, Quiet `0x02`,
  Turbo `0x04`, and Full Speed `0x10` remain separate firmware policies.
- Added a dedicated Linux `power-saver` policy using the native Normal fan curve
  plus a moderate per-cpufreq-policy frequency ceiling; GNOME Power Saver no
  longer aliases the separate acoustic Quiet mode.
- Changed Quiet to acoustic-first behavior: native Quiet plus a strong CPU QoS
  cap based on each X Elite cpufreq policy's own maximum frequency rather than
  a hard-coded GHz ceiling.
- Added Quiet emergency cooling hysteresis. At the emergency threshold the
  strong CPU cap remains active while the firmware cooling curve is temporarily
  promoted to Turbo; it automatically returns to native Quiet after recovery.
- Added a fail-safe for missing cpufreq QoS: Quiet never silently becomes a
  hot/minimal-fan mode when throttling control is unavailable. It immediately
  forces Turbo cooling, remains visibly selected as Quiet, and emits an
  emergency notification explaining that CPU throttling control is unavailable.
- Added a pollable `quiet_emergency` sysfs state and kernel `KOBJ_CHANGE` uevents
  carrying emergency state, temperature, and reason (`thermal`, `recovered`,
  `profile-change`, or `qos-unavailable`).
- Added GNOME desktop notifications when Quiet emergency cooling engages and
  when it clears. The engage notification is critical/persistent and the clear
  notification replaces it.
- Changed Full Speed into a literal maximum-cooling policy: select the recovered
  native Full Speed firmware mode, remove artificial CPU caps, and command both
  fans to PWM 255 while retaining the SoC/kernel's normal hardware thermal
  protection.
- Made profile transitions transactional across low-level fan ownership, native
  firmware marker, CPU QoS and Quiet-emergency state, with coherent rollback on
  partial failure and full hardware-policy replay after resume.
- Exposed `PLATFORM_PROFILE_LOW_POWER` separately from `PLATFORM_PROFILE_QUIET`;
  retained `PLATFORM_PROFILE_PERFORMANCE` and `PLATFORM_PROFILE_MAX_POWER` for
  the corresponding high-power policies.
- Updated the power-profiles-daemon-compatible fallback bridge so GNOME's stock
  three profiles map to Power Saver / Balanced / Performance rather than
  collapsing Power Saver into Quiet.
- Added automatic GNOME backend selection: use native Linux `platform_profile`
  when the A14 handler is available, otherwise enable the packaged compatible
  fallback bridge and restore the distribution daemon when native support is
  present again.
- Added a narrow root-owned A14 system D-Bus profile service exposing only the
  five named modes and emergency state; it deliberately exposes no raw EC,
  register, PWM, mailbox, or MMIO API to the desktop.
- Added the GNOME Shell **A14 Mode** Quick Settings menu for Quiet / Power Saver /
  Balanced / Performance / Full Speed. The extra top-bar indicator stays hidden
  normally and appears only while Quiet emergency cooling is active.
- Added system-wide GNOME extension installation/auto-enable integration; a
  newly installed extension may require one logout/login for an already-running
  Wayland Shell session to discover it.
- Added a safe Quiet-emergency validation that lowers the temporary threshold
  instead of heating the machine to the real emergency temperature, verifies
  sysfs/uevents/desktop delivery, then restores the original thresholds.
- Updated profile load validation for the A14's real
  `cpuN/cpufreq/cpuinfo_avg_freq` telemetry, QoS max-frequency reporting, the
  new Power Saver policy, and literal PWM-255 Full Speed verification.
- Reworked the DT `platform_profile` validation to build a native ARM64
  `gendwarfksyms` from the exact 7.1.5 source when Ubuntu/mainline ARM64 headers
  contain the wrong x86-64 host executable. The validator no longer changes the
  configured symbol-versioning algorithm as a workaround.
- Fixed the installed modprobe configuration to remove the obsolete
  `quiet_max_khz=1440000` parameter and install the new percentage/hysteresis
  parameters instead, preventing the new module from rejecting its own package
  configuration.
- Recorded the complete hardware load capture establishing the real firmware
  ordering `quiet < balanced << performance < full-speed`.
- Added package/CI coverage for the five-mode policy, emergency notification
  path, udev integration, narrow profile D-Bus service and GNOME Quick Settings.
- Bumped the DKMS/DEB package version so existing 0.2.0 installs are actually
  upgraded to the new policy stack.

## Earlier unreleased platform work

- Hardened direct EC fan-control recovery: automatic mode is now written,
  read back and verified with bounded retries instead of being assumed from a
  successful write.
- Closed manual-mode failure paths so partial PWM setup, thermal fallback and
  failed automatic recovery keep retrying the safety path rather than leaving
  manual fan control unmonitored.
- Made suspend fail closed when automatic fan restore or EC mailbox quiesce
  fails, and restore the pre-suspend performance state if suspend is aborted
  after the fan controller was already returned to automatic mode.
- Added retryable EC mailbox quiescing and explicit shutdown/remove diagnostics
  instead of silently discarding EC communication failures.
- Kept hwmon/profile state coherent by forcing real automatic mode for
  `pwm1_enable=2` and notifying profile observers after direct hwmon changes.
- Fixed DKMS source packaging so guarded EC/HID source transforms are present in
  `/usr/src`, stale orphaned DKMS registrations are cleaned during upgrades,
  and initramfs is refreshed so an older HID module cannot return after reboot.
- Started the always-on camera and human-presence work as proper kernel,
  device-tree, firmware and standard sensor-subsystem support.
- Added a read-only Linux probe covering OV02C10/CAMSS, ADSP remoteproc,
  QRTR/QMI/RPMSG, device tree, firmware hashes, media topology and IIO state.
- Corrected numeric device-tree decoding, removed an unsupported QRTR `ss`
  query, narrowed firmware enumeration, and added kernel-source/DTB provenance.
- Added a manually built, non-packaged kernel development module that binds to
  SSC QMI service 400 through the in-kernel QRTR/QMI framework.
- Added runtime SUID discovery for camera handshake, human-presence detection
  and camera face detection, plus an IIO proximity/change-event frontend.
- Added machine-confirmed camera handshake 576/ACK 832 and HPD 512/event 928
  protocol handling with service-loss cleanup and endpoint rediscovery.
- Kept the SSC driver entirely outside the EC DKMS/DEB package, systemd units
  and automatic module-loading paths.
- Added a separate source patcher for GNOME Resources that corrects Snapdragon
  CPU identity, online topology, socket/core counts and cpufreq reporting using
  standard device-tree and sysfs interfaces without a runtime helper.
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
