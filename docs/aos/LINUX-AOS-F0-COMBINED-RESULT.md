# Linux combined AOS F0 prerequisite result

This document records the hardware result of the framework-managed combined F0
prerequisite diagnostic on the ASUS Zenbook A14 UX3407RA / X1E80100.

This result does **not** authorize direct CPAS MMIO, SSC activation, deviceless
ICP clock manipulation, raw interconnect manipulation, or replay of the Windows
camera-platform IOCTL.

## Test environment

- Kernel: `7.0.0-32-qcom-x1e`
- Boot ID: `2dd56d19-d763-48ca-9d75-6d98a826ecda`
- Diagnostic: `platform-power-f0-combined-framework-only`
- Direct CPAS MMIO: false
- SSC contact: false
- ICP clock manipulation: false
- Raw interconnect manipulation: false
- DTB changes: false

The test was recovered from the current boot log after the original runner hit a
locale-dependent `journalctl --since` parsing error after all three hardware
holds had already completed. The recovery pass performed no hardware operation.

## Concurrent target state

Three framework-owned holds were launched concurrently:

- CCI0 `ac15000.cci`: 37.5 MHz;
- CCI1 `ac16000.cci`: 37.5 MHz;
- CAMSS `acb7000.isp` phase 3:
  - `camnoc_rt_axi`: 300 MHz;
  - `camnoc_nrt_axi`: 300 MHz;
  - `cpas_ahb`: 80 MHz;
  - `core_ahb`: 80 MHz;
  - `cpas_fast_ahb`: 100 MHz;
  - normal CAMSS runtime PM retained the existing top-GDSC/genpd and ICC
    framework state.

The target-hold start timestamps were:

```text
CCI0   86.563782 s
CCI1   86.565639 s
CAMSS  86.581182 s
```

The start spread was 17.400 ms, leaving a conservative minimum common overlap
of **232.600 ms** across all three 250 ms holds.

## Result

The combined prerequisite state is validated:

```text
overlap_status=validated-at-least-100ms
minimum_common_hold_overlap_ms=232.600
kernel_fault_status=none-in-combined-window
recovery_status=combined-hold-validated
```

Both CCI controllers reached exactly 37.5 MHz, completed successfully, restored
exactly to 19.2 MHz, and later returned runtime-suspended.

CAMSS reached all five requested phase-3 targets exactly and held them for 250
ms without reset, watchdog failure, panic, SError, call trace, oops, or internal
error. CPAS/Core/Fast AHB restored exactly to 64/64/80 MHz.

The CAMSS sysfs store returned `-ERANGE` only during restoration because the
public CAMNOC shared-RCG rate table cannot reconstruct the boot-time 19.2 MHz
parked configuration after explicit rate programming. Both CAMNOC clocks land at
240 MHz when asked to restore 19.2 MHz. This is the already-established parking
limitation and does not invalidate the successful 300 MHz target hold.

After recovery, CAMSS, CCI0 and CCI1 were all runtime-suspended.

## Remaining Windows-F0 resource gap

The combined run closes the previously separate CAMSS/CCI concurrency question.
The remaining named Windows CAMP F0 clock gap is now concentrated on ICP:

- `cam_cc_icp_ahb_clk`: 80 MHz in the CAMP F0 resource sequence;
- `cam_cc_icp_clk`: 400 MHz in the CAMP F0 resource sequence.

The other previously suspicious support clocks are not a reason for another
consumer-clock diagnostic:

- X1E80100 GCC keeps `GCC_CAMERA_AHB_CLK` and `GCC_CAMERA_XO_CLK` always on;
- X1E80100 CAMCC treats `CAM_CC_GDSC_CLK` as a critical CBCR and enables it from
  the common Qualcomm clock-controller probe path;
- Titan-top is represented through Linux genpd;
- CAMSS already owns and votes its `ahb`, `hf_mnoc`, `sf_mnoc` and
  `sf_icp_mnoc` interconnect paths.

The Windows `CAMP_RES_QRD.bin` FSTATE 0 sequence explicitly contains both ICP
clock resources before the CCI clocks and GPIO resources. Therefore they are
part of the Windows CAMP component-active resource sequence, not merely names in
an unrelated performance table.

However, the current Linux camera graph exposes the ICP clocks without a
legitimate ICP device/runtime-PM owner. Qualcomm downstream camera stacks model
ICP as a dedicated device with CPAS voting, SOC-resource sequencing, firmware
loading/HFI and its own lifecycle. Directly obtaining and enabling these clocks
as provider-global/deviceless clocks would not reproduce that ownership model
and remains prohibited.

## Next evidence boundary

Do not perform another generic clock-rate test and do not retry CPAS `+0x1e0`.

The next work is implementation/design analysis for a legitimate Linux ICP
owner and for the minimum ICP lifecycle required only to reproduce the CAMP F0
prerequisite safely. Before any hardware activation, establish from downstream
ICP code and the X1E80100 Linux topology which of the following are mandatory:

1. dedicated ICP platform/runtime-PM device ownership;
2. CPAS/AHB and AXI/interconnect votes;
3. ICP-AHB and ICP core clock sequencing;
4. firmware/SMMU/HFI initialization;
5. shutdown/unwind ordering.

If a safe minimal owner cannot be justified without firmware/CPAS lifecycle,
ICP activation remains blocked and the AOS handoff must remain fail-closed.

## Safety boundary

Unchanged:

- direct CPAS `+0x1e0` access remains quarantined;
- no `/dev/mem`, raw `ioremap`, or diagnostic `readl`/`writel`;
- no SSC activation;
- no deviceless ICP clock activation;
- no raw interconnect manipulation;
- production AOS acquisition remains fail-closed with `-EOPNOTSUPP`.
