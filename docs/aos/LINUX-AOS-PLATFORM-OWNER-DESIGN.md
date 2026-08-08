# Linux AOS platform-resource ownership design

This document defines the next implementation boundary after the combined
framework-managed F0 prerequisite test succeeded on the ASUS Zenbook A14
UX3407RA / X1E80100.

It is a design document only. It does **not** authorize direct CPAS MMIO, SSC
activation, ICP firmware boot, deviceless clock manipulation, or a new hardware
test.

## Evidence boundary

The evidence now establishes all of the following:

1. Windows `SET_AOS_CONFIG(state=0)` first obtains CAMP component 0 Active/F0,
   then completes the route-to-AOS operation. The targeted WPP trace placed the
   successful state-0 message about 16 microseconds after CAMP became Active.
2. The preserved Windows `CAMP_RES_QRD.bin` FSTATE 0 sequence explicitly enables
   `cam_cc_icp_ahb_clk` at 80 MHz and `cam_cc_icp_clk` at 400 MHz as CAMP
   component-active resources. FSTATE 1 disables them in the reverse resource
   sequence.
3. Linux safely held, concurrently for at least 232.600 ms:
   - CCI0 and CCI1 at 37.5 MHz;
   - CAMNOC RT/NRT at 300/300 MHz;
   - CPAS/Core/Fast AHB at 80/80/100 MHz;
   - normal CAMSS runtime PM, Titan-top genpd and existing CAMSS interconnect
     votes.
4. No reset, watchdog fault, panic, SError, call trace, oops or internal error
   occurred during that combined hold.
5. X1E80100 Linux already keeps the Windows-named GCC camera AHB/XO support
   clocks available through the clock-controller implementation, and CAMCC's
   GDSC support CBCR is critical. Those are no longer separate AOS test targets.

The remaining named Windows FSTATE-0 clock gap is therefore the ICP pair.

## Why a provider-global ICP clock access is rejected

`CAM_CC_ICP_AHB_CLK` and `CAM_CC_ICP_CLK` exist in the X1E80100 CAMCC provider,
but the current Linux CAMSS device does not list them as consumer clocks and
there is no upstream X1E80100 ICP platform device that owns them.

Calling a provider-global/deviceless clock lookup and enabling those clocks
would reproduce only a register-level side effect, not a Linux device/resource
lifecycle. That is exactly the class of experiment this branch is trying to
avoid.

Qualcomm downstream camera stacks model ICP as a real device with CPAS/SOC
resource management and a firmware/HFI lifecycle. That proves the clocks are
not normally intended to be manipulated as anonymous global resources.

At the same time, Windows CAMP FSTATE 0 only shows the ICP clocks as platform
power resources around the AOS ownership transaction; it does not show an ICP
firmware/HFI boot at the mux boundary. Therefore porting the full downstream ICP
functional driver is not yet justified merely to reproduce the CAMP power
prerequisite.

## Recommended Linux ownership model

Use the existing Linux devices as the resource owners and make the AOS handoff
a short coordinated transaction.

### CAMSS / camera-platform owner

The X1E80100 CAMSS device is the closest existing Linux equivalent of the
Windows CAMP camera-platform resource owner. It already owns:

- CAMNOC RT/NRT;
- CPAS/Core/Fast AHB clocks used by the validated prerequisite;
- GCC HF/SF AXI consumer clocks;
- the `ahb`, `hf_mnoc`, `sf_mnoc` and `sf_icp_mnoc` interconnect paths;
- the Titan-top power domain through genpd.

Extend the X1E80100 CAMSS binding/device-tree clock list with two explicitly
named **AOS-only platform-resource clocks**:

```text
icp_ahb -> CAM_CC_ICP_AHB_CLK
icp     -> CAM_CC_ICP_CLK
```

CAMSS then obtains those handles from its own device node. They must not be
added to normal VFE/CSID streaming clock tables and must not be enabled merely
because ordinary CAMSS runtime PM resumes.

This makes CAMSS a legitimate Common Clock Framework consumer without creating
an incomplete fake ICP functional device.

### CCI owners

CCI0 and CCI1 must continue to own their own clock/runtime-PM transitions. The
existing `i2c-qcom-cci` driver already owns all clocks attached to each CCI node
and enables/disables them from its runtime-PM callbacks.

Do not duplicate the CCI clock phandles into the CAMSS node.

For the eventual transaction, add a small CCI-driver helper that can take a
short platform hold at a requested CCI functional-clock rate while using the
CCI device's own runtime-PM and clock handles. The helper must be reference
counted/serialized and must restore the previous rate on the last release.

The first implementation of that helper remains fail-closed and is compile-only;
it must not yet be called by the AOS path.

## Transaction model

The intended final resource transaction, once every prerequisite has been
separately validated, is:

```text
qcom_camss_aon_acquire()
    lock AP/AOS ownership state
    reject if an AP camera pipeline is active

    acquire CCI0 platform hold @ 37.5 MHz
    acquire CCI1 platform hold @ 37.5 MHz

    pm_runtime_resume_and_get(CAMSS)
        -> existing ICC votes
        -> existing Titan-top/genpd ownership

    hold CAMSS AOS prerequisite rates
        camnoc_rt_axi     300 MHz
        camnoc_nrt_axi    300 MHz
        cpas_ahb           80 MHz
        core_ahb           80 MHz
        cpas_fast_ahb     100 MHz

    enable AOS-only platform clocks
        icp_ahb            80 MHz
        icp               400 MHz

    [ownership mechanism remains BLOCKED]

    unwind all temporary F0 resources in reverse order
```

The actual ownership operation is deliberately absent from this design. The
current provider must continue returning `-EOPNOTSUPP` before any CPAS mux
access.

## Why not a CAMSS child device yet

The current `qcom,x1e80100-camss` binding is a closed schema and does not model
an AOS/CAMP child device. Introducing a child solely to own two clocks would
require a new binding/device-model abstraction before it provides any additional
resource correctness.

Because these two clocks are evidenced as CAMP **platform F0 resources**, not
as an ICP functional/firmware operation at the handoff boundary, attaching them
as optional AOS-only resources to the existing CAMSS camera-platform owner is
the smaller first step.

A dedicated child/auxiliary camera-platform device remains an option if later
evidence shows that CAMSS cannot safely or cleanly coordinate the resource
lifetime.

## Implementation stages

### Stage A — ownership plumbing only

Safe to implement next:

- extend the X1E80100 CAMSS binding with `icp_ahb` and `icp` clock names;
- add the two clock phandles to the X1E80100/Hamoa camera node used by this
  platform;
- have CAMSS acquire the clock handles at probe time;
- add no `clk_prepare_enable()` or `clk_set_rate()` call for them;
- keep `qcom_camss_aon_acquire()` fail-closed with `-EOPNOTSUPP`;
- add CI checks that reject any ICP activation or CPAS MMIO in this stage.

This stage proves that Linux can represent the missing resources with a proper
consumer and that the binding/driver changes apply cleanly.

### Stage B — CCI hold API plumbing only

Then add a CCI-owned hold API with:

- device-owned runtime-PM reference;
- exact-rate validation for 37.5 MHz;
- serialization/refcounting;
- exact restore bookkeeping;
- no caller wired to it yet.

Compile and static-test only.

### Stage C — no-MMIO combined owner diagnostic

Only after A and B are reviewed:

- create a diagnostic-only path using the production owner APIs;
- enable the ICP clocks at 80/400 MHz together with the already validated
  CAMSS+CCI prerequisite state;
- perform **no CPAS mux access and no SSC activation**;
- hold briefly, unwind in reverse and verify normal cameras.

This is the first stage that would touch the ICP clocks and therefore requires a
separate explicit test boot and fail-safe recovery plan.

### Stage D — ownership mechanism

Still blocked until Stage C succeeds and the CPAS access mechanism itself is
re-evaluated. A successful F0 hold does not automatically authorize direct
`CPAS + 0x1e0` access.

## Non-goals

This design does not:

- boot ICP firmware;
- initialize HFI;
- create an ICP userspace API;
- use ICP for normal Linux camera processing;
- activate SSC;
- change normal CAMSS streaming behavior;
- access the CPAS ownership mux.

## Safety invariants

Until explicitly revised by later evidence:

- `qcom_camss_aon_acquire()` returns `-EOPNOTSUPP` before ownership MMIO;
- no `/dev/mem`;
- no raw `ioremap` for CPAS;
- no diagnostic CPAS `readl`/`writel`;
- no provider-global/deviceless ICP clock enable;
- no raw ICC manipulation;
- no SSC INIT/activation;
- no full ICP firmware/HFI bring-up merely to test the ownership prerequisite.
