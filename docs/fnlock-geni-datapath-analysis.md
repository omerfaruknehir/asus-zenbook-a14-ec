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

## Strong remaining data-path difference: FIFO versus SE-DMA

The captured Windows Qualcomm driver has two controller families of operation:
FIFO and GPI. In the non-GPI path, static disassembly shows direct writes to
`SE_GENI_TX_FIFOn` and writes of zero to `SE_GENI_DMA_MODE_EN`; no normal
non-GPI SE-DMA transmit path has been identified.

Linux v7.1.5 behaves differently when the hardware FIFO interface is available:
`geni_i2c_tx_one_msg()` calls `i2c_get_dma_safe_msg_buf(msg, 32)`. A 73-byte
HID-over-I2C SET_FEATURE write therefore normally qualifies for Linux's internal
SE-DMA path instead of the FIFO path. If the hardware reports FIFO disabled,
Linux instead selects GPI DMA, and this FIFO-vs-SE-DMA hypothesis is not
applicable.

The X1E80100 DT supplies GPI DMA channels for the `0x00a80000` serial engine,
but the Linux driver chooses GPI only when `GENI_IF_DISABLE_RO & FIFO_IF_DISABLE`
is set. The next discriminator is therefore the live value of register offset
`0x64`, bit 0, on this machine.

If bit 0 is clear, the next clean A/B is to keep stock Linux timing and command
parameters while forcing only writes on controller `0x00a80000`, slave `0x15`,
length 73 through GENI FIFO rather than Linux SE-DMA. If bit 0 is set, discard
this hypothesis and continue with GPI descriptor/TRE semantics.
