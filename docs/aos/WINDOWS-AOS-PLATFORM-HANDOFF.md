# Windows AOS camera-platform handoff evidence

This document records the machine-specific evidence used to investigate the
ASUS Zenbook A14 UX3407RA always-on-camera ownership handoff. It is not a
proposal to replay Windows IOCTLs or access CPAS registers from Linux userspace.

## Safety boundary

The following remain prohibited in this investigation:

- direct CPAS `+0x1e0` access;
- `/dev/mem`;
- raw `ioremap`;
- diagnostic `readl`/`writel` of the AON mux;
- the retired Stage 3/4 write-capable tests;
- SSC camera-handshake activation before ownership is proven safe.

The production Linux provider remains fail-closed with `-EOPNOTSUPP`.

## Windows front-sensor capability

`qccamfrontsensor8380.sys` implements
`IOCTL_KMD_FRONT_SENSOR_GET_AOS_PARAM` (`0x002323ff`). The observed AOS sensor is
`ov02c10`, camera ID 2, with HPD enabled.

## Exact Windows AOS client

The focused Windows payload resolves the user-mode client of the camera-platform
AOS operation.

Windows enumerates:

```text
ACPI\QCOM0D06\1F
Qualcomm(R) Spectra(TM) 695 ISP Camera Always On Sensing Device
class=Sensor
service=WUDFRd
ACPI location=\_SB.AONC
INF section=AlwaysOnSensing_Inst.NT
```

The installed UMDF payload contains `qcAlwaysOnSensing.dll` version
`4934.953.0.0`.

Static ARM64 disassembly proves that `qcAlwaysOnSensing.dll` itself calls
`DeviceIoControl` on the camera-platform handle with
`IOCTL_KMD_CAMERA_PLATFORM_SET_AOS_CONFIG` (`0x002326bb`).

The two observed 8-byte payloads are:

```text
01 00 00 00 00 00 00 00
```

which is `{ version = 1, state = 0 }`, meaning route the camera platform to AOS,
and:

```text
01 00 00 00 01 00 00 00
```

which is `{ version = 1, state = 1 }`, meaning restore the AP path.

The DLL also contains the Qualcomm Sensor Hub camera-handshake protocol and
human-presence messages, including:

- `qsh_camera_handshake_init`;
- `qsh_camera_handshake_release_control`;
- `qsh_camera_handshake_revoke_control`;
- camera power-state ON/OFF;
- `sns_human_presence_detect`;
- presence detected/not-detected events.

Therefore the correct Windows trace target is the normal Windows Presence
Sensing path backed by `ACPI\QCOM0D06`, not a guessed camera test or a direct
camera-platform IOCTL tool.

## Camera-platform operation

The matching `qccamplatform8380.sys` maps AOS configuration states as follows:

| State | Register value | Meaning |
|---:|---:|---|
| 0 | `0x00000101` | route camera clock/ownership path to AOS |
| 1 | `0x00000000` | restore the normal AP path |

The driver maps the camera-platform/CPAS-top resource and references
`CPAS_TOP_CPAS_0_MAIN_CAM_AON_CAM_SEL_CTRL`, offset `0x1e0`.

The machine ACPI `CAMP` device (`QCOM0C32`, UID `0x1b`) describes the
camera-platform window at `0x0ac19000 + 0x0c000`, making the apparent register
address `0x0ac191e0`. This establishes provenance only; it does not make the
window safe to access.

## Confirmed Windows power-before-store sequence

ARM64 disassembly resolves the ordering around the mux store:

```text
SET_AOS_CONFIG
  -> acquire camera-platform reference
  -> first reference:
       PoFxActivateComponent(PoHandle, component 0, flags 1)
  -> PlatformPowerState = ON
  -> validate AOS/AP request
  -> store 0x101 or 0x000 to CPAS + 0x1e0
  -> release camera-platform reference
  -> last reference:
       PlatformPowerState = OFF
       PoFxIdleComponent(PoHandle, component 0, flags 1)
```

The confirmed store is an ordinary ARM64 `str`; there is no immediate readback
and no driver-local SCM/QSEE import on the path.

## Why direct Linux MMIO is quarantined

The original Linux experiments held CAMSS runtime PM and enabled only a small
subset of the camera-platform clocks before touching the mux.

- Runtime PM alone returned normally.
- Runtime PM plus CPAS AHB clocks returned normally.
- A direct mux read caused an abrupt reset without a useful panic/SError trace.
- A later write-only test storing the expected AP value `0x000` also reset before
  the sysfs write returned.

Those results prove that direct CPAS access in that prerequisite state is not
safe. No later power-only success authorizes retrying the mux.

## Windows CAMP component-0 F0 resource model

The QRD CAMP resource/performance payload and Kernel-Power rundown identify the
component-0 F0 defaults used by Windows:

- CCI0 = 37.5 MHz;
- CCI1 = 37.5 MHz;
- NRT bandwidth = 200 MB/s;
- RT bandwidth = 200 MB/s;
- CAMNOC RT = 300 MHz;
- CAMNOC NRT = 300 MHz;
- CPAS AHB = 80 MHz;
- Core AHB = 80 MHz;
- CPAS Fast AHB = 100 MHz;
- ICP AHB = 80 MHz;
- ICP = 400 MHz.

The F0 resource sequence also references MMCX, Titan-top, GCC camera support
clocks, GCC HF/SF AXI clocks and camera GPIO resources.

### `CAMP_PRLD_QRD.bin` correction

`CAMP_PRLD_QRD.bin` is associated with the platform driver's **Privacy LED**
resource path. Nearby binary strings identify `PrldBinaryPath`, `PRLD
RuntimeResourceConfig`, PMIC Privacy LED operation and a Privacy LED P-state
operation.

Consequently the Kernel-Power performance-set label `CAM_PRLD` must not be
assumed to be a missing AOS ownership/power prerequisite.

## Linux framework mapping

The live normal-boot audit establishes:

- CAMSS owns the named `top` power domain, corresponding to Titan-top;
- Titan-top participates in the MMCX/MXC genpd graph;
- CAMSS owns `ahb`, `hf_mnoc`, `sf_mnoc` and `sf_icp_mnoc` interconnect paths;
- CCI0 (`ac15000.cci`) and CCI1 (`ac16000.cci`) are real `i2c-qcom-cci`
  devices and own their CCI clocks;
- `cam_cc_icp_ahb_clk` and `cam_cc_icp_clk` exist in CAMCC but are deviceless in
  the current Linux DT/runtime graph.

The normal X1E CAMSS runtime-PM votes are already above the 200 MB/s Windows F0
RT/NRT defaults, so a separate raw bandwidth manipulation is not justified.

### GCC camera support clocks

Upstream X1E80100 GCC explicitly forces `GCC_CAMERA_AHB_CLK` and
`GCC_CAMERA_XO_CLK` on during GCC probe. These are therefore not an unresolved
hardware-test target on Linux.

The CAMSS binding already exposes the GCC camera HF/SF AXI branches as
`gcc_axi_hf` and `gcc_axi_sf`; those were exercised in the framework-managed
CAMSS prerequisite test.

## Validated Linux F0 subset

All tests below were framework-managed, non-SSC and contained no direct CPAS
MMIO.

### CAMSS runtime-PM / seven-clock prerequisite

A 250 ms hold with CAMSS runtime PM, top-domain/ICC state and these seven clocks
completed without reset:

- `camnoc_rt_axi`;
- `camnoc_nrt_axi`;
- `cpas_ahb`;
- `core_ahb`;
- `cpas_fast_ahb`;
- `gcc_axi_hf`;
- `gcc_axi_sf`.

Both cameras remained enumerable afterward.

### Windows-F0 clock-rate subset

The staged rate diagnostic then proved:

1. CAMNOC RT/NRT at 300/300 MHz for 250 ms: no reset.
2. CPAS/Core/Fast AHB at 80/80/100 MHz for 250 ms: no reset and exact restore.
3. Combined 300/300/80/80/100 MHz for 250 ms: no reset.

The CAMNOC shared-RCG path cannot reconstruct its boot-time parked 19.2 MHz
configuration through the public rate table after explicit programming; its
restore request lands at 240 MHz. That is a restoration limitation, not a
failure to reach or hold the Windows 300 MHz target.

### CCI0 / CCI1

A separate diagnostic used the existing `i2c-qcom-cci` runtime-PM ownership:

- CCI0: 19.2 -> 37.5 MHz -> 19.2 MHz, exact, 250 ms hold, success;
- CCI1: 19.2 -> 37.5 MHz -> 19.2 MHz, exact, 250 ms hold, success.

Both CCI controllers returned runtime-suspended and both cameras enumerated
after each isolated test.

## ICP remains blocked

Although upstream X1E CAMCC exposes `cam_cc_icp_ahb_clk` and
`cam_cc_icp_clk`, and the ICP source supports 400 MHz, the current Linux system
has no legitimate device consumer/runtime-PM owner for those clocks.

Qualcomm downstream camera stacks model ICP as a dedicated camera subsystem with
its own platform device, CPAS registration/votes, SoC-resource enablement and
firmware lifecycle. Therefore directly acquiring the deviceless clock handles
would not recreate the Windows ICP prerequisite and is not an acceptable next
hardware experiment.

## Windows trace required next

The earlier WPR Power trace contained CAMP rundown metadata but no runtime CAMP
active/idle transition, so the manual action used for that capture did not
actually drive the camera-platform component into F0.

The repository now includes:

```text
scripts/a14-windows-qcom0d06-aos-trace.ps1
```

This collector targets the real Windows Presence Sensing path. It:

- records the built-in WPR `Power` profile;
- snapshots `QCOM0D06`, `QCOM0C32` and their power dependencies;
- records UMDF host/module state;
- does **not** send `0x002326bb` itself;
- does not read `HumanPresenceSensor` itself;
- does not restart devices or modify PnP state;
- performs no register access.

On Windows, the supported Settings entry point for Presence Sensing is
`ms-settings:presence`. A normal OS feature such as Lock on Leave, Wake on
Approach or Adaptive Dimming should be exercised while the trace is running.
The resulting ETL should then be decoded with the existing Kernel-Power exporter
to find the real CAMP component-0 activation, component state and performance
state sequence.

## Current implementation requirements

- Production AOS acquisition remains fail-closed with `-EOPNOTSUPP`.
- Direct CPAS `+0x1e0` access remains quarantined.
- SSC INIT 576 remains blocked until ownership is independently proven safe.
- ICP remains blocked until a legitimate Linux owner/runtime-PM context exists.
- `CAM_PRLD` is treated as Privacy LED evidence, not an AOS prerequisite.
- The next evidence-gathering step is a real QCOM0D06 Windows Presence Sensing
  trace, not another Linux power escalation.
