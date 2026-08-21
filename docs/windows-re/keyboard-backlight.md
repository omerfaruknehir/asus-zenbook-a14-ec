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
