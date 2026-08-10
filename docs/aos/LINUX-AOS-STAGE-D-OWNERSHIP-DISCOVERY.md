# Linux AOS Stage D ownership discovery

This document tracks the next evidence boundary after the ASUS Zenbook A14
UX3407RA / X1E80100 full-F0 owner test completed successfully.

## Stage C result

The isolated real-owner Stage C diagnostic was run on hardware twice. Both
attempts:

- acquired CCI0 and CCI1 at 37.5 MHz through their device-owned hold API;
- established CAMNOC RT/NRT at 300/300 MHz;
- established CPAS/Core/Fast AHB at 80/80/100 MHz;
- established ICP AHB / ICP at 80/400 MHz;
- held the target state for 250 ms;
- restored ICP exactly;
- released both CCI owners with `ret=0`;
- completed with `ret=0`;
- performed no direct CPAS MMIO and contacted no SSC path.

The first attempt reproduced the already-known CAMNOC parked-rate limitation:
its original 19.2 MHz state could only return to the public 240 MHz rate after
explicit programming. The second attempt began with CAMNOC already at 240 MHz
and restored it exactly.

Stage C therefore closes the named Windows CAMP F0 clock/resource prerequisite.
It does **not** prove that the AP may safely access
`MAIN_CAM_AON_CAM_SEL_CTRL` from Linux.

## Stage D question

Windows `qccamplatform8380.sys` performs the ownership-mux store with an
ordinary ARM64 store after the first CAMP component-0 reference has completed
`PoFxActivateComponent()` and the platform is in F0. No driver-local SCM/QSEE
call exists on the confirmed store path.

The retired Linux direct-access experiments reset the machine before the host
access returned. Because Stage C has now reproduced the named F0 resources, the
remaining question is:

> What additional platform ownership, dependency, protection or firmware state
> makes the CPAS camera-ownership window host-accessible on Windows?

The answer must be established before any new mux access is considered.

## Candidate classes

### 1. PEP-equivalent dependency state

The focused Windows correlation now proves that Qualcomm PEP executes an
HLOS ARC/voltage resource transaction and an ICB transaction set inside the
blocking CAMP component-0 activation. The exact CAMP resource payload also
contains an MMCX ARC client vote. The open question is no longer whether a
PEP-side dependency exists, but whether Linux already expresses equivalent
per-client semantics through the CAMCC/genpd hierarchy.

A positive Linux mapping is preferred because it can be represented through an
existing framework owner without introducing raw hardware access.

### 2. Security/firewall ownership

A direct CPU access that resets the platform without a normal ARM64 abort may
indicate a platform protection path rather than a simple missing clock. The
read-only audit therefore records existing kernel messages related to XPU,
firewall, secure-world, SCM and SMMU state. It does not invoke SCM.

The mere existence of `qcom_scm_io_readl()` / `qcom_scm_io_writel()` elsewhere
in Qualcomm Linux is not evidence that this camera register should use those
APIs. Windows directly stores to the mapped window, so an SCM-based Linux write
must not be invented without machine-specific evidence.

### 3. Resource/ownership mismatch

The CPAS window currently enters Linux through the machine CAMSS resource list
because CAMSS is the closest Linux owner for the Windows CAMP platform object.
The audit records `/proc/iomem`, CAMSS platform resources and DT ownership to
check whether another Linux device already claims or describes the same window.

## Read-only Stage D audit

`scripts/a14-aos-stage-d-owner-audit.sh` collects the following without changing
hardware state:

- CAMSS runtime-PM status and platform resource table;
- `/proc/iomem` overlap with the CAMP/CPAS-top window;
- CAMSS DT `reg-names`, clock names, power-domain names and interconnect names;
- debugfs genpd, clock and interconnect summaries when available;
- kernel messages for camera/security/ownership clues;
- presence of the Qualcomm SCM driver without calling it;
- firmware ACPI DSDT/SSDT tables when the current Linux boot exposes them;
- optional ACPICA disassembly and hits for `CAMP`, `AONC`, `QCOM0C32`,
  `QCOM0D06`, `QCOM0C17`, `_DEP`, `_PR0`, `_PR3`, `_PS0`, `_PS3`, `_DSM` and
  `OperationRegion`.

The script explicitly performs no camera enumeration, module loading, service
changes, clock changes, power-domain changes, SSC operation or CPAS access.

A focused follow-up audit resolves the CAMCC parent-domain and OPP properties
needed to compare Linux with the newly proven Windows MMCX ARC vote. It remains
read-only and does not runtime-resume CAMSS or CAMCC.

## Windows PEP correlation evidence

### Private qcpep trace path

The Windows boot Power trace proves that CAMP component 0 can transition through
`PowerRequired=true` to `Active=true`, and identifies the same CAMP token and
seven performance sets used by the camera-platform driver. The WPR Power profile
does not itself enable Qualcomm's private qcpep WPP providers, so the private
resource executor must be observed through the already-running `qcpep-rpmh`
buffering session.

A safe native QUERY+FLUSH snapshot recovered that private WPP traffic. The
records use two provider GUIDs embedded in `qcpep8380.sys`, and raw
`EVENT_RECORD.UserData` decoding shows structured Qualcomm RPMh/interconnect
traffic including `ICB` payloads.

Public Presence Sensing settings and ordinary HumanPresenceSensor reads were
tested as possible CAMP triggers and rejected: they produced no CAMP component
activation and no matching private qcpep activity. Those tests should not be
repeated for this purpose.

### Camera-preview bring-up signature

A normal user-driven Windows camera preview produced a finite qcpep bring-up
burst:

- five-second baseline: 133 private qcpep events, 46 `ICB` records;
- camera-open to visible-preview interval: 1,686 events, 553 `ICB` records;
- following five-second steady-preview interval: only 36 events, 12 `ICB`
  records.

The first private qcpep activity began approximately 442.5 ms after the manual
camera-open marker. Named `vdd_arc_hlos` and `PPP_DRV_HLOS` records appeared in
camera bring-up and teardown but not in the baseline or steady-preview window.
The first preview capture lacked a completed WPR ETL, so those names alone could
not establish their position relative to CAMP `PoFxActivateComponent()`.

### Focused CAMP activation correlation

A second activation-only run preserved both the WPR Power ETL and the private
qcpep buffer while the normal Camera preview remained active. The sustained
CAMP activation is:

```text
08:54:25.6813981  CAMP PowerRequired=true
08:54:25.6813990  CAMP PowerRequired=true (paired event)
08:54:25.6814032  component operation begins
08:54:25.6816451  qcpep vdd_arc_hlos request sequence begins
08:54:25.6817301  qcpep ICB request sequence begins
08:54:25.6819198  qcpep vdd_arc_hlos completion/result record
08:54:25.6819301  CAMP PEP work ends
08:54:25.6819321  CAMP IdleState=0
08:54:25.6819363  CAMP Active=true
```

`PowerRequired=true` to `Active=true` is approximately 538.2 us. Sixty-three
private qcpep records fall inside that exact blocking interval. The first
`vdd_arc_hlos` record occurs about 247.0 us after the request, the first `ICB`
request about 332.0 us after it, and the `vdd_arc_hlos` completion/result record
about 521.7 us after it. This proves that HLOS ARC/voltage-resource processing
and an associated ICB transaction set execute before CAMP becomes active.

`PPP_DRV_HLOS` is **not** part of this blocking prerequisite: its first
camera-open-side activity begins roughly 106.6 ms after CAMP is already active.
It remains camera-correlated but is deprioritized for the CPAS-host-access
question.

### Exact CAMP MMCX resource

The A14-selected `CAMP_RES_QRD.bin` FSTATE 0 begins with an `NPARESOURCE` named:

```text
/arc/client/rail_mmcx
```

The resource carries scalar `0x40`. FSTATE 1 contains the same client with
scalar `0`. Linux's Qualcomm RPMh power-domain ABI defines regulator level 64
(`0x40`) as `LOW_SVS`, so the combined binary and ABI evidence strongly
identifies the Windows CAMP resource as an MMCX LOW_SVS ARC client vote, with
FSTATE 1 dropping that vote. The same CAMP F0 resource sequence then enables
`cam_cc_titan_top_gdsc`.

This interpretation concerns the **client vote**, not merely the instantaneous
aggregate rail level.

## Linux CAMCC/MMCX comparison

The prior normal-boot Linux audit already showed:

```text
cam_cc_titan_top_gdsc   off
mmcx                    on   performance=192
```

with display/DisplayPort consumers holding MMCX while CAMSS/Titan-top were
suspended. Therefore the Windows result does **not** establish a simple
"MMCX voltage too low on Linux" failure. The aggregate Linux rail was already
above LOW_SVS in that audit.

Linux also has a legitimate hierarchy for the camera dependency:

- CAMSS names `ife0`, `ife1` and `top` as its three power domains;
- the live CAMSS `top` phandle is CAMCC power-domain index 5,
  `CAM_CC_TITAN_TOP_GDSC`;
- the CAMCC provider has two parent genpd links under its external power-domain
  list;
- Qualcomm common-clock code attaches that provider power-domain list and GDSC
  registration adds parentless CAMCC GDSCs, including Titan-top, beneath the
  provider parents.

Stage C's framework-managed CAMSS runtime resume therefore exercised the
Titan-top/CAMCC parent-domain topology rather than bypassing it.

However, the old audit did **not** capture CAMCC's live DT `required-opps` or
resolve the parent-domain phandles/OPP nodes. It is therefore not yet proven
that Stage C established the same **camera-owned MMCX LOW_SVS performance vote**
as Windows CAMP. An aggregate `mmcx=192` cannot answer that question because a
different consumer may mask a missing camera vote.

The next evidence step is read-only: resolve CAMCC's actual live
`power-domains`, `required-opps`, OPP targets and current genpd performance
states. Only after that mapping is known should another state-changing Linux
diagnostic be considered.

## Gate for a future hardware experiment

A future Stage D hardware action is permitted only after the read-only evidence
identifies a concrete additional owner/dependency transition and that transition
can itself be represented through a legitimate Linux framework owner.

The order remains:

1. prove whether the Windows MMCX ARC client vote already has an equivalent
   Linux CAMCC/genpd representation;
2. if it does not, validate only that newly identified framework-owned
   dependency/state transition by itself;
3. validate it concurrently with the already-proven Stage C full-F0 owner hold;
4. confirm normal cleanup and camera operation;
5. only then reassess whether the Windows ownership store has been reproduced
   faithfully enough to justify a separate, explicitly reviewed mux experiment.

A Stage C success or a high aggregate MMCX rail alone is not sufficient for
step 5.

## Safety boundary

Direct CPAS MMIO remains prohibited.

Until new evidence explicitly changes the boundary:

- no `/dev/mem`;
- no raw `ioremap` of the CPAS window;
- no diagnostic `readl`/`writel` of the ownership mux;
- no guessed `qcom_scm_io_*` replacement for the Windows store;
- no SSC INIT 576 / camera-handshake activation;
- production `qcom_camss_aon_acquire()` remains fail-closed with
  `-EOPNOTSUPP` before ownership access.
