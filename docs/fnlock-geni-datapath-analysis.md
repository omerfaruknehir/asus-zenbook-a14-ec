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

## Packing configuration matches exactly

Linux v7.1.5 configures the non-GPI I2C serial engine for 8-bit words packed
four bytes per FIFO word, MSB-to-LSB. The resulting register values are:

- `SE_GENI_TX_PACKING_CFG0 = 0x0007f8fe`
- `SE_GENI_TX_PACKING_CFG1 = 0x000ffefe`
- the same pair for RX
- `SE_GENI_BYTE_GRAN = 0`

Static disassembly of the exact captured Windows `qci2c8380.sys` loads the
literal constants `0x0007f8fe` and `0x000ffefe` and stores them to the same
TX and RX packing registers. Packing/byte-lane configuration therefore does not
explain the Windows-only Fn-lock behavior.

## Windows FIFO versus Linux SE-DMA A/B is disproven as sufficient

The captured Windows Qualcomm driver uses direct `SE_GENI_TX_FIFOn` writes in
its non-GPI transmit path and keeps `SE_GENI_DMA_MODE_EN` cleared. Linux v7.1.5
normally sends the 73-byte HID-over-I2C SET_FEATURE through internal SE-DMA when
FIFO is available because the transfer exceeds its 32-byte DMA threshold.

A controller-scoped Linux A/B was therefore performed that changed only writes
matching all of:

- physical controller `0x00a80000`
- slave address `0x15`
- write length exactly 73 bytes

The instrumented driver reported:

- `GENI_IF_DISABLE_RO = 0x00000000`
- `FIFO_IF_DISABLE = 0`
- `windows_fifo = 1`

so FIFO is genuinely available on this serial engine. Every boot-time and
user-triggered 73-byte write logged:

`A14 Fn-lock Windows FIFO A/B: addr=0x15 len=73 forced=FIFO (SE-DMA bypassed)`

Repeated Fn-lock state=0/state=1 feature writes still returned success and the
physical F-row still did not reverse. FIFO versus internal SE-DMA is therefore
not sufficient to explain the behavior.

## Windows HID stack has no ASUS filter on the target collection

The existing Windows transport capture shows the target `ACPI\\QTEC0001\\2`
stack uses the Microsoft `hidi2c` service with Microsoft `mshidkmdf` as its
upper filter. `HID\\QTEC0001&COL03...` has no upper or lower vendor filter.
`AsusConsumerDevFilter.sys` is attached to a separate `ACPI\\ASUH2024` HID
device, not the QTEC0001 vendor-defined collection used by Fn-switch.

Therefore the successful direct Windows `HidD_SetFeature()` result is not
currently explained by an ASUS filter intercepting the target request.

## Next software discriminator: first-contact enumeration state

Linux v7.1.5 performs an extra pre-enumeration address probe before reading the
HID descriptor:

`i2c_smbus_read_byte(0x15)`

Windows HIDI2C's documented enumeration begins directly with the HID descriptor
address write/read, followed by SET_POWER, RESET, reset-completion input read,
and report-descriptor retrieval. The previous Linux Windows-style reset A/B was
performed only after normal Linux enumeration had already happened, so it could
not disprove a persistent state difference caused by Linux's very first raw
address probe.

The next clean cold-boot A/B should therefore restore the stock GENI driver and
change only this one Linux behavior for the UX3407RA keyboard: skip the initial
raw `i2c_smbus_read_byte()` probe on controller `a80000.i2c`, address `0x15`.
Keep normal Linux timing, FIFO/SE-DMA policy, reset ordering and HID feature
formatting unchanged for this first test.
