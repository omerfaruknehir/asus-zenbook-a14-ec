# UX3407RA Fn-lock GENI data-path comparison

This note continues `fnlock-reverse-engineering.md` below the HID-over-I2C
packet layer. It records only differences reproduced on the UX3407RA or
statically verified in the exact captured Windows binaries.

## Windows timing A/B is disproven as sufficient

The captured Windows `qci2c8380.sys` 19.2-MHz / nominal-400-kHz timing tuple is:

- divider 2
- high 5
- low 12
- cycle 24
- `SE_I2C_SCL_COUNTERS = 0x00503018`

Linux v7.1.5 normally uses:

- divider 2
- high 5
- low 11
- cycle 22
- `SE_I2C_SCL_COUNTERS = 0x00502c16`

A controller-scoped Linux A/B was performed on physical GENI controller
`0x00a80000`. The instrumented driver reported a live SE source clock of exactly
19.2 MHz and a requested bus rate of 400 kHz, then successfully replaced the
Linux counters with the exact captured Windows value `0x00503018` before the
keyboard enumerated. The previously disproven extra Windows-style HIDI2C reset
was disabled in the HID driver during this boot.

Fn-lock SET_FEATURE still returned success and logged state=1, but the physical
F-row did not reverse. Therefore the Windows-vs-Linux SCL counter difference is
real but not sufficient to explain the Fn-lock behavior.

## GENI master-command semantics match for a standalone write

Static ARM64 disassembly of the captured `qci2c8380.sys` shows its normalized
transfer flags distinguish direction, whether an address phase is required,
and whether the controller should hold the bus for a continuation.

For a normal standalone SPB write, the driver reaches the write form with:

- address phase enabled
- final STOP/release enabled
- write direction
- no pre-command delay

For slave address `0x15`, the resulting GENI command is equivalent to:

- opcode `I2C_WRITE = 1`
- params `0x15 << 9`
- `STOP_STRETCH = 0`
- `BYPASS_ADDR_PHASE = 0`

Thus `SE_GENI_M_CMD0` is effectively `0x08002a00` for the standalone transfer.
Linux's single-message `i2c-qcom-geni` write constructs the same opcode/address
and leaves `STOP_STRETCH` clear. START/address/STOP command parameters therefore
do not currently provide a concrete Windows-only behavior to copy.

## FIFO versus SE-DMA A/B is disproven as sufficient

Static disassembly of the captured Windows Qualcomm driver shows that its
non-GPI transmit path writes through `SE_GENI_TX_FIFOn` and keeps
`SE_GENI_DMA_MODE_EN` cleared. Linux v7.1.5 normally chooses internal SE-DMA
for non-GPI transfers at least 32 bytes long, so the 73-byte Fn-lock
SET_FEATURE normally takes a different Linux data path.

The live UX3407RA controller reported:

- `GENI_IF_DISABLE_RO = 0x00000000`
- `FIFO_IF_DISABLE = 0`

so FIFO is genuinely available. A controller-scoped A/B then forced every
73-byte write to address `0x15` on controller `0x00a80000` through GENI FIFO,
bypassing Linux SE-DMA. The driver logged the forced FIFO path for the boot-time
ASUS feature writes and for repeated user-triggered Fn-lock state 0/1 writes.

Physical F-row behavior still did not reverse. Therefore FIFO versus internal
SE-DMA is not sufficient to explain the Windows-versus-Linux Fn-lock behavior.

## GENI FIFO packing matches Windows

Linux configures I2C FIFO packing with 8-bit words, four bytes per FIFO entry,
MSB-to-LSB ordering. The resulting values are:

- `TX_PACKING_CFG0 = 0x0007f8fe`
- `TX_PACKING_CFG1 = 0x000ffefe`
- `RX_PACKING_CFG0 = 0x0007f8fe`
- `RX_PACKING_CFG1 = 0x000ffefe`
- `BYTE_GRAN = 0`

The captured Windows `qci2c8380.sys` loads the same literal values
`0x0007f8fe` and `0x000ffefe` and writes them to the corresponding TX/RX
packing registers. Packing therefore does not provide a concrete remaining
Windows-only behavior.

## No ASUS kernel filter on the successful Windows target stack

The successful direct Windows `HidD_SetFeature()` test targets the
`QTEC0001` Col03 HID collection. The captured target stack consists of the
standard Microsoft HID-over-I2C/HIDClass path and does not contain an ASUS
upper/lower filter on this collection. `AsusConsumerDevice.sys` belongs to a
different ASUS HID device. This makes a hidden ASUS kernel-filter side effect
on the successful QTEC0001 feature request unlikely.

## Linux initial raw address-probe A/B: Fn-lock negative

Linux v7.1.5 normally calls `i2c_hid_probe_address()` before fetching the HID
descriptor. That helper performs a raw `i2c_smbus_read_byte()` against the
I2C-HID target before normal descriptor/power/reset enumeration.

A cold-boot A/B removed only that initial raw address probe for physical
controller `a80000.i2c`, address `0x15`, while restoring the stock GENI driver,
stock Linux SCL timing, stock Linux FIFO/SE-DMA policy, and stock Linux
POWER_ON/RESET sequencing.

The instrumented module proved the A/B was active on the cold boot:

- `loaded_a14_skip_initial_probe=Y`
- log: `skipping Linux raw initial i2c_smbus_read_byte() probe on a80000.i2c addr=0x15`
- no old GENI timing/FIFO experiment remained installed for the boot

Fn-lock still did not physically reverse the F-row. Therefore Linux's extra raw
pre-descriptor address probe is not sufficient to explain the Fn-lock failure.

An initial report that keyboard backlight had stopped on this boot was corrected
by the tester immediately afterward: the keyboard backlight was working. Do not
record or reuse a keyboard-backlight regression from this A/B.

## Next direction: measure Windows controller state before more Linux A/Bs

Do not stack another speculative Linux transport change. The remaining useful
gap is the live state of the Qualcomm GENI controller on Windows during the
known-working direct `HidD_SetFeature()` operation.

Static reversing shows that Windows `qci2c8380.sys` and Linux initialize several
common GENI control/interrupt registers differently even though the per-transfer
I2C command, packing, length, address, timing A/B, and FIFO data path have now
been compared. The next step is to capture Windows qci2c Inflight Recorder/WPP
state around the successful state=0/state=1 direct-HID test and, if that does
not expose the needed register values, obtain a read-only live MMIO snapshot of
controller `0x00a80000` under Windows. Only then should another Linux controller
A/B be designed.
