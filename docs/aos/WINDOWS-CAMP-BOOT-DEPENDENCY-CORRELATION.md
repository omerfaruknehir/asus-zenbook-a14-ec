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

The post-boot module inventory identifies the real Always-On Sensing UMDF host:

```text
WUDFHost.exe  PID 8288  qcalwaysonsensing.dll
```

Therefore PID 8288, not PID 10252, is the directly observed
`qcAlwaysOnSensing.dll` owner in this boot.

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

The two long PID-10252 windows (`23:11:16.155` and `23:11:18.620`) are therefore
not proven to be the AOS UMDF client. The eight Event-325 performance-state
requests in the second long window are also PID 10252. Until PID 10252 is
identified, those dynamic performance votes must not be labeled AOS-specific.

By contrast, the three PID-8288 requests are directly correlated with the
process hosting `qcAlwaysOnSensing.dll`:

```text
request                  component Active=true      component Active=false      PowerRequired=false
23:11:14.267287           23:11:14.267928            23:11:14.267948             23:11:14.289093
23:11:16.121670           23:11:16.123880            23:11:16.123899             23:11:16.145472
23:11:20.223411           23:11:20.223975            23:11:21.235400             23:11:21.251334
```

Static disassembly already proves that the first camera-platform reference in
`SET_AOS_CONFIG` calls `PoFxActivateComponent(PoHandle, 0, 1)` before the CPAS
AON mux store. These PID-8288 windows are therefore the strongest runtime
candidates for observing that prerequisite path.

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

The positive CAMP registration/activation sequences and the retained client
process IDs are internally coherent and remain useful evidence. However,
negative statements such as "dependency X never transitioned" cannot be made
conclusive from this trace because relevant events could have been dropped.

A new boot trace is not required merely to continue offline identity analysis.
If a future decision depends on proving the absence of a dependency transition,
a lower-volume or larger-buffer boot capture will be required.

## Next offline boundary

Identify PID 10252 from process start/image metadata in the same ETL. This will
separate the two long CAMP/performance-vote windows from the directly observed
PID-8288 `qcAlwaysOnSensing.dll` requests.

Do not retry direct CPAS `+0x1e0` access. Do not activate SSC. ICP remains
blocked until a legitimate Linux device/runtime-PM owner exists.
