# UX3407RA keyboard-backlight host protocol

## Validated hardware behavior

The QTEC keyboard HID collection is `0b05:0220`, report ID `0x5a`.
Physical keyboard-light control is performed by the feature report:

```text
5a ba c5 c4 LEVEL
```

Levels `0`, `1`, `2`, and `3` physically select off through maximum. Fn+F4
arrives from the controller as input usage `5a c7` and the host cycles the
level. The ACPI EC readback `ECCR(0xc9, 0xf0)` remained `0x00` across all four
physical HID levels, so that AML interface is not a live mirror of the QTEC
controller on the tested DT boot path.

## ASUSOptimization 2.1.75.0 static analysis

Analyzed file:

```text
ASUSOptimization/AsusOptimization.exe
size:    641584 bytes
format:  PE32+ AArch64
sha256:  2108a7b6b3ed677c003405bc05c8dcf2078d5f7cfa2792cae11ecbe411f791df
```

The `.rdata` string `SetFeature Keyboard light` is at RVA `0x83970`. Direct
ARM64 `ADRP`/`ADD` references at `0x27b14` and `0x27b5c` lead to the feature
dispatcher function at `0x25e78..0x27d28`.

The keyboard-light case reads a value, keeps its low nibble, and explicitly
clamps it to three:

```text
00027a28  ldr   w8, [sp, #32]
00027a2c  and   w24, w8, #0xf
00027a30  ubfx  w25, w8, #7, #1
00027a3c  cmp   w24, #3
00027a40  b.ls  0x27a4c
00027a44  mov   w24, #3
00027a48  mov   w9, #3
```

After its automatic-lighting conditions choose the final value in `w9`, the
same case constructs the report byte by byte:

```text
00027a74  mov   w8, #0x5a
00027a7c  strb  w8, [sp, #32]
00027a80  mov   w8, #0xba
00027a84  strb  w8, [sp, #33]
00027a88  mov   w8, #0xc5
00027a8c  strb  w8, [sp, #34]
00027a90  mov   w8, #0xc4
00027a94  strb  w8, [sp, #35]
00027a9c  strb  w9, [sp, #36]
```

The buffer is then passed to the imported HID feature setter. The executable
contains no literal `5a ba c5 c4` array because the compiler synthesizes it with
the stores above.

## Conclusion

ASUS's Windows host software does not request an 8-bit duty cycle from this
controller. It deliberately limits the public keyboard-light payload to
`0..3`. The DSDT table `{00,55,AA,FF}` therefore cannot be treated as evidence
that the active QTEC HID endpoint accepts arbitrary 8-bit brightness.

An internal PWM engine can still have finer electrical resolution, but access
would require an undocumented HID command or keyboard-MCU firmware changes.
The bounded `raw-sequence` probe resets to known level zero before testing
`04`, `10`, `40`, `7f`, `80`, `c0`, `fe`, and `ff`. These values distinguish
ignored, clamped, low-two-bit-masked, and genuinely raw-duty behavior without
performing a blind 256-value vendor-command sweep.

On UX3407RA, every tested value above three left the physical LEDs off after a
proven level-zero baseline; restoring value one immediately lit the keyboard.
That result rules out clamping, low-two-bit masking, and direct 8-bit duty-cycle
semantics for the `5a ba c5 c4` command.  The controller treats values above
three as invalid/off.

## Endpoint audit

The working `0..3` command and Fn+F4 input usage `5a c7` are both observed on
the same Linux node, 0B05:0220.  ASUSOptimization also sends keyboard-light and
Fn-switch feature reports through the same QTEC HID handle, so that endpoint is
not a mistaken NumberPad interface.

The separate `ACPI\\ASUH2024` virtual HID stack is backed by ASUS NumberPad
keyboard/consumer filter drivers.  Its captured binaries contain neither the
QTEC session prefix nor the keyboard-light command.  The QTEC dependency stack
contains Microsoft's generic I2C HID miniport and Qualcomm I2C/GPIO/PEP bus
drivers, with no additional ASUS keyboard-light driver or firmware-update
side channel.

The A14 also exposes a separate ASUS I2C HID device, 0B05:4543.  Its live
descriptor has Feature report 0x06 with 19 wire bytes and Feature report 0x5a
with 17 wire bytes.  Both reports read as an all-zero report and remain
byte-for-byte unchanged while the proven 0B05:0220 controller cycles through
physical levels 0, 1, 2, and 3.  Therefore 4543 is not a readable brightness
mirror.

A descriptor-correct, explicitly acknowledged write test then sent
`5a ba c5 c4 VALUE` to 4543 without initialization.  Values `00`, `01`, `02`,
`03`, `04`, `10`, `40`, `7f`, `80`, `c0`, `fe`, and `ff` all produced
no physical light after the proven 0220 path first selected level zero.  Both
4543 Feature reports remained all zero, while restoring level one through 0220
lit the keyboard immediately.  This rules out an uninitialized 4543 backlight
transport; a session-gated transport remains untested.

A second descriptor-correct test sent the ASUS identity handshake and feature
configuration query before trying values `00..03`.  All four candidates again
left the physical LEDs off and both Feature reports remained zero.  The final
visible level-one restoration came from the proven 0220 sysfs write performed
after the attempted 4543 restoration; it is not evidence that the 4543 restore
worked.  This rules out both uninitialized and basic-session-initialized 4543
transport variants for the known keyboard-light command.

The `d0 8f 01` and `d0 85 ff` packets do exist in G-Helper's generic ProArt
initialization path.  However, its current `AsusHid.WriteInput()` implementation
filters devices through an explicit PID allow-list that contains neither A14
PID 0220 nor 4543.  Those packets therefore are not evidence for either live
A14 endpoint and must not be presented as a verified A14 initialization
sequence.

A different undocumented report or firmware-internal control path remains
possible.  It must be identified from the complete HID descriptor or firmware,
not by redirecting this proven QTEC command to ASUH2024.
