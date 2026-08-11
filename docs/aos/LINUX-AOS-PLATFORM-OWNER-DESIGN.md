# Linux AOS platform-resource ownership design

This document tracks the Linux resource-ownership model for the ASUS Zenbook
A14 UX3407RA / X1E80100 AOS camera path after the framework-managed F0
prerequisite work.

Stages A and B are implemented and compile/static validated. Stage C is prepared
as an isolated diagnostic but has **not** been run on hardware yet. Stage D,
which concerns the actual AP/AOS ownership switch, remains blocked.

Nothing in this document authorizes direct CPAS MMIO or SSC activation.

## Evidence boundary

The evidence currently establishes all of the following:

1. Windows `SET_AOS_CONFIG(state=0)` obtains CAMP component 0 Active/F0 before
   the route-to-AOS operation. The targeted trace placed the successful state-0
   message about 16 microseconds after CAMP became Active.
2. The preserved Windows CAMP FSTATE 0 resources include:
   - CCI0 / CCI1 at 37.5 / 37.5 MHz;
   - CAMNOC RT / NRT at 300 / 300 MHz;
   - CPAS / Core / Fast AHB at 80 / 80 / 100 MHz;
   - ICP AHB / ICP at 80 / 400 MHz.
3. Linux safely held the already-owned subset concurrently for 232.6 ms:
   - CCI0 and CCI1 at 37.5 MHz;
   - CAMNOC RT/NRT at 300/300 MHz;
   - CPAS/Core/Fast AHB at 80/80/100 MHz;
   - normal CAMSS runtime PM, Titan-top genpd and existing CAMSS ICC votes.
4. That combined hold produced no reset, watchdog fault, panic, SError, call
   trace, oops or internal error.
5. X1E80100 Linux already accounts for the Windows-named GCC camera support
   resources and CAMSS interconnects through existing framework owners.
6. Direct Linux access to `CPAS + 0x1e0` remains independently unsafe: both the
   earlier read and the later AP-value-only write reset the platform. The
   production AON provider therefore remains quarantined and returns
   `-EOPNOTSUPP` before direct CPAS access.

The ICP pair was the remaining named FSTATE-0 clock gap. It is now represented
through a legitimate Linux consumer, but it has not yet been activated on this
machine through the new owner path.

## Ownership model

### CAMSS / camera-platform owner

The X1E80100 CAMSS device is the closest existing Linux equivalent of the
Windows CAMP camera-platform resource owner. It already owns the normal camera
platform resources used by the validated prerequisite:

- CAMNOC RT/NRT;
- CPAS/Core/Fast AHB;
- GCC HF/SF AXI consumer clocks;
- `ahb`, `hf_mnoc`, `sf_mnoc` and `sf_icp_mnoc` ICC paths;
- Titan-top through genpd.

Stage A extends the X1E80100 CAMSS consumer clock list with two explicitly
AOS-only resources:

```text
icp_ahb -> CAM_CC_ICP_AHB_CLK
icp     -> CAM_CC_ICP_CLK
```

CAMSS acquires those handles from its own device node. They are not part of
ordinary VFE/CSID streaming tables and ordinary CAMSS runtime PM does not enable
them.

This deliberately avoids both bad alternatives:

- provider-global/deviceless ICP clock manipulation; and
- inventing an incomplete functional ICP device merely to own two CAMP F0
  clocks.

Qualcomm downstream stacks do have a full ICP functional device with CPAS,
firmware and HFI lifecycle, but current Windows evidence does not show ICP
firmware/HFI boot as part of the ownership-switch prerequisite. Porting the full
functional ICP stack is therefore not justified for this experiment.

### CCI owners

CCI0 and CCI1 remain owned by `i2c-qcom-cci`; their clocks are not duplicated
into CAMSS.

Stage B adds a small exported CCI platform-hold API:

```text
qcom_cci_platform_hold_get(dev, rate)
qcom_cci_platform_hold_put(dev)
```

The API:

- uses the CCI device's own runtime-PM reference;
- uses the existing device-owned `cci` clock handle;
- requires the requested rate to round exactly;
- reference-counts same-rate users;
- rejects a conflicting hold;
- rejects a new hold while a normal I2C transfer is active;
- rejects normal I2C transfers while a hold is active;
- restores the exact pre-hold rate on final release.

Because CCI timing programming assumes a particular source clock, transfer
exclusion is not optional: normal transactions must not overlap a temporary
37.5 MHz platform hold.

Stage B hardening also latches the CCI owner fail-closed if exact restoration
fails. A faulted owner rejects later holds and normal I2C transfers until an
explicit unbind/reboot instead of operating with uncertain timing.

There is still **no production CAMSS/AOS caller** for this API.

## Intended final transaction

If all prerequisite stages eventually pass, the resource portion of a future
AOS transaction is expected to look like this:

```text
qcom_camss_aon_acquire()
    serialize AP/AOS ownership state
    reject if an AP camera pipeline is active

    acquire CCI0 owner hold @ 37.5 MHz
    acquire CCI1 owner hold @ 37.5 MHz

    pm_runtime_resume_and_get(CAMSS)
        -> existing ICC votes
        -> existing Titan-top/genpd ownership

    hold CAMSS F0 rates
        camnoc_rt_axi     300 MHz
        camnoc_nrt_axi    300 MHz
        cpas_ahb           80 MHz
        core_ahb           80 MHz
        cpas_fast_ahb     100 MHz

    enable CAMSS-owned AOS platform clocks
        icp_ahb            80 MHz
        icp               400 MHz

    [ownership mechanism remains BLOCKED]

    unwind temporary resources in reverse order
```

The actual ownership mechanism is deliberately absent. The production provider
continues to fail with `-EOPNOTSUPP` before any CPAS mux access.

## Implementation status

### Stage A — ICP ownership plumbing: implemented

Implemented by patch 0006:

- CAMSS binding grows from 29 to 31 clock consumers;
- `icp_ahb` and `icp` are appended to the A14 CAMSS clock list;
- CAMSS obtains managed optional handles at probe time;
- production code contains no prepare/enable or rate-change call for the pair;
- AOS acquisition remains fail-closed.

CI applies the production series to current Linux master and rejects production
ICP activation in this stage.

### Stage B — CCI hold API: implemented, no production caller

Implemented by patches 0007 and 0008:

- device-owned runtime-PM/rate hold API;
- exact-rate validation;
- serialization/refcounting;
- normal-transfer exclusion;
- exact restore bookkeeping;
- fail-closed restore-failure latch;
- no production CAMSS/AOS caller.

The patched CCI object and CAMSS integration have been cross-compiled for ARM64
against current upstream Linux.

### Stage C — full-F0 real-owner diagnostic: prepared, not hardware-run

Stage C is the first permitted diagnostic that may actually enable the ICP
clocks. It is intentionally separate from the production AOS path.

The isolated diagnostic:

1. verifies CAMSS is idle and runtime-suspended;
2. obtains CCI0 and CCI1 through their production owner API at 37.5 MHz;
3. resumes CAMSS through normal runtime PM;
4. establishes the already-tested CAMSS 300/300/80/80/100 MHz F0 rates;
5. saves the original ICP rates;
6. sets CAMSS-owned ICP AHB / ICP to 80 / 400 MHz;
7. enables the ICP pair;
8. holds the complete state for 250 ms;
9. disables ICP first and unwinds all owners in reverse;
10. requires exact ICP and CCI restoration;
11. checks normal camera enumeration after the test.

For additional failure safety, a clock is marked for restoration before every
Stage C `clk_set_rate()` attempt. Even if CCF returns an error, cleanup still
attempts to restore the saved rate rather than assuming the hardware was
unchanged.

The only non-exact CAMSS restore result accepted is the already-established
CAMNOC public-RCG limitation: after explicit programming, its boot-time parked
19.2 MHz state can return to 240 MHz instead. That limitation was already seen
in the previous successful CAMSS prerequisite tests.

Stage C performs:

- no `CPAS + 0x1e0` access;
- no raw CPAS `ioremap`;
- no direct diagnostic `readl`/`writel`;
- no `/dev/mem`;
- no SSC load, INIT or activation.

The builder and installer create a separate one-shot test boot. The runner
writes and syncs a persistent `status=started` marker before the first ICP
activation so an abrupt reset remains distinguishable from a returned test.

The Stage C transformation, symbolic DT overlay and safety invariants are CI
validated, and the injected CAMSS plus patched CCI objects cross-compile for
ARM64 against current upstream Linux. **The actual 80/400 MHz ICP hardware hold
has not been run yet.**

### Stage D — ownership mechanism: blocked

Stage D remains blocked even if Stage C succeeds.

A successful full-F0 hold would show that the Windows-named platform resources
can be represented and held through legitimate Linux owners. It would not prove
that direct host access to the CPAS ownership register is safe. The known reset
boundary remains controlling evidence until a supported ownership mechanism is
identified or separately proven.

## Non-goals

This work does not:

- boot ICP firmware;
- initialize HFI;
- create an ICP userspace API;
- use ICP for normal Linux camera processing;
- activate SSC;
- change normal CAMSS streaming behavior;
- access the CPAS ownership mux.

## Safety invariants

Until explicitly revised by new evidence:

- `qcom_camss_aon_acquire()` returns `-EOPNOTSUPP` before ownership MMIO;
- no `/dev/mem`;
- no raw CPAS `ioremap`;
- no diagnostic CPAS `readl`/`writel`;
- no provider-global/deviceless ICP clock enable;
- no raw ICC manipulation;
- no SSC INIT/activation;
- no full ICP firmware/HFI bring-up merely to test the CAMP F0 prerequisite;
- Stage C, if run, occurs only in its isolated one-shot boot and proves only the
  resource prerequisite.
