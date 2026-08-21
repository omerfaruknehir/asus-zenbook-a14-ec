# ITE51300 EC feature-coverage ToDo

This is the umbrella checklist for inventorying, reverse-engineering, documenting, and—where safe and useful—supporting every host-accessible EC feature on the UX3407RA. Split confirmed features into focused work items as the interfaces become understood.

## Verified baseline

- `UX3407RA.312` contains a 256 KiB EC image named `F0184104.UX3407RA.313`.
- EC identity: `ITE51300-EC-V0.00`; architecture: RV32IMC.
- EC-image SHA-256: `353eb0d125d76a14f15faa72f2153d57e25efd8d212f42b18a9f11c16e3fc39d`.
- The EC firmware contains the HID descriptors for ASUS devices `0B05:0220` and `0B05:4543`.
- Confirmed backlight command: `5A BA C5 C4 LEVEL`.
- The public handler maps logical levels to PWM targets: `0 -> 00`, `1 -> 43`, `2 -> 87`, `3 -> CC`; every other value maps to zero.
- A separate EC routine ramps PWM channel 4 toward its 8-bit target in steps of 3.
- Mailbox `01/07` reads PWM channel 4 and `01/87` writes its current duty cycle, but the firmware ramp overwrites that one-shot value.
- The stable target lives at EC RAM `0x80304a`; stock firmware exposes no host command that writes it raw.
- A hash- and instruction-gated 10-byte patch is documented and generated without any flashing support.
- Copied backlight payloads sent to 4543 produced no physical effect, with or without the basic ASUS identity/config session.
- Firmware flashing/recovery paths are never runtime probe targets.
- The signed FV contains an AArch64 UEFI `ECFlashApp` with explicit flash-ID, erase, program, byte-for-byte verify, and retry paths; authentication and recovery behavior remain unproven.

## 1. Reproducible firmware inventory

- [ ] Add a deterministic capsule → FV → FFS → section → EC-image inventory tool.
- [ ] Record hashes, offsets, GUIDs, UI names, compression types, and module identities.
- [ ] Add a pinned RV32IMC disassembly workflow.
- [ ] Generate an EC function, call, and data-reference map.
- [ ] Compare future firmware revisions without committing proprietary firmware blobs.

## 2. Host-interface map

- [ ] Document every ACPI EC method/field used by Linux or Windows, including `ECCR`, `ECCW`, notifications, and ASUS methods.
- [ ] Inventory all HID report IDs, lengths, usages, commands, and responses on 0220 and 4543.
- [ ] Map the confirmed EC command families: `BA C5 C4`, `D0 4E`, `D0 7C`, `D0 85`, `D0 8F`, and `F4 6B`.
- [ ] Correlate EC internal state with safe host-visible reads.
- [ ] Classify each interface as read-only, reversible write, persistent write, flash/recovery, or unknown.

## 3. Feature coverage

- [ ] Keyboard matrix, hotkeys, consumer usages, Fn-lock, and report routing.
- [ ] Keyboard-backlight raw PWM, logical policy, ramping, Fn+F4, boot, suspend, and resume.
  - [x] Map the public HID levels, PWM channel, target byte, and ramp routine.
  - [x] Prove why one-shot mailbox PWM writes are not stable.
  - [x] Generate the minimal raw-target firmware patch with exact hash/instruction guards.
  - [ ] Validate a non-destructive EC deployment, backup, and recovery path before enabling the patch.
  - [ ] Expose `0..255` through LED class only after the patched target path is physically validated.
- [ ] Fan control, tachometer telemetry, thermal thresholds, and fail-safe behavior.
- [ ] Power/platform profiles and profile hotkeys.
- [ ] Battery/charger state, charge limits, AC events, and battery safety.
- [ ] Lid, power button, wake sources, sleep/resume, and power sequencing.
- [ ] GPIO-controlled platform devices and indicators.
- [ ] Thermal sensors and any ambient/adaptive inputs.
- [ ] Device identity, board configuration, manufacturing data, and read-only diagnostics.
- [ ] Firmware update/recovery discovery and documentation only; no automatic flashing.
  - [x] Locate and reproducibly extract the exact `ECFlashApp` UEFI module.
  - [ ] Reverse the `$ECDH# ITE51300 EC feature-coverage ToDo

This is the umbrella checklist for inventorying, reverse-engineering, documenting, and—where safe and useful—supporting every host-accessible EC feature on the UX3407RA. Split confirmed features into focused work items as the interfaces become understood.

## Verified baseline

- `UX3407RA.312` contains a 256 KiB EC image named `F0184104.UX3407RA.313`.
- EC identity: `ITE51300-EC-V0.00`; architecture: RV32IMC.
- EC-image SHA-256: `353eb0d125d76a14f15faa72f2153d57e25efd8d212f42b18a9f11c16e3fc39d`.
- The EC firmware contains the HID descriptors for ASUS devices `0B05:0220` and `0B05:4543`.
- Confirmed backlight command: `5A BA C5 C4 LEVEL`.
- The public handler maps logical levels to PWM targets: `0 -> 00`, `1 -> 43`, `2 -> 87`, `3 -> CC`; every other value maps to zero.
- A separate EC routine ramps PWM channel 4 toward its 8-bit target in steps of 3.
- Mailbox `01/07` reads PWM channel 4 and `01/87` writes its current duty cycle, but the firmware ramp overwrites that one-shot value.
- The stable target lives at EC RAM `0x80304a`; stock firmware exposes no host command that writes it raw.
- A hash- and instruction-gated 10-byte patch is documented and generated without any flashing support.
- Copied backlight payloads sent to 4543 produced no physical effect, with or without the basic ASUS identity/config session.
- Firmware flashing/recovery paths are never runtime probe targets.
- The signed FV contains an AArch64 UEFI `ECFlashApp` with explicit flash-ID, erase, program, byte-for-byte verify, and retry paths; authentication and recovery behavior remain unproven.

## 1. Reproducible firmware inventory

- [ ] Add a deterministic capsule → FV → FFS → section → EC-image inventory tool.
- [ ] Record hashes, offsets, GUIDs, UI names, compression types, and module identities.
- [ ] Add a pinned RV32IMC disassembly workflow.
- [ ] Generate an EC function, call, and data-reference map.
- [ ] Compare future firmware revisions without committing proprietary firmware blobs.

## 2. Host-interface map

- [ ] Document every ACPI EC method/field used by Linux or Windows, including `ECCR`, `ECCW`, notifications, and ASUS methods.
- [ ] Inventory all HID report IDs, lengths, usages, commands, and responses on 0220 and 4543.
- [ ] Map the confirmed EC command families: `BA C5 C4`, `D0 4E`, `D0 7C`, `D0 85`, `D0 8F`, and `F4 6B`.
- [ ] Correlate EC internal state with safe host-visible reads.
- [ ] Classify each interface as read-only, reversible write, persistent write, flash/recovery, or unknown.

## 3. Feature coverage

- [ ] Keyboard matrix, hotkeys, consumer usages, Fn-lock, and report routing.
- [ ] Keyboard-backlight raw PWM, logical policy, ramping, Fn+F4, boot, suspend, and resume.
  - [x] Map the public HID levels, PWM channel, target byte, and ramp routine.
  - [x] Prove why one-shot mailbox PWM writes are not stable.
  - [x] Generate the minimal raw-target firmware patch with exact hash/instruction guards.
  - [ ] Validate a non-destructive EC deployment, backup, and recovery path before enabling the patch.
  - [ ] Expose `0..255` through LED class only after the patched target path is physically validated.
- [ ] Fan control, tachometer telemetry, thermal thresholds, and fail-safe behavior.
- [ ] Power/platform profiles and profile hotkeys.
- [ ] Battery/charger state, charge limits, AC events, and battery safety.
- [ ] Lid, power button, wake sources, sleep/resume, and power sequencing.
- [ ] GPIO-controlled platform devices and indicators.
- [ ] Thermal sensors and any ambient/adaptive inputs.
- [ ] Device identity, board configuration, manufacturing data, and read-only diagnostics.
 validation and any checksum/signature policy.
  - [ ] Map flash geometry, erase/program granularity, flash-ID allow-list, retry limits, and I2C transport.
  - [ ] Determine single-bank versus dual-bank layout and boot-time rollback behavior.
  - [ ] Establish readback backup and board-level recovery before permitting any write.

## 4. Linux interfaces

- [ ] Prefer standard subsystems: LED class, input, hwmon, thermal, power_supply, platform_profile, rfkill, and firmware attributes.
- [ ] Avoid parallel userspace daemons when a safe kernel interface exists.
- [ ] Define locking, serialization, timeouts, suspend/resume restoration, and firmware-ownership rules.
- [ ] Preserve firmware defaults on unsupported models and EC versions.
- [ ] Gate model-specific functions with exact board/EC quirks.

## 5. Safety and validation

- [ ] Provide a read-only inventory/probe mode.
- [ ] Require explicit opt-in for unknown writes; bound each test and restore prior state.
- [ ] Never brute-force flash, persistent storage, battery, thermal, or power-sequencing commands.
- [ ] Record endpoint, command, response, physical observation, kernel log, and recovery result.
- [ ] Add parser/mapping unit tests and confirmed-feature hardware smoke tests.
- [ ] Test cold boot, reboot, module reload, suspend/resume, AC/battery transitions, and recovery.

## Definition of done

- Every discoverable host-facing EC interface has an evidence trail and safety classification.
- Every safely supportable feature has a documented Linux ABI and regression coverage.
- Risky or unsupported functions are explicitly documented with evidence.
- Keyboard backlight exposes genuine hardware behavior; no fake 0–255 sysfs scaling.
