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

`qcAlwaysOnSensing.dll` opens the Qualcomm camera-platform device and uses
`IOCTL_KMD_CAMERA_PLATFORM_SET_AOS_CONFIG` (`0x002326bb`) around the SSC
camera-handshake/HPD lifecycle.

The matching `qccamplatform8380.sys` maps the two input states as follows:

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
resource provenance; it does **not** establish that the window is safe to access
before all platform prerequisites are active.

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
`aon_mux_read=false`. This places the failure at the direct write while the
camera platform was in the prerequisite state produced by that experiment.

## Matching focused-audit payload

The read-only focused audit preserved the exact installed ARM64 files used for
static analysis:

- `qccamplatform8380.sys`, version `4934.911.0.0`, SHA-256
  `041E989C967E1E5425E963F9B8B1826806603DB175F24072865A49AAE6991739`;
- `qcAlwaysOnSensing.dll`, version `4934.953.0.0`, SHA-256
  `5237DEF4E14E6B73A6B1F788878DFB5CF61D4B239515301375BF304EB81408EE`;
- the matching QRD and MTP CAMP resource, performance, platform-config and
  preload binaries;
- the matching base and extension INFs and catalogs.

The selected binaries and CAMP data are Microsoft hardware-compatibility
signed according to Windows Authenticode validation on the machine.

## Confirmed Windows power-before-store sequence

The ARM64 disassembly resolves the previously unknown ordering.

The AOS IOCTL handler first calls a camera-platform reference helper. The first
reference performs this sequence:

1. increment the platform reference count;
2. when the new count is one, call the helper at image VA `0x140007aa0`;
3. that helper calls `PoFxActivateComponent(PoHandle, 0, 1)`;
4. after the PoFx activation call returns, store `1` in the driver's
   `PlatformPowerState` field;
5. return to the AOS IOCTL handler.

The AOS handler then verifies that `PlatformPowerState == 1`, validates the
input state, chooses `0x101` or `0x000`, and executes the direct ARM64 store:

```text
str w22, [x8, #0x1e0]
```

The matching instruction is at image VA `0x140003bf4`. There is no register
readback around this store.

The final platform-reference release clears `PlatformPowerState` and calls the
helper at image VA `0x140007b68`, which resolves to
`PoFxIdleComponent(PoHandle, 0, 1)`.

The effective ordering is therefore:

```text
SET_AOS_CONFIG
  -> acquire camera-platform reference
  -> PoFxActivateComponent(component 0, flags 1)
  -> PlatformPowerState = ON
  -> store AOS/AP value to CPAS + 0x1e0
  -> release camera-platform reference
  -> PlatformPowerState = OFF on the last reference
  -> PoFxIdleComponent(component 0, flags 1)
```

This confirms that Windows does not treat the mux write as a standalone
operation.

## PoFx and PEP resource evidence

The installed platform driver imports and uses the PoFx device/component APIs,
including component activation, idle, power-control and performance-state
operations. It also imports `MmMapIoSpaceEx` and performs an ordinary ARM64 MMIO
store after PoFx activation.

No static import indicating a direct SCM/QSEE/secure-monitor call was found in
this driver. That does not eliminate firmware participation inside the Windows
PEP or another dependency, but a driver-local secure-call wrapper is not visible
on the confirmed store path.

Windows reports `CAMP` as dependent on:

- the Qualcomm Power Engine Plug-in device (`QCOM0C17`);
- the Qualcomm PMIC power-management device (`QCOM0C2B`);
- the Qualcomm System Manager GPIO device (`QCOM0C0C`).

The matching QRD extension INF associates this ASUS machine with:

- `CAMP_RES_QRD.bin`: PEP resource graph;
- `CAMP_PERF_QRD.bin`: performance-state and bandwidth mapping;
- `CAMP_PCFG_QRD.bin`: platform configuration;
- `CAMP_PRLD_QRD.bin`: preload data.

The base camera-platform activation graph names:

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

`CAMP_PERF_QRD.bin` maps RT/NRT bandwidth requests to CAMNOC AXI clock and
P-state selection.

## Linux prerequisite comparison

The X1E80100 CAMSS Linux model already provides more than the original Stage 3
notes implied:

- CAMSS runtime PM is linked to the named `top` power domain, which represents
  the Titan-top GDSC;
- runtime resume raises the four CAMSS interconnect paths (`ahb`, `hf_mnoc`,
  `sf_mnoc`, and `sf_icp_mnoc`);
- the device-tree binding exposes the seven direct clock equivalents needed for
  the Windows base camera-platform graph:
  `camnoc_rt_axi`, `camnoc_nrt_axi`, `cpas_ahb`, `core_ahb`,
  `cpas_fast_ahb`, `gcc_axi_hf`, and `gcc_axi_sf`.

The failed Stage 3 test held runtime PM but explicitly enabled only
`cpas_ahb` and `cpas_fast_ahb`. The concrete untested difference is therefore
the broader local clock state, not merely the top GDSC or ICC votes.

`gcc_camera_ahb_clk`, `gcc_camera_xo_clk`, and the Windows-specific
`cam_cc_gdsc_clk` do not have one-to-one consumer clock names in the CAMSS
binding. They may be parent/framework-managed effects of the Linux clock and
genpd operations, or they may remain a separate prerequisite gap.

## Revised interpretation

The leading explanation for the Stage 3 reset is an MMIO access while the CPAS
window was only partially clocked relative to Windows' PoFx component-0 state.
This explanation is now supported by the exact Windows call order and resource
graph, but it remains a hardware hypothesis until Linux proves the expanded
power state without touching the mux.

A firewall or firmware response is still possible. Therefore direct AON mux
MMIO remains quarantined regardless of the power-probe result.

## Safe Linux prerequisite probe

The diagnostic patch under
`kernel-patches/aos/power-diagnostics/` is intentionally separate from the
production series. Its sysfs trigger performs only:

1. CAMSS runtime-PM resume, retaining the top GDSC and existing ICC votes;
2. enable the seven Linux-visible platform clocks listed above;
3. report every resulting clock rate;
4. hold the state for 250 ms;
5. disable the clocks and release runtime PM in reverse.

It contains no `readl`, `writel`, `ioread`, `iowrite`, CPAS register
dereference, SSC request, or camera-handshake INIT.

Build, install, and run it only through the isolated scripts:

```bash
bash ./scripts/a14-aos-power-diag-build.sh
bash ./scripts/a14-aos-power-diag-install-test.sh
```

After manually selecting the generated GRUB test entry:

```bash
bash ./scripts/a14-aos-power-diag-run.sh
```

The result determines only whether the expanded prerequisite state can be
entered and exited safely. It does **not** authorize another mux access.

## Current implementation requirements

- The production CAMSS provider fails acquisition with `-EOPNOTSUPP` before
  touching the register.
- The old write-capable Stage 3/4 diagnostics remain removed and blocked.
- The safe power probe must complete and preserve normal camera enumeration.
- Any future mux-access experiment requires a separate reviewed design and must
  not be folded into the prerequisite probe.
- The SSC/IIO driver may send camera-handshake INIT 576 only after a future
  provider backend has safely acquired AOS ownership.
