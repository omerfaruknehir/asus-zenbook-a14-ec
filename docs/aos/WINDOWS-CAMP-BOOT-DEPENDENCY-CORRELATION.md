# Windows CAMP boot dependency/client correlation

This document follows `WINDOWS-CAMP-BOOT-POFX-TRACE.md` and correlates the
boot-specific CAMP PoFx token with the known AOS/HPS/power dependency devices.
It is evidence only and does not authorize direct CPAS MMIO, SSC activation, or
deviceless Linux resource manipulation.

## Source

The source boot WPR Power ETL is 2,708,471,808 bytes. The targeted dependency
export retained 311 Kernel-Power events after resolving these identifiers:

```text
CAMP      0xffffd30c46ce4b20   ACPI\QCOM0C32\1b / \_SB.CAMP
AONC      0xffffd30c46ce6770   ACPI\QCOM0D06\1f
HPS       0xffffd30c46ce8b20   ACPI\QCOM06D9\... / \_SB.HPS0
QCOM0C2B  0xffffd30c46ae98a0   \_SB.PMIC
QCOM0C0C  0xffffd30c466ee770   \_SB.GIO0
QCOM0C17  unresolved
```

`QCOM0C17` did not resolve to a Kernel-Power DeviceNode/token in this export.
That absence must not be converted into a claim that the PEP dependency is
inactive or irrelevant.

## Critical process-owner correction

The boot process-identity export resolves all three relevant user-mode hosts.

### PID 8288: Qualcomm Always-On Sensing UMDF host

Kernel-Process records show:

```text
23:11:13.345618  WUDFHost.exe PID 8288 created
23:11:13.367932  qcAlwaysOnSensing.dll loaded
```

The DLL is loaded from the installed `qcalwaysonsensing.inf` DriverStore
package. This independently confirms the post-boot module inventory:

```text
WUDFHost.exe  PID 8288  qcAlwaysOnSensing.dll
```

Therefore PID 8288 is the directly observed AOS UMDF client in this boot.

### PID 5560: Qualcomm Human Presence Sensor UMDF host

Kernel-Process records show:

```text
23:11:11.897669  WUDFHost.exe PID 5560 created
23:11:11.916210  qcHumanPresenceSensor.dll loaded
23:11:11.918685  SensorsUtilsV2.dll loaded
23:11:11.927017  SensorsCx.dll loaded
```

This separates the public Human Presence Sensor driver host from the AOS camera
client host.

### PID 10252: Windows Camera Frame Server host

PID 10252 is not an AOS WUDF process. Kernel-Process records identify it as a
system `svchost.exe` instance and show the camera Frame Server stack loading:

```text
23:11:15.773769  svchost.exe PID 10252 created
23:11:15.910763  FrameServer.dll loaded
23:11:15.926955  mfsensorgroup.dll loaded
23:11:16.043019  FrameServerCore.dll loaded
23:11:16.067735  QcDeviceMFT8380.dll loaded
23:11:16.072390  Windows.Devices.Sensors.dll loaded
```

The first long PID-10252 CAMP request starts at `23:11:16.155434`, only about
87.7 ms after Qualcomm's `QcDeviceMFT8380.dll` is loaded. During the second
long window PID 10252 creates child process `FsIso.exe` (PID 14516) at
`23:11:18.727968`. PID 10252 exits normally at `23:11:50.286837`.

This is strong runtime evidence that PID 10252 is the Windows Camera Frame
Server / Qualcomm camera-pipeline host. Consequently the two long PID-10252
CAMP windows and the eight Event-325 performance-state requests in the second
window must not be labeled AOS-specific.

## CAMP request ownership

CAMP `PowerRequired=true` requests are attributed to these process contexts:

```text
23:11:07.157399  PID 4
23:11:09.499764  PID 4
23:11:14.267287  PID 8288
23:11:16.121670  PID 8288
23:11:16.155434  PID 10252
23:11:18.620275  PID 10252
23:11:20.223411  PID 8288
```

The PID-10252 windows are Camera Frame Server activity. The three PID-8288
requests are directly correlated with the process hosting
`qcAlwaysOnSensing.dll`:

```text
request                  component Active=true      component Active=false      PowerRequired=false
23:11:14.267287           23:11:14.267928            23:11:14.267948             23:11:14.289093
23:11:16.121670           23:11:16.123880            23:11:16.123899             23:11:16.145472
23:11:20.223411           23:11:20.223975            23:11:21.235400             23:11:21.251334
```

The final AOS-host request begins only about 19 ms after the preceding Camera
Frame Server window reports `PowerRequired=false` at `23:11:20.204443`. This
ordering is consistent with a transition from ordinary AP camera setup to the
AOS client, but timing alone does not prove that the CPAS ownership-mux store
occurs in that specific third PID-8288 window.

Static disassembly already proves that the first camera-platform reference in
`SET_AOS_CONFIG` calls `PoFxActivateComponent(PoHandle, 0, 1)` before the CPAS
AON mux store. These PID-8288 windows are therefore the strongest runtime
candidates for observing that prerequisite path.

## Performance-state attribution correction

All eight retained Event-325 performance-state requests belong to PID 10252,
which is now identified as the Camera Frame Server host. They describe normal
camera-pipeline workload adaptation, not the AOS UMDF client.

The boot trace still proves that CAMP registers its performance sets with the
state-0 tables documented in `WINDOWS-CAMP-BOOT-POFX-TRACE.md`, but those
registration values must not be conflated with the exact performance state in
force at a later PID-8288 AOS activation.

Because the trace dropped events, and because PoFx performance state can change
independently of component Active/Idle transitions, the exact CCI/CAMNOC/
bandwidth state at the final PID-8288 activation is not proven by the retained
Event-325 subset. In particular, the Camera Frame Server's 300 MHz/lower-
bandwidth requests are not evidence that AOS requires those values, and the
registration state-0 values are not by themselves proof that every later AOS
activation re-enters those maxima.

No new Linux clock, interconnect, ICP, or CPAS-MMIO experiment is authorized by
these performance events.

## HPS state around the AOS-host CAMP requests

HPS component 0 is observed active before every PID-8288 CAMP request:

- HPS becomes `Active=true` at `23:11:13.235106`;
- it is briefly idled at `23:11:14.936886`;
- it becomes `Active=true` again at `23:11:14.976478`;
- no later HPS `Active=false` is present before the CAMP windows ending at
  `23:11:21.251`.

Thus the observed HPS state is already active when `qcAlwaysOnSensing.dll`
requests CAMP. This is correlation, not proof that HPS activation is a CAMP
hardware prerequisite.

## System Manager GPIO state

`ACPI\QCOM0C0C\0` (`\_SB.GIO0`) has substantial component activity during early
boot. Immediately before CAMP registration, components 3, 4, 6, 7, 8, 9, 10,
11, 12, 14, 15 and 16 are activated and most are then idled again.

Using only the observed Event-312 transitions, the latest known active GPIO
component set at each of the three PID-8288 CAMP requests is identical:

```text
{ 3, 6, 7, 15, 16 }
```

There is no observed GPIO component transition at the exact PID-8288 CAMP
activation boundaries. The GPIO state appears established earlier in boot.
Component numbers are not yet mapped to individual CAMP GPIO resources, so no
Linux GPIO action is justified from this evidence.

## PMIC and AONC observations

`QCOM0C2B` / `\_SB.PMIC` resolves to DeviceNode `0xffffd30c46ae98a0`, but the
runtime subset contains no observed component Active/Idle pair correlated with
the PID-8288 CAMP windows.

`QCOM0D06` / AONC resolves to DeviceNode `0xffffd30c46ce6770`, but this export
contains only DeviceRundown identity events for that token and no runtime PoFx
component event. This is consistent with AONC being a UMDF client device rather
than the CAMP PoFx resource owner; it is not evidence that AONC is inactive.

## Trace-drop limitation

`wpr -stopboot` reported:

```text
This trace has dropped 235691 events. Please record this trace again.
```

The positive CAMP registration/activation sequences, module loads, and retained
client process IDs are internally coherent and remain useful evidence. However,
negative statements such as "dependency X never transitioned" or "performance
set Y never changed" cannot be made conclusive from this trace because relevant
events could have been dropped.

A new boot trace is not required merely to continue offline identity/provider
analysis. If a future decision depends on proving the absence of a dependency or
performance transition, a lower-volume or larger-buffer boot capture will be
required.

## Next offline boundary

Inspect events executing in PID 8288 around the three CAMP activation windows.
The goal is to determine whether the existing boot ETL captured a WUDF,
Qualcomm, camera-platform, or related provider event that directly brackets the
AOS `SET_AOS_CONFIG` operation. This remains offline analysis of the existing
ETL.

Do not retry direct CPAS `+0x1e0` access. Do not activate SSC. ICP remains
blocked until a legitimate Linux device/runtime-PM owner exists.
