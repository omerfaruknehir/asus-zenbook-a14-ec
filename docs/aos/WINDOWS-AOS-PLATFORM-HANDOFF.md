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
missing platform prerequisite.

## Windows platform-power evidence

A read-only audit of the installed Windows 11 ARM64 camera stack found stronger
evidence for incomplete resource activation than for a secure-world-only mux.

The installed camera-platform package is `qccamplatform8380`, version
`4934.911.0.0`. Its binary contains all of the following:

- `IOCTL_KMD_CAMERA_PLATFORM_SET_AOS_CONFIG failed: PlatformPowerState is OFF`
- `Successfully config Mclk Mux for AOS`
- `CameraCPAS_Init` and `CameraCPAS_DeInit`
- CAMNOC bandwidth and AXI-clock selection paths
- PoFx device, component, performance-state and power-control registration
- runtime-resource enumeration/configuration through ACPI
- direct `MmMapIoSpaceEx` and `MmUnmapIoSpace` imports

No static import indicating a direct SCM/QSEE/secure-monitor call was found in
this platform driver. That does not completely rule out secure mediation through
another device, but it weakens the secure-register-only explanation.

Windows reports `CAMP` as dependent on:

- the Qualcomm Power Engine Plug-in device (`QCOM0C17`);
- the Qualcomm PMIC power-management device (`QCOM0C2B`);
- the Qualcomm System Manager GPIO device (`QCOM0C0C`).

The installed `CAMP_RES_QRD.bin` PEP resource graph names a substantially larger
set of resources than the Linux Stage 3 experiment enabled:

- `cam_cc_titan_top_gdsc`
- `cam_cc_gdsc_clk`
- `cam_cc_core_ahb_clk`
- `cam_cc_cpas_ahb_clk`
- `cam_cc_cpas_fast_ahb_clk`
- `cam_cc_camnoc_axi_rt_clk`
- `cam_cc_camnoc_axi_nrt_clk`
- `gcc_camera_ahb_clk`
- `gcc_camera_hf_axi_clk`
- `gcc_camera_sf_axi_clk`
- `gcc_camera_xo_clk`
- CAMNOC HF/SF interconnect masters and performance states

`CAMP_PERF_QRD.bin` additionally maps RT/NRT bandwidth demand to CAMNOC AXI
clock and P-state selection.

## Current interpretation

The leading hypothesis is now that Windows reaches a complete
`PlatformPowerState=ON` through PEP/PoFx before accessing the mux. Linux Stage 3
activated the CAMSS runtime-PM path and only the two CPAS AHB clocks, but did not
explicitly reproduce the complete camera-platform resource graph. An access to
a partially powered or locally clock-gated CPAS/CAMNOC register window can
explain the abrupt platform reset.

This remains a hypothesis until the exact Windows function path and resource
ordering are reconstructed from the matching driver binary and resource files.
The direct MMIO quarantine therefore remains mandatory.

## Revised implementation requirements

The CAMSS provider fails acquisition with `-EOPNOTSUPP` before touching the
register. No further mux access is allowed yet.

The next investigation must:

1. preserve the exact matching `qccamplatform8380.sys` and CAMP resource/config
   binaries;
2. locate code references to the AOS power-state rejection, mux-success and
   register-log strings;
3. reconstruct which PoFx components/resources are activated before the store;
4. compare that sequence against the X1E80100 Linux CAMSS clock, genpd and ICC
   model;
5. add a non-MMIO Linux prerequisite probe that only enables and reports the
   candidate resources, then releases them cleanly;
6. consider another MMIO test only after the prerequisite state is proven and
   the test has a separately reviewed reset-safe design.

The SSC/IIO driver remains a consumer of the CAMSS provider. It may send
camera-handshake INIT 576 only after a future provider backend has safely
acquired AOS ownership.