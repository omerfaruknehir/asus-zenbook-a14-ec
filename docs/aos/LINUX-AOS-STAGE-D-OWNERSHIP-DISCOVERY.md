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

Windows CAMP registration references more than the clock rates reproduced by
Stage C. Existing traces also correlate CAMP with platform dependencies such as
System Manager GPIO, PMIC resources and an unresolved `QCOM0C17` dependency.
The retained Windows events are insufficient to prove whether one of these
resources changes immediately around the ownership store.

A positive dependency mapping would be the preferred explanation because it can
potentially be represented through an existing Linux owner without introducing
raw hardware access.

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

## Windows PEP correlation evidence

The Windows boot Power trace proves that CAMP component 0 can transition through
`PowerRequired=true` to `Active=true`, and identifies the same CAMP token and
seven performance sets used by the camera-platform driver. However, the WPR
Power profile did not enable Qualcomm's private qcpep WPP providers, so that
boot ETL cannot expose the internal PEP/RPMh resource execution.

The installed `qcpep` package has an already-running `qcpep-rpmh` buffering
session. A safe native QUERY+FLUSH snapshot recovered its private WPP traffic.
The records use two provider GUIDs embedded in `qcpep8380.sys`, and raw
`EVENT_RECORD.UserData` decoding shows structured Qualcomm RPMh/interconnect
traffic including `ICB` payloads.

A correlation run on 2026-08-10 tested whether public Windows Presence Sensing
configuration could reproduce the CAMP activation while the qcpep buffer was
available. It did not:

- `HumanPresenceSettings` disabled Wake on Approach, Lock on Leave and Adaptive
  Dimming, then restored the exact original values successfully;
- the complete settings transition ran from approximately 07:52:47.509 to
  07:53:03.732 local time;
- CAMP appeared only in the WPR rundown immediately afterward, with component 0
  explicitly `Active=false`, `IdleState=1`;
- no CAMP `PowerRequired=true` or component-active transition occurred during
  the settings cycle;
- the private qcpep WPP stream contains a 278.649-second no-event interval from
  approximately 07:49:27.812 to 07:54:06.461, which fully contains the settings
  cycle.

Therefore neither changing Presence Sensing settings nor simply reading the
public HumanPresenceSensor data path is a valid CAMP activation trigger for this
Stage D question. Those tests should not be repeated for this purpose.

The next Windows evidence path is a normal user-driven camera preview. The
collector records WPR Power events while the user manually opens and closes a
standard Windows camera application, then snapshots the existing `qcpep-rpmh`
buffer **before** WPR stop. The collector does not launch/control the camera,
send camera-platform IOCTLs, restart devices or access CPAS. This should provide
a narrow timestamp window around an ordinary CAMP component-0 activation while
preserving the private Qualcomm PEP/RPMh traffic from the same interval.

## Gate for a future hardware experiment

A future Stage D hardware action is permitted only after the read-only evidence
identifies a concrete additional owner/dependency transition and that transition
can itself be represented through a legitimate Linux framework owner.

The order would then be:

1. validate the newly identified dependency/state transition by itself;
2. validate it concurrently with the already-proven Stage C full-F0 owner hold;
3. confirm normal cleanup and camera operation;
4. reassess whether the Windows ownership store has now been faithfully
   reproduced enough to justify a separate, explicitly reviewed mux experiment.

A Stage C success alone is not sufficient for step 4.

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
