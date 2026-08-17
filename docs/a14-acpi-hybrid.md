# ASUS Zenbook A14 ACPI + Device Tree hybrid experiment

This document describes the deliberately conservative first stage of bringing the
UX3407RA Windows ACPI namespace into Linux without replacing the known-working
Qualcomm Device Tree boot path.

## Why this is not `acpi=force`

On arm64, normal Linux boot treats ACPI and Device Tree as competing platform
firmware descriptions. Enabling ACPI globally changes CPU/PSCI, interrupt,
PCI, power, clock/regulator and device-enumeration decisions. That is not an
acceptable first experiment on the UX3407RA because the current X1E80100 DT is
already the working source for boot-critical Qualcomm hardware.

The experimental command line is instead:

```text
acpi=hybrid
```

The stage-0 implementation intentionally leaves the kernel-global
`acpi_disabled` value set. Existing ARM64 and Qualcomm code therefore continues
to select its normal DT paths without needing invasive per-subsystem patches.
A separate `acpi_dt_hybrid` state enables a restricted ACPICA sidecar only.

## Stage 0 safety model

Stage 0 enables:

- ACPI root-table discovery and checksum validation;
- FADT sanity validation;
- ACPICA subsystem and AML namespace loading;
- restricted interpreter startup;
- `/sys/firmware/acpi` table exposure;
- read-only namespace existence checks for the known UX3407RA objects:
  - `\\_SB.I2C9`
  - `\\_SB.ECKB`
  - `\\_SB.PEP0`
  - `\\_SB.GIO0`

Stage 0 explicitly does **not** enable:

- ACPI as the platform/boot authority;
- ACPI CPU enumeration or topology;
- ACPI PSCI selection;
- ACPI GIC/IRQ routing or `\\_PIC`;
- SCI/GPE/fixed-event handling;
- ACPI global-lock handling;
- ACPI PCI root enumeration;
- ACPI regulator/full-constraints ownership;
- ACPI sleep/wakeup ownership;
- ECDT/DSDT EC probing;
- ACPI platform/I2C device creation;
- the generic ACPI device scan;
- device `_STA`/`_INI` initialization;
- address-space `_REG` initialization;
- automatic `_OSC` negotiation.

The ACPICA calls use the corresponding suppression flags:

```text
ACPI_NO_ACPI_ENABLE
ACPI_NO_HARDWARE_INIT
ACPI_NO_EVENT_INIT
ACPI_NO_HANDLER_INIT
ACPI_NO_DEVICE_INIT
ACPI_NO_ADDRESS_SPACE_INIT
```

This is a namespace/interpreter foundation, not yet generic Qualcomm ACPI
hardware support.

## Firmware evidence for this machine

The complete UX3407RA firmware table dump contains no SSDTs. The relevant
keyboard path is fully described by the DSDT:

```text
\\_SB.ECKB
  _HID = QTEC0001
  _CID = PNP0C50
  _UID = 2
  _DEP = { \\_SB.PEP0, \\_SB.GIO0, \\_SB.I2C9 }

\\_SB.I2C9
  _HID = QCOM0C10
  _UID = 9
  MMIO = 0x00a80000, length 0x4000
```

`ECKB` is HID-over-I2C slave `0x15` on `I2C9`.

The captured DSDT SHA-256 is:

```text
281bbf235f27a554b72af4e99d018b27f4f9ceeabb34be1a3c06f59f0443a134
```

These deterministic relationships are intended for the later companion bridge;
stage 0 does not attach them yet.

## Build and install

The helper builds a distinct kernel release:

```text
7.1.5-a14-acpi-hybrid0
```

It uses the running `7.1.5-070105-generic` configuration and preserves the exact
live FDT from `/sys/firmware/fdt` for the experimental GRUB entry. It also builds
the A14 EC modules for the new kernel while forcibly restoring the committed
known-good `hid_asus_ec.c`; the Fn-lock generator is not allowed to reintroduce
the keyboard-backlight regression.

Build as the normal user:

```bash
bash scripts/a14-acpi-hybrid-kernel.sh build
```

Install as root:

```bash
sudo bash scripts/a14-acpi-hybrid-kernel.sh install
```

The installer creates a dedicated GRUB entry:

```text
ASUS Zenbook A14 — ACPI+DT Hybrid v0 (7.1.5-a14-acpi-hybrid0)
```

It does not replace the existing `7.1.5-070105-generic` kernel or its normal
GRUB entries.

## First boot validation

After manually selecting the hybrid entry, verify:

```bash
uname -r
cat /proc/cmdline
bash scripts/a14-acpi-hybrid-kernel.sh status

test -d /proc/device-tree && echo DT_PRESENT

sudo dmesg --ctime | \
  grep -E 'DT-hybrid|ACPI: Core revision|i2c_hid|0B05:0220|asus.*ec' | \
  tail -n 200

sudo sha256sum /sys/firmware/acpi/tables/DSDT
```

Expected core evidence:

```text
7.1.5-a14-acpi-hybrid0
acpi=hybrid
DT_PRESENT
DT-hybrid sidecar: ACPI tables accepted; DT remains boot authority
DT-hybrid sidecar: initializing ACPICA core with Linux ACPI platform mode disabled
DT-hybrid namespace: \\_SB.I2C9 present
DT-hybrid namespace: \\_SB.ECKB present
DT-hybrid namespace: \\_SB.PEP0 present
DT-hybrid namespace: \\_SB.GIO0 present
DT-hybrid sidecar ready: DT owns hardware; ACPI scan/power/IRQ/PCI disabled
```

Also verify physically before doing any further experiment:

- keyboard backlight leaves firmware breathing mode and remains controllable;
- keyboard/hotkeys work;
- CPUFreq policies exist and use the expected SCMI path;
- fans/profile controls still work;
- storage, USB, Wi-Fi and display behave like the known-good DT boot.

## Recovery

If the hybrid kernel fails to boot or regresses hardware, select the existing
`7.1.5-070105-generic` entry in GRUB.

Once booted back into the known-good kernel:

```bash
sudo bash scripts/a14-acpi-hybrid-kernel.sh remove
```

The removal helper refuses to delete the experimental release while that release
is currently running.

## Planned progression

Only after stage 0 is repeatedly stable:

1. Add a read-only ACPI/DT identity bridge.
2. Match DT `a80000.i2c` to ACPI `\\_SB.I2C9` using the exact MMIO resource.
3. Match the existing DT I2C client at `0x15` to ACPI `\\_SB.ECKB`.
4. Attach ACPI firmware-node/companion information only to already-existing DT
   devices; do not create duplicate physical devices.
5. Expose selected `_CRS`, `_DEP` and `_DSM` information to explicitly
   whitelisted drivers.
6. Keep `PEP0` inspection-only until its Windows/Qualcomm semantics are
   understood well enough to avoid competing with DT power domains.
7. Consider hardware-owning ACPI support only after each subsystem has an
   independently reversible DT fallback.
