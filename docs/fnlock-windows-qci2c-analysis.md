# UX3407RA Windows Qualcomm I2C comparison

This note records the lower-controller evidence captured from the same
UX3407RA on which direct Windows `HidD_SetFeature()` physically switches the
F-row. It supplements `fnlock-reverse-engineering.md`.

## Captured Windows dependency drivers

The `QTEC0001` ACPI node depends on `PEP0`, `GIO0`, and `I2C9`. A read-only
Windows capture copied the exact bound drivers and metadata:

- PEP0 / `qcpep8380.sys`: SHA-256
  `d5529d8036424c2f697016be135ca169a38118e08d6f7e9935fa906e37b14969`
- GIO0 / `qcgpio.sys`: version `1.0.0.5346`, SHA-256
  `9ec5b4776ba9da6ae1ab2bd3840e9dc8d49ab0f54b475f1d27a6e175186c7f4f`
- I2C9 / `qci2c8380.sys`: version `1.0.0.5968`, signed-driver version
  `1.0.4281.8500`, SHA-256
  `d1f1f9a760b6b6d856f2e6cb1de673fcbc972f84a1ae9190ea9d1fe7b2ab3713`

I2C9 has MMIO `0x00a80000..0x00a83fff` and IRQ 832. Its service depends on
Microsoft `SpbCx`.

## GENI mode selection matches Linux

ARM64 disassembly of the captured `qci2c8380.sys` shows that it maps the GENI
MMIO resource and reads offset `0x64`, bit 0, to choose its GPI/DMA path versus
its non-GPI path. This is the same `GENI_IF_DISABLE_RO` / `FIFO_IF_DISABLE`
hardware decision used by Linux `i2c-qcom-geni`.

The Windows driver also programs the expected Qualcomm GENI register model,
including:

- `SE_I2C_TX_TRANS_LEN` at `+0x26c`
- `SE_I2C_RX_TRANS_LEN` at `+0x270`
- `SE_I2C_SCL_COUNTERS` at `+0x278`
- master command at `+0x600`

Its normal transfer setup uses the same broad command concepts visible in the
Linux driver: I2C write/read opcodes, slave address in the command parameter,
STOP stretching for multi-message operations, address bypass when requested,
and pre/timestamp delay flags.

This makes a wholesale FIFO-versus-GPI mismatch a weaker explanation for the
Fn-switch failure than it appeared before the driver capture.

## Verified SCL timing-table difference

The captured Windows driver's data section contains this 19.2 MHz table:

| bus rate | divider | high | low | cycle |
| --- | ---: | ---: | ---: | ---: |
| 100 kHz | 7 | 10 | 11 | 26 |
| 400 kHz | 2 | 5 | 12 | 24 |
| 1 MHz | 1 | 3 | 9 | 18 |

For the keyboard's 400 kHz bus this encodes
`SE_I2C_SCL_COUNTERS = 0x00503018`.

Linux 7.1.5 instead contains the newer 19.2 MHz table:

| bus rate | divider | high | low | cycle |
| --- | ---: | ---: | ---: | ---: |
| 100 kHz | 7 | 10 | 12 | 26 |
| 400 kHz | 2 | 5 | 11 | 22 |
| 1 MHz | 1 | 2 | 8 | 18 |

For 400 kHz that is `SE_I2C_SCL_COUNTERS = 0x00502c16`.

The Windows values are exactly the pre-2025 Linux `i2c-qcom-geni` 19.2 MHz
values. Upstream Linux changed them in commit
`a815975cbaeb4ab29f45312ef23be2871b2e8b82` after Qualcomm reported that the
old 400 kHz settings produced about 370 kHz and supplied updated programming
guidance.

This is the first verified Windows-versus-Linux difference below i2c-hid that
changes the electrical I2C clock waveform while the HID-over-I2C write bytes
remain identical.

## Next A/B gate

Do not patch the timing table blindly. Linux 7.1.5 chooses its 32 MHz table
only when `clk_get_rate(gi2c->se.clk) == 32 MHz`; otherwise it uses the 19.2
MHz table. The X1E80100 GCC exposes both 19.2 MHz and 32 MHz as rates for the
QUPv3 wrap1 S0 source.

Before changing the driver, verify the live UX3407RA `a80000` serial-engine
clock rate. If it is 19.2 MHz, a controller-scoped A/B that restores the
Windows/pre-2025 counters for this one serial engine is justified. Avoid a
global timing-table change because other GENI I2C controllers may be active on
the machine.
