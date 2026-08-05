# Windows AOS camera-platform handoff evidence

This document records the machine-specific evidence used to implement the
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

## Camera-platform operation

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

The driver writes the value to
`CPAS_TOP_CPAS_0_MAIN_CAM_AON_CAM_SEL_CTRL`, offset `0x1e0` from its mapped
camera-platform/CPAS-top base.

## Physical resource

The machine ACPI `CAMP` device (`QCOM0C32`, UID `0x1b`) describes:

- `0x0ac13000 + 0x1000`: CCI synchronization block
- `0x0ac15000 + 0x1000`: CCI0
- `0x0ac16000 + 0x1000`: CCI1
- `0x0ac19000 + 0x0c000`: camera-platform/CPAS-top window

Therefore the handoff register is physically located at `0x0ac191e0`.

Linux already owns the CCI and CAMSS resources, but the current X1E80100 CAMSS
binding does not describe the `0x0ac19000` window. The correct implementation is
therefore a CAMSS-owned resource and API, not a hard-coded `ioremap()` in the HPD
driver and not a `/dev/mem` write.

## Linux implementation requirements

The CAMSS provider must:

- map a named `cpas-top` resource;
- power the Titan-top domain and enable `cpas_ahb`/`cpas_fast_ahb` before access;
- serialize AP and AOS ownership;
- reject AOS acquisition while an AP V4L2 pipeline is prepared or streaming;
- write `0x101`, read it back, and keep the power/clock vote while AOS owns it;
- restore `0x000` on handshake failure, disable, suspend, service loss, and
  module removal;
- never expose the register as a userspace ABI.

The SSC/IIO driver is a consumer of that provider. Only after the provider has
successfully switched ownership may it send camera-handshake INIT `576` and
wait for ACK `832`.
