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

The original driver also sent `5a d0 8f 01`. BIOS 312 EC disassembly proves that
its handler sets bit 7, clears bit 6 in `0x008012a0`, and resets an associated
mode/counter. Further callers show a separate timed state machine, not a proven
Fn-switch gate. Restoring it before `D0/4E` in package 0.5.15 did not change the
physical row, so it is disproven as a sufficient prerequisite.

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
fix hypothesis. Normal builds keep this reinitialization disabled; it remains
available only as an explicit diagnostic module parameter.

## Windows ACPI ECKB versus Linux Device Tree

A Windows capture retrieved the raw 271855-byte DSDT and the evaluated PnP
resources for `ACPI\QTEC0001\2`. The firmware object is `\\_SB.ECKB`:

- `_HID = QTEC0001`
- `_CID = PNP0C50`
- `_UID = 2`
- `_DEP = { \\_SB.PEP0, \\_SB.GIO0, \\_SB.I2C9 }`
- `_CRS` describes an I2C connection at slave address `0x15`, 400000 Hz, on
  `\\_SB.I2C9`, plus a level-low, pull-up, wake-capable GPIO interrupt sourced
  from `\\_SB.GIO0`.
- `_DSM` is the standard Microsoft HID-over-I2C DSM and function 1 supplies HID
  descriptor address `0x1`.

`ECKB` itself contains no `_PS0`, `_PS3`, `_PR0`, `_PR3`, reset GPIO, explicit
supply resource, or vendor-specific child power method. Therefore Linux's
missing `vdd`/`vddl` supply properties and dummy-regulator messages remain a DT
completeness observation, but the Windows ACPI child does not expose an
ECKB-specific rail/reset sequence that can simply be copied as an Fn-lock fix.

The three Windows dependency providers evaluate as:

- `PEP0`: `QCOM0C17`, the Qualcomm platform/PEP dependency
- `GIO0`: `QCOM0C0C`, the Qualcomm GPIO/system-manager dependency
- `I2C9`: `QCOM0C10`, the Qualcomm I2C controller dependency

Windows `I2C9` is the same physical serial engine Linux describes at MMIO
`0x00a80000`. Linux names the DT child `i2c8`; the index/name difference is not
a hardware difference. The Linux A14 DT also configures that controller for
400000 Hz and the keyboard at address `0x15`, so bus speed, slave address and
controller selection are ruled out.

The Linux keyboard node describes GPIO67 as level-low with a pull-up and as a
wakeup source, which is semantically consistent with the Windows ECKB GPIO
resource. The ACPI GPIO pin namespace still needs a proven mapping before its
raw pin value is equated numerically to Linux GPIO67.

The remaining high-value comparison is below i2c-hid: Windows Qualcomm
PEP/GPIO/I2C platform-driver behavior and the actual controller transaction
semantics versus Linux `i2c-qcom-geni` (including FIFO/SE-DMA/GPI mode, runtime
power sequencing and final bus framing). Do not guess or toggle unidentified
regulator/reset GPIOs.

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

## Current Linux status after 0.5.15 hardware test

Release 0.5.14's software report inversion was not firmware Fn-lock. Package
0.5.15 removed that emulation but its `D0/8F` prerequisite theory also failed
physical testing. Fn+F12 did not open the recovered bit-7 service gate either,
which proves that internal protocol opcode `0x86` is not the physical key usage
despite the numeric collision.

The driver must preserve `KEY_FN_ESC` solely for OSD and describe `D0/4E` as a
submitted request until the EC queue and service result can be acknowledged.

## BIOS 312 EC gate sequence

The full BIOS 312 DSDT contains a separate host-enable branch that was missing
from the earlier HID-only reconstruction. Under the EC mutex it clears the
associated mode and enables the Fn-switch service with:

```text
ECCW(0x02, 0x87, 0x00)
ECCW(0x02, 0x86, 0x01)
```

The disable branch sends `ECCW(0x02,0x86,0x00)` and then
`ECCW(0x02,0x87,0x05)`. This matches the EC firmware independently: internal
opcode `0x86` with a nonzero argument calls the ready-gate setter used by the
queued `D0/4E` service, while zero clears it. Package 0.5.16 submits the exact
enable sequence before the existing Windows-compatible `D0/4E` report. This is
a physical-validation candidate, not a success claim.
