# ASUS Zenbook A14 native fan / thermal profiles

Target: ASUS Zenbook A14 UX3407RA / UX3407QA family.

This note records the profile mechanism recovered from the machine's ASUS
Windows control package and UX3407RA DSDT.  It is intentionally separate from
manual PWM control: the Windows normal profiles are firmware thermal policies,
not fixed fan duties.

## Result

The A14 uses ASUS WMI device `0x00110019` for its four native fan/thermal
profiles.

The classic ASUS `0x00110018` FanOverboost interface is probed by generic
`AsusOptimization.exe` code, but it is not implemented by this UX3407RA DSDT:
its `DEVS` dispatcher falls through to the unsupported return value for that
ID.  Do not use `0x00110018` as the A14 profile transport.

`0x00110013` is also not a profile setter.  Its DSDT path calls `I2C6.SFAN`,
which reads fan telemetry/status from the EC.

## `0x00110019` modes

The DSDT `DEVS(0x00110019, mode)` branch has four explicit cases:

| mode | DSDT table | WEBC payload | Linux local name |
|---:|---|---:|---|
| 0 | `TZCN` | `0x01` | `balanced` / Normal / Standard |
| 1 | `TZCQ` | `0x02` | `quiet` / Whisper |
| 2 | `TZCT` | `0x04` | `performance` / Turbo |
| 3 | `TZCF` | `0x10` | `full-speed` |

The Normal/Quiet/Turbo/Full-speed interpretation is supported by the DSDT
symbol names and the four-mode Windows control flow.  Linux keeps stable local
names (`balanced`, `quiet`, `performance`, `full-speed`).

After selecting a mode, firmware invokes its `WEBC` helper with command
`0x11`, updates the host thermal policy through the Windows PEP path, and
records the selected mode in the DSDT `FANF` object.

Linux deliberately reproduces only the EC firmware command.  It does not try
to reproduce the Windows `PEP0.THTZ` host thermal-table operation; Linux owns
its thermal-zone policy independently.

## EC transport

The existing Linux byte transport already matches the DSDT primitives:

- `ECRB(major, minor)` -> select `{ 0x10, major, minor }`, then read through
  opcode `0x11`.
- `ECWB(major, minor, value)` -> select `{ 0x10, major, minor }`, then write
  `{ 0x11, value }`.

No new raw-I/O mechanism is required.

For the one-byte fan profile operation, DSDT `WEBC(0x11, 1, payload)` is:

1. Poll `ECRB(0xc9, 0x6f)` until it is zero.
2. The DSDT sleeps **100 ms** between polls and allows 200 attempts.
3. Write the profile payload to `ECWB(0xc9, 0x40, payload)`.
4. Set the start bit with `ECWB(0xc9, 0x6f, status | 0x80)`.
5. Submit command `0x11` with `ECWB(0xc9, 0x6e, 0x11)`.

The DSDT timeout path rereads status, latches bit `0x40`, and returns failure.
The Linux helper mirrors that firmware behavior and returns `-ETIMEDOUT` to its
caller.

A previous transform accidentally treated the DSDT `Sleep(100)` as
100-200 microseconds.  That reduced the intended ~20-second worst-case wait to
roughly 20-40 ms and could enter the firmware timeout path far too early.  The
composition transform now uses a 100-110 ms poll delay and is upgrade-aware for
already-composed trees.

## Native policy versus manual PWM

These controls must remain separate:

- Native `balanced`, `quiet`, `performance`, and `full-speed` use
  `0x00110019` / `WEBC(0x11)` and leave the firmware in charge of the fan
  curve.
- HWMON manual PWM uses the separately recovered low-level EC fan
  AUTO/MANUAL and PWM registers and is represented as `custom` internally.

Returning the low-level fan controller to AUTO does **not** itself imply a
native Normal profile command.  Policy transitions issue the native command
explicitly.  This matters during shutdown, suspend, rollback, and manual-mode
failure handling: those paths can safely return fan ownership to firmware
without silently changing the selected thermal profile.

When HWMON explicitly requests automatic policy (`pwm_enable=2`) or the manual
safety fallback fires, the driver intentionally establishes native Normal /
`balanced` after releasing manual PWM ownership.

## `platform_profile` projection

The local four-mode interface is always available through the driver's own
profile sysfs attribute.  On kernels with `PLATFORM_PROFILE_MAX_POWER`, the
standard projection is:

- `quiet` -> `PLATFORM_PROFILE_QUIET`
- `balanced` -> `PLATFORM_PROFILE_BALANCED`
- `performance` -> `PLATFORM_PROFILE_PERFORMANCE`
- `full-speed` -> `PLATFORM_PROFILE_MAX_POWER`
- manual PWM -> `PLATFORM_PROFILE_CUSTOM` when reported internally

On older platform-profile ABIs, `full-speed` remains available locally even if
it must project onto the closest standard profile.

## Composition rules

`make prepare` reruns the A14 transforms every time.  The transforms are
idempotent and upgrade-aware; this is required because they compose the root
out-of-tree driver in place and an older working tree may already contain a
previous protocol revision.

Do not replace this native profile path with a synthetic CPU-frequency cap or
fixed PWM value.  Those can be separate Linux/manual controls, but they are not
the Windows A14 native profile mechanism.
