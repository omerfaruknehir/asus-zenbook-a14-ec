# UX3407RA Fn-lock reverse engineering

This document records only behavior that has been reproduced or statically
verified on the UX3407RA. It exists to keep failed experiments from being
reintroduced as assumptions.

## Proven Windows target

ASUSOptimization.exe 2.1.75.0 selects the HID top-level collection with:

- VID/PID `0b05:0220`
- Usage Page `ff31`
- Usage `0076`
- FeatureReportByteLength `64`
- report ID `5a`

On the tested Windows installation the path is the `QTEC0001` Col03
collection. With ASUSOptimization stopped, a direct `HidD_SetFeature()` call
using a complete 64-byte buffer switches the physical F-row mode:

```
5a d0 4e 00 00 ...   # ASUS/media actions primary
5a d0 4e 01 00 ...   # ordinary F1..F12 primary
```

This is a firmware/hardware row-mode switch. It is not software key inversion.

A cold-boot A/B also proved that ASUSOptimization is not a prerequisite. The
service was disabled before reboot and had never run during that Windows boot,
yet the same direct `HidD_SetFeature()` state=0/state=1 writes still reversed
the physical F-row. Any remaining Linux difference therefore exists below or
outside ASUSOptimization's per-device startup path.

## ASUSOptimization startup path

Static ARM64 disassembly of the exact 2.1.75.0 binary shows that the per-device
startup path:

1. GETs feature report `5a`.
2. Sends `5a + "ASUS Tech.Inc."` only when the returned report is not one of
   the known ASUS feature families.
3. Sends configuration `5a 05 20 31 00 08`, then GETs the same report, with
   up to four attempts.
4. The tested machine returns capability bytes `01 20 01` at offsets 6..8.
5. The N-key-rollover startup transaction is skipped for that response.
6. If the HKLM `ArrowKeySwitch` value is 1, it sends `5a c2 4b 01`.
7. It reads HKLM `FnSwitch` and sends `5a d0 4e <state>`.

The settings key used by ASUSOptimization is:

`SOFTWARE\ASUS\ASUS System Control Interface\AsusOptimization\ASUS Keyboard Hotkeys`

The model-specific battery command in the same function is restricted by the
binary to UX8406/UX8407/HT7407/UX8200-class model prefixes. It is not part of
the UX3407RA Fn-switch path.

The old `5a d0 8f 01` command is OOBE-complete behavior, not Fn-lock
initialization, and must not be used as an Fn-lock prerequisite.

## Exact Windows HIDI2C SetFeature transport

The exact Windows `hidi2c.sys` used by the successful test is:

- version `10.0.28000.2546`
- SHA-256 `d84f9b04465d45a198314a9c157acebfbf8f1eb4e49199fc0864467ee027d05d`
- public symbols recovered from Microsoft's matching PDB

Its public `HidSetReport` function constructs the report-ID-5a FEATURE command
as:

```
command register
3f 03 5a

data register
42 00
5a d0 4e <state> 00 ...   # complete 64-byte feature report
```

`0x42` is the 66-byte HID-over-I2C data-block length: 2 length bytes plus the
full 64-byte numbered report.

The Windows `SpbWriteWrite` helper supplies one SPB transfer whose buffer is a
four-fragment scatter/gather list: command register, encoded command, data
register, report data. Thus the wire payload is one write transfer; splitting
those four fragments in memory does not create a hidden second ASUS command.

## Exact Linux 7.1.5 submitted I2C-HID packet

Dynamic debug on the real UX3407RA captured the complete `send_buf` passed by
Linux 7.1.5 `i2c_hid_xfer()` to `i2c_transfer()` for an Fn+Esc transition to
state=1:

```
05 00
3f 03 5a
06 00
42 00
5a d0 4e 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00
```

This is a 73-byte write buffer:

- `05 00`: command register `0x0005`
- `3f 03 5a`: FEATURE SET_REPORT with extended report ID `0x5a`
- `06 00`: data register `0x0006`
- `42 00`: 66-byte data block
- `5a d0 4e 01` plus 60 zeros: complete 64-byte feature report

The Linux upper transport packet therefore matches the working Windows command
shape exactly. The accepted-but-ineffective Linux tests are not explained by a
different report length, report-ID encoding, HID collection, custom upper HID
driver, hidden ASUS payload in `HidD_SetFeature`, command register, data
register, or i2c-hid FEATURE formatting.

This capture proves the bytes submitted to the Linux I2C adapter. It does not,
by itself, prove that the Qualcomm controller emits identical electrical bus
framing/timing to the Windows SPB controller path.

## Windows-style HIDI2C reset A/B: disproven as sufficient

The exact Windows HIDI2C public-symbol path is:

- `OnD0Entry` -> `HidInitialize`
- initial `HidInitialize` performs `SET_POWER(ON)`
- `OnPostInterruptsEnabled` then calls `HidReset`
- `HidReset` sends RESET and waits up to 4 seconds for reset completion
- Windows `HidReset` does **not** issue a second `SET_POWER(ON)` after RESET

Linux 7.1.5 i2c-hid's normal hardware-reset path performs POWER_ON -> RESET and
then `i2c_hid_finish_hwreset()` issues another POWER_ON after reset unless the
`NO_WAKEUP_AFTER_RESET` quirk is set.

This was tested directly on Linux with a runtime Windows-style sequence:
POWER_ON -> RESET -> wait for FEATURE GET readiness, with no post-reset
POWER_ON. The device became ready after 110 ms total, returned the expected
ASUS capability bytes `01 20 01`, accepted Fn-switch state 0/1 writes, and the
driver reported both state transitions. The physical F-row did **not** change.

Therefore the post-reset POWER_ON difference is real but is not sufficient to
explain Windows-versus-Linux Fn-switch behavior. It must not remain the leading
fix hypothesis.

## Platform-description difference now under investigation

Windows enumerates this physical unit as ACPI `QTEC0001` (`\\_SB.ECKB`) through
Microsoft `hidi2c.inf`. Linux 7.1.5 enumerates the same `0b05:0220` endpoint as
a Device Tree `hid-over-i2c` node at address `0x15`.

The Linux A14 DT keyboard node provides the I2C address, HID descriptor address,
GPIO67 interrupt/pinctrl and wakeup-source, but no `vdd-supply`, `vddl-supply`,
`reset-gpios`, post-power delay or post-reset delay. Consequently `i2c_hid_of`
reports dummy `vdd`/`vddl` regulators.

The next safe comparison is the Windows ACPI resource/power description of
`QTEC0001/ECKB` versus this sparse DT node, plus lower-controller transaction
semantics if the ACPI resources do not expose a missing lifecycle dependency.
Do not guess or toggle unidentified regulator/reset GPIOs.

## Disproven on Linux

The following were accepted by the device but did not physically change the
F-row and must not be presented as fixes:

- bare full-length `5a d0 4e 00/01`
- ASUS initial string followed by Fn-switch
- full init/config GET/config SET/Fn-switch sequence on one hidraw handle
- DSDT `DEVS(0x00100023)` EC stage plus HID switch
- the same feature sequence while bound to `hid-generic`
- an added QTEC-style post-HID POWER_ON followed by ASUS startup/Fn-switch
- Windows-style POWER_ON -> RESET -> ready wait with no post-reset POWER_ON,
  followed by ASUS startup/Fn-switch

The exact Linux descriptor also confirms one `ff31:0076` top-level collection
with 64-byte feature report `5a`.
