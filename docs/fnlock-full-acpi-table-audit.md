# UX3407RA full ACPI table-set audit for Fn-lock

Source archive: `A14ACPI.tar.xz`

- archive SHA-256: `df7838e0753b04aaab7576ecfffbe2b225d4586c505c76b1ac83015246635901`
- dumped directly from firmware memory before `ExitBootServices`
- RSDP/XSDT/table checksums reported valid by the capture manifest

This note records only findings relevant to the QTEC0001 keyboard / Fn-lock investigation.

## XSDT completeness: no SSDTs

The XSDT contains 16 entries:

1. FACP
2. UEFI
3. FPDT
4. CSRT
5. DBG2
6. GTDT
7. IORT
8. APIC
9. MCFG
10. PPTT
11. SDEV
12. SPCR
13. TPM2
14. MSDM
15. FPDT
16. BGRT

There are **no SSDT entries**. The only AML namespace table is the DSDT referenced by the FADT.

The DSDT is exactly the one already captured during the earlier Windows ACPI investigation:

- length: `271855`
- SHA-256: `281bbf235f27a554b72af4e99d018b27f4f9ceeabb34be1a3c06f59f0443a134`
- firmware address: `0x00000000D4783018`

Therefore there is no hidden SSDT that augments `ECKB`, `I2C9`, `GIO0`, or `PEP0`. The earlier DSDT-only namespace analysis covered the complete AML namespace supplied by this firmware.

## ECKB remains entirely described by the DSDT

The raw AML around `\\_SB.ECKB` confirms:

- `_HID = "QTEC0001"`
- `_CID = "PNP0C50"`
- `_UID = 2`
- `_DEP = { \\_SB.PEP0, \\_SB.GIO0, \\_SB.I2C9 }`
- I2C SerialBus connection to `\\_SB.I2C9`, slave address `0x15`
- GPIO interrupt sourced from `\\_SB.GIO0`, ACPI pin value `0x0180`
- standard HID-over-I2C `_DSM`

No separate SSDT can add `_PS0`, `_PS3`, `_PR0`, `_PR3`, a reset GPIO, or another ECKB-specific power method because no SSDTs exist in the table set.

## I2C9 controller resource confirmation

The DSDT `\\_SB.I2C9` object is `QCOM0C10`, UID 9, dependent on `PEP0`.

Its `_CRS` contains:

- MMIO base `0x00A80000`
- MMIO length `0x4000`
- GSI/IRQ `832` (`0x340`)

This matches the previously captured Windows PnP resource assignment and the Linux `a80000.i2c` GENI controller.

## SDEV does not cover the keyboard or I2C9

The complete SDEV table has one namespace-device secure-device entry only:

- `\\_SB.SISP`

There is no `ECKB`, `I2C9`, `GIO0`, or QTEC0001 entry. Therefore the Fn-lock difference is not explained by an ACPI SDEV secure-device handoff for the keyboard or its I2C controller.

## IORT does not add a QTEC/I2C9 named component

The IORT contains 30 nodes. Its named-component nodes cover devices such as GPU, USB, UFS, audio/DSP and other DMA-capable blocks, but there is no named-component node for `\\_SB.ECKB` or `\\_SB.I2C9`.

A raw byte sequence equal to `0x00A80000` occurs inside the SMMUv3 node area, but it is not an I2C9 named-component base-address declaration. It must not be treated as evidence that IORT configures the keyboard GENI controller.

## CSRT observation and caution

The firmware supplies a large Qualcomm `CSRT` (~47 KiB) with two `QCOM` resource groups and substantial vendor-specific shared data. A raw byte sequence equal to `0x00A80000` appears inside that vendor data.

However:

- the occurrence is not aligned as a normal 32-bit controller-base field in the visible blob;
- the other known QCOM0C10 I2C controller bases (`0x00B80000`, `0x00B84000`, `0x00B8C000`, `0x00B90000`, `0x00B94000`, `0x00B9C000`) do not appear as matching 32-bit values;
- CSRT shared data is vendor-defined.

Therefore this occurrence is **not currently evidence** that the CSRT contains I2C9/qci2c configuration. Do not build a Linux quirk around it without decoding the Qualcomm CSRT blob or finding a corresponding Windows consumer.

## FADT platform model

The FADT confirms:

- preferred power profile: Mobile
- `HW_REDUCED_ACPI = 1`
- `LOW_POWER_S0_IDLE_CAPABLE = 1`
- PSCI compliant
- PSCI conduit: SMC, not HVC

This is consistent with a Qualcomm/PEP-heavy Windows platform-power architecture, but it does not identify an ECKB-specific Fn-lock prerequisite.

## Fn-lock impact

The full ACPI table set closes several remaining namespace hypotheses:

1. No hidden SSDT changes ECKB/I2C9 initialization.
2. No ACPI SDEV secure-device entry targets the keyboard/controller.
3. No IORT named-component mapping exists for ECKB/I2C9.
4. The exact I2C9 MMIO/IRQ resources remain `0x00A80000/0x4000`, IRQ 832.

The next high-value evidence remains live Windows qci2c/controller behavior around the already-proven successful direct `HidD_SetFeature()` operation, rather than another speculative ACPI or Linux enumeration modification.
