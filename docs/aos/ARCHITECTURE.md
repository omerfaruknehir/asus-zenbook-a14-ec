# Always-on sensing: kernel architecture

This directory tracks proper Linux support for the ASUS Zenbook A14 always-on
camera and human-presence hardware. Sensor operation must not depend on a custom
userspace daemon, a polling loop, a synthetic input device, or a replacement
camera stack.

## Hardware established from the Windows-matched machine data

The UX3407RA front/AOS sensor is an OmniVision OV02C10:

- I²C bus instance: 9
- 7-bit address: `0x36`
- chip-ID register: `0x300a`
- chip ID: `0x5602`
- master clock: 19.2 MHz
- AOS mode: 320×240 RAW10 over two CSI-2 lanes
- AOS register sequence: 515 ordered byte writes
- reset resource: pin 22 in the AOC/QSH numbering domain
- DRI resource: chip pin 113
- suspend/resume event IDs: 832/833

The Windows path is:

```text
OV02C10 + AOC camera resources
        ↓
Qualcomm QSH camera firmware/configuration
        ↓
ADSP/SSC services over Qualcomm transport
        ↓
face presence and distance
        ↓
OS sensor interface
```

The normal AP-side V4L2 path and the low-power QSH path share a physical sensor,
but they are not interchangeable. Successful OV02C10/CAMSS streaming does not
prove that QSH has acquired and configured the AOS producer.

## Required Linux layers

### 1. Device tree

The A14 DTS must describe physical wiring and power resources. It must not copy
Windows ACPI device IDs into Linux as fake platform devices.

Required data includes the existing OV02C10 endpoint, CSI routing, clocks,
regulators, reset/DRI resources, and the relationship between the AP camera path
and the always-on owner. New properties require a reviewed DT binding; vendor
configuration filenames must not be embedded ad hoc without a binding.

### 2. OV02C10 V4L2 driver

Upstream Linux already contains `drivers/media/i2c/ov02c10.c`. The A14 work must
extend that driver rather than add a second sensor driver. Needed changes are:

- select and retain a current mode instead of assuming `supported_modes[0]`;
- add the captured 320×240 low-power mode with correct timing;
- keep 1928×1092 as the normal camera mode;
- preserve runtime-PM, regulator and reset semantics;
- arbitrate ownership cleanly when the QSH/AON path is active.

The 515-write table is evidence for the mode implementation. It must be reviewed
against the sensor module blob before submission; blindly replaying it from a
new standalone module is not acceptable.

### 3. Qualcomm firmware and remote processor

The machine already uses a Windows-matched ADSP firmware/DTB pair. Linux must
continue loading that pair through the existing Qualcomm remoteproc/PAS path.
The camera/QSH configuration files are proprietary firmware inputs and are not
stored in this repository. Only filenames, hashes, decoded metadata and
installation provenance are tracked.

The kernel driver must use `request_firmware()` or the firmware-loading mechanism
owned by the relevant Qualcomm subsystem. A helper script must not push binary
messages into a live remote processor.

### 4. QSH/SNS transport

Transport belongs in a Qualcomm kernel driver built on the existing QRTR/QMI,
RPMSG, remoteproc and service-discovery infrastructure. The implementation must:

- discover the correct service rather than depend on a transient node number;
- recover from ADSP restart and service loss;
- perform camera acquire/release/revoke ownership correctly;
- load the machine configuration using the firmware subsystem;
- validate message sizes and versions;
- use runtime PM and system-suspend callbacks;
- avoid private debug IOCTLs as the normal ABI.

### 5. Standard Linux sensor ABI

Presence/distance should be exposed through a standard kernel ABI. The current
working direction is an IIO proximity channel with threshold/change events and,
when the firmware supplies it, processed distance. A new generic human-presence
ABI should only be proposed if the available IIO/HID interfaces cannot represent
the data without losing semantics.

Desktop power management must consume the standard device. It must not be the
component that talks to QSH.

## Optional desktop integrations

Optional GNOME/KDE integrations live under `desktop/` and are independent of
hardware enablement. Examples include a fan/profile indicator or a camera block
indicator. They may read standard hwmon, LED, privacy-switch, V4L2 or IIO state;
they must never be required to make the hardware function.

## Development stages

1. Capture a read-only report with `scripts/a14-aos-kernel-probe.sh`.
2. Match the running Ubuntu kernel and DTS to current upstream interfaces.
3. Produce reviewable OV02C10 and DTS patches.
4. Implement the Qualcomm QSH service client with restart-safe lifecycle.
5. Expose IIO presence/distance and validate runtime PM and suspend.
6. Split upstream submissions by subsystem: media, arm64 DTS/bindings,
   Qualcomm SoC/remoteproc, then IIO if required.

## Acceptance criteria

A result is not considered working unless all of these hold:

- no userspace process is required for sensor operation;
- no periodic camera polling is used;
- normal RGB camera operation still works;
- suspend/resume and ADSP recovery work repeatedly;
- turning presence sensing off releases camera ownership and power resources;
- firmware provenance and hashes are recorded;
- the interface is usable through standard Linux subsystems;
- optional desktop helpers are separately packaged and removable.
