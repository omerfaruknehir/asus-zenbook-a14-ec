# ITE51300 EC feature-coverage ToDo

This is the umbrella checklist for inventorying, reverse-engineering,
documenting, and—where safe and useful—supporting every host-accessible EC
feature on the UX3407RA. Split confirmed features into focused work items as
the interfaces become understood.

## Verified baseline

- `UX3407RA.309` contains a 256 KiB EC image named
  `F0184104.UX3407RA.312`; `UX3407RA.312` contains
  `F0184104.UX3407RA.313`.
- EC identity: `ITE51300-EC-V0.00`; architecture: RV32IMC.
- EC-image SHA-256:
  `353eb0d125d76a14f15faa72f2153d57e25efd8d212f42b18a9f11c16e3fc39d`.
- The EC firmware contains the HID descriptors for ASUS devices `0B05:0220`
  and `0B05:4543`.
- Confirmed backlight command: `5A BA C5 C4 LEVEL`.
- The public handler maps logical levels to PWM targets: `0 -> 00`, `1 -> 43`,
  `2 -> 87`, `3 -> CC`; every other value maps to zero.
- A separate EC routine ramps PWM channel 4 toward its 8-bit target in steps of
  3.
- Mailbox `01/07` reads PWM channel 4 and `01/87` writes its current duty cycle,
  but the firmware ramp overwrites that one-shot value.
- The stable target lives at EC RAM `0x0080304a`; stock firmware exposes no host
  command that writes it raw.
- A hash- and instruction-gated 10-byte patch is documented and generated
  without any flashing support. Its output is explicitly marked
  `flash_ready=NO`.
- Stock UX3407RA EC revisions preserve the 16-byte header shape but change
  bytes `0x4a..0x4b` (`df e2` in EC `.312`, `f7 bb` in EC `.313`). A related
  UX3407QA EC `.313` uses `a3 ca` and its next EC `.314` uses `91 65`;
  common checksum models tested so far do not reproduce the field.
- Copied backlight payloads sent to 4543 produced no physical effect, with or
  without the basic ASUS identity/config session.
- Firmware flashing/recovery paths are never runtime probe targets.
- The signed FV contains an AArch64 UEFI `ECFlashApp` that erases, programs, and
  verifies the complete EC image range `0x00000..0x3ffff`.
- `ECFlashApp` accepts JEDEC IDs `EF 60 14` and `C8 60 14`, programs in 128-byte
  chunks, erases 4 KiB sectors, and retries a failed update up to three times.
- `ECFlashApp` performs byte-for-byte verification but makes no pre-write backup
  and has no rollback path in its own code.
- A write-incapable AArch64 UEFI readback application now mirrors the exact
  Qualcomm I2C/SPI read transport, permits only SPI `0x9f` and `0x0b`, reads the
  complete 1 MiB device three times, and fails closed on any mismatch.
- Its raw-payload validation is not cryptographic: `$ECDH$` is used to extract
  a display version and the only enforced identity is `ITE51300-EC-V0.00` at
  image offset `0x50`. Outer capsule authentication is a separate layer.
- Confirmed Fn-switch command: `5A D0 4E STATE`; state zero requests action
  keys and state one requests F1-F12.
- Fn-switch requests are queued in `0x00803049` and are serviced only while
  `0x00800410 == 0` and bit 7 of `0x0080041a` is set.
- Confirmed auxiliary command: `5A D0 8F 01`; it sets bit 7, clears bit 6 at
  `0x008012a0`, and clears an associated mode/counter. Hardware testing
  disproved it as a sufficient Fn-switch prerequisite.
- A SHA-locked RV32IMC analyzer and compiled C++ behavioral reconstruction now
  validate these recovered paths without embedding or modifying ASUS firmware.

## 1. Reproducible firmware inventory

- [ ] Add a deterministic capsule → FV → FFS → section → EC-image inventory
  tool.
- [x] Add exact, fail-closed FMP, EC-image, and `ECFlashApp` extractors.
- [ ] Record hashes, offsets, GUIDs, UI names, compression types, and module
  identities in generated output.
- [x] Add a SHA-locked RV32IMC disassembly workflow for recovered handlers.
- [ ] Generate an EC function, call, and data-reference map.
- [ ] Compare future firmware revisions without committing proprietary firmware
  blobs.

## 2. Host-interface map

- [ ] Document every ACPI EC method/field used by Linux or Windows, including
  `ECCR`, `ECCW`, notifications, and ASUS methods.
- [ ] Inventory all HID report IDs, lengths, usages, commands, and responses on
  0220 and 4543.
- [ ] Map the confirmed EC command families: `BA C5 C4`, `D0 4E`, `D0 7C`,
  `D0 85`, `D0 8F`, and `F4 6B`.
- [ ] Correlate EC internal state with safe host-visible reads.
- [ ] Classify each interface as read-only, reversible write, persistent write,
  flash/recovery, or unknown.

## 3. Feature coverage

- [ ] Keyboard matrix, hotkeys, consumer usages, Fn-lock, and report routing.
  - [x] Locate the exact `D0/4E` parser, request-bit handlers, current-state
    bit, asynchronous service routine, and its two gates.
  - [x] Locate the `D0/8F/01` auxiliary timed-state handler and disprove it as
    the missing gate through hardware testing.
  - [x] Disprove physical Fn+F12 as the producer of internal protocol opcode
    `0x86`; the identical number is a collision between two namespaces.
  - [x] Identify BIOS 312's real host-enable producer: serialized
    `ECCW(02,87,00)` then `ECCW(02,86,01)`; the latter reaches internal opcode
    `0x86` and sets gate bit 7. The controller record is at `0x00800430`.
  - [ ] Physically validate the exact DSDT gate sequence plus `D0/4E` on cold
    boot, warm boot, module reload, and resume.
  - [ ] Add safe readback for the queued request, current state, and gate state.
  - [ ] Restore hardware Fn-lock only after the activation sequence is verified
    on cold boot, warm boot, module reload, and resume.
  - [ ] Preserve `KEY_FN_ESC` strictly as an OSD notification; do not substitute
    software Fn-row rewriting for firmware Fn-lock.
- [ ] Keyboard-backlight raw PWM, logical policy, ramping, Fn+F4, boot, suspend,
  and resume.
  - [x] Map the public HID levels, PWM channel, target byte, and ramp routine.
  - [x] Prove why one-shot mailbox PWM writes are not stable.
  - [x] Generate the minimal raw-target firmware patch with exact
    hash/instruction guards.
  - [x] Compare official UX3407RA and UX3407QA revisions and confirm that
    header bytes `0x4a..0x4b` vary between revisions of the same model.
  - [ ] Derive the exact meaning/generation of `0x4a..0x4b`, or prove through
    boot-path evidence that modified code does not require regenerating it.
  - [ ] Establish a readback backup and board-level recovery path before any
    write.
  - [ ] Physically validate a non-destructive deployment method before enabling
    the patch.
  - [ ] Expose `0..255` through LED class only after the patched target path is
    physically validated.
- [ ] Fan control, tachometer telemetry, thermal thresholds, and fail-safe
  behavior.
- [ ] Power/platform profiles and profile hotkeys.
- [ ] Battery/charger state, charge limits, AC events, and battery safety.
- [ ] Lid, power button, wake sources, sleep/resume, and power sequencing.
- [ ] GPIO-controlled platform devices and indicators.
- [ ] Thermal sensors and any ambient/adaptive inputs.
- [ ] Device identity, board configuration, manufacturing data, and read-only
  diagnostics.
- [ ] Firmware update/recovery discovery and documentation only; no automatic
  flashing.
  - [x] Locate and reproducibly extract the exact `ECFlashApp` UEFI module.
  - [x] Reverse its `$ECDH$` parsing and raw-image identity check.
  - [x] Map flash range, erase/program granularity, flash-ID allow-list, retry
    limits, and verification behavior.
  - [x] Confirm that the updater itself provides neither backup nor rollback.
  - [x] Confirm that the official Windows install scripts only stage the UEFI
    firmware INF and provide no EC backup, checksum generation, or recovery.
  - [x] Build and CI-audit a write-incapable triple-pass 1 MiB UEFI readback
    application using the exact ASUS/Qualcomm transport.
  - [ ] Run the readback on the exact UX3407RA and preserve three identical
    dumps plus their hashes before investigating any deployment path.
  - [ ] Determine why a JEDEC capacity code for a larger device is accepted
    while only the first 256 KiB is updated.
  - [ ] Determine single-bank versus dual-bank layout and boot-time recovery
    behavior.
  - [ ] Identify a proven external recovery method for this exact board.

## 4. Linux interfaces

- [ ] Prefer standard subsystems: LED class, input, hwmon, thermal,
  `power_supply`, `platform_profile`, rfkill, and firmware attributes.
- [ ] Avoid parallel userspace daemons when a safe kernel interface exists.
- [ ] Define locking, serialization, timeouts, suspend/resume restoration, and
  firmware-ownership rules.
- [ ] Preserve firmware defaults on unsupported models and EC versions.
- [ ] Gate model-specific functions with exact board/EC quirks.

## 5. Safety and validation

- [ ] Provide a read-only inventory/probe mode.
- [ ] Require explicit opt-in for unknown writes; bound each test and restore
  prior state.
- [ ] Never brute-force flash, persistent storage, battery, thermal, or
  power-sequencing commands.
- [ ] Record endpoint, command, response, physical observation, kernel log, and
  recovery result.
- [ ] Add parser/mapping unit tests and confirmed-feature hardware smoke tests.
- [ ] Test cold boot, reboot, module reload, suspend/resume, AC/battery
  transitions, and recovery.

## Definition of done

- Every discoverable host-facing EC interface has an evidence trail and safety
  classification.
- Every safely supportable feature has a documented Linux ABI and regression
  coverage.
- Risky or unsupported functions are explicitly documented with evidence.
- Keyboard backlight exposes genuine hardware behavior; no fake 0–255 sysfs
  scaling.
