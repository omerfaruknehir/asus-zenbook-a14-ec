# Windows AOS camera-platform handoff evidence

This document records the machine-specific evidence used to investigate the
Zenbook A14 always-on-camera ownership handoff in Linux. It is not a proposal to
replay Windows IOCTLs from userspace.

## Front-sensor capability block

`qccamfrontsensor8380.sys` implements
`IOCTL_KMD_FRONT_SENSOR_GET_AOS_PARAM` (`0x002323ff`). The output is an 88-byte
structure:

| Offset | Size | Meaning |
|---:|---:|---|
| `0x00` | 4 | revision, observed value `2` |
| `0x04` | 4 | AOS capability |
| `0x08` | 4 | AOS test mode |
| `0x0c` | 50 | sensor name |
| `0x40` | 4 | camera ID |
| `0x44` | 4 | HPD client enable |
| `0x48` | 4 | face-detection mode index |
| `0x4c` | 4 | face-detection algorithm |
| `0x50` | 4 | face-delivery mode |
| `0x54` | 4 | horizontal view angle |

The installed front-camera configuration identifies the AOS sensor as
`ov02c10`, camera ID `2`, with HPD enabled.

## Camera-platform operation observed in Windows binaries

`qcAlwaysOnSensing.dll` performs the following order:

1. Read and validate the front-sensor AOS capability block.
2. Open the Qualcomm camera-platform device.
3. Send `IOCTL_KMD_CAMERA_PLATFORM_SET_AOS_CONFIG` (`0x002326bb`) with an
   eight-byte input `{ version = 1, state = 0 }`.
4. Start the SSC camera-handshake and HPD sequence.
5. During teardown, send `{ version = 1, state = 1 }` to return ownership to the
   normal camera path.

`qccamplatform8380.sys` maps the states as follows:

| State | Register value | Meaning |
|---:|---:|---|
| 0 | `0x00000101` | route the camera clock/ownership path to AOS |
| 1 | `0x00000000` | restore the normal AP camera path |

The binary references
`CPAS_TOP_CPAS_0_MAIN_CAM_AON_CAM_SEL_CTRL`, offset `0x1e0` from its
camera-platform/CPAS-top mapping.

## Physical resource

The machine ACPI `CAMP` device (`QCOM0C32`, UID `0x1b`) describes:

- `0x0ac13000 + 0x1000`: CCI synchronization block
- `0x0ac15000 + 0x1000`: CCI0
- `0x0ac16000 + 0x1000`: CCI1
- `0x0ac19000 + 0x0c000`: camera-platform/CPAS-top window

The apparent register address is therefore `0x0ac191e0`. This establishes
resource provenance; it does **not** establish that an arbitrary Linux EL1 MMIO
access is permitted.

## Linux hardware results

The original implementation assumed that mapping the firmware-described window,
holding CAMSS runtime PM, and enabling `cpas_ahb` plus `cpas_fast_ahb` would be
sufficient. Hardware disproved that assumption.

1. Runtime PM get/put returned normally.
2. Runtime PM plus the two CPAS AHB clocks returned normally.
3. A read from the mux caused an abrupt platform reset with no preserved Linux
   panic or pstore record.
4. The read was removed. A later isolated test wrote only `0x000`, the expected
   already-active AP value, with no readback and no SSC request. The machine
   again reset before the sysfs write returned.

The Stage 3 marker remained `status=started`, `ssc_contacted=false`, and
`aon_mux_read=false`. This places the failure at the direct write itself or at a
platform firewall/firmware response to it.

## Revised implementation requirements

The CAMSS provider now fails acquisition with `-EOPNOTSUPP` before touching the
register. Direct MMIO remains quarantined.

Before implementing another backend, determine which prerequisite the Windows
path supplies but the Linux experiment did not. Candidate classes include:

- secure or XPU authorization;
- a firmware-mediated camera-platform request;
- a CPAS/CAMNOC power or interconnect sequence beyond the two AHB clocks;
- another ownership or lifecycle call performed by the Windows camera stack.

The investigation must inspect the call path around the Windows register helper,
not merely the final store instruction. No further register access should occur
until a non-resetting access mechanism is supported by evidence.

The SSC/IIO driver remains a consumer of the CAMSS provider. It may send
camera-handshake INIT 576 only after a future provider backend has successfully
and safely acquired AOS ownership.