# Windows AOS-host CAMP boot windows

This document closes the provider-correlation pass over the existing Windows boot
WPR Power trace for the ASUS Zenbook A14 UX3407RA. It follows
`WINDOWS-CAMP-BOOT-POFX-TRACE.md` and
`WINDOWS-CAMP-BOOT-DEPENDENCY-CORRELATION.md`.

This is evidence only. It does not authorize direct CPAS MMIO, SSC activation,
or deviceless Linux resource manipulation.

## Source

The source ETL is:

```text
A14-Camera-Platform-Boot-PoFx-Trace-20260807-231205
camera-platform-boot-pofx.etl
size=2708471808 bytes
```

The AOS UMDF host is PID 8288 (`WUDFHost.exe` with
`qcAlwaysOnSensing.dll`). The boot-specific CAMP token is:

```text
0xffffd30c46ce4b20
```

A trace-specific known-window exporter queried only PID 8288 in three narrow
intervals around the already-proven CAMP requests. It retained 118 events:

```text
window 1: 44
window 2: 68
window 3: 6
total:   118
```

Provider counts were:

```text
64  Microsoft-Windows-Kernel-Power
37  Microsoft-Windows-Kernel-Processor-Power
14  classic kernel system-trace events
 3  Microsoft-Windows-Kernel-Process
```

The 14 unnamed events resolve by provider GUID to the classic NT kernel Thread
and PerfInfo system-trace classes. No retained event is a Qualcomm/WUDF/AOS
provider record naming `SET_AOS_CONFIG`.

## Exact AOS-host CAMP timings

The three requests have two distinct shapes.

### Window 1

```text
23:11:14.2672869  PID 8288  PowerRequired=true
23:11:14.2679277  PID 4     component 0 Active=true
23:11:14.2679480  PID 8288  component 0 Active=false
23:11:14.2890928  PID 8288  PowerRequired=false
```

Relative to the request:

```text
Active=true          +0.6408 ms
Active=false         +0.6611 ms
PowerRequired=false +21.8059 ms
```

The observed `Active=true -> Active=false` interval is about 20.3 microseconds.

### Window 2

```text
23:11:16.1216696  PID 8288  PowerRequired=true
23:11:16.1238798  PID 4     component 0 Active=true
23:11:16.1238991  PID 8288  component 0 Active=false
23:11:16.1454716  PID 8288  PowerRequired=false
```

Relative to the request:

```text
Active=true          +2.2102 ms
Active=false         +2.2295 ms
PowerRequired=false +23.8020 ms
```

The observed `Active=true -> Active=false` interval is about 19.3 microseconds.

### Window 3

```text
23:11:20.2234113  PID 8288  PowerRequired=true
23:11:20.2239747  PID 4     component 0 Active=true
23:11:21.2353997  PID 4     component 0 Active=false
23:11:21.2513344  PID 4     PowerRequired=false
```

Relative to the request:

```text
Active=true           +0.5634 ms
Active=false        +1011.9884 ms
PowerRequired=false +1027.9231 ms
```

The third request therefore keeps CAMP component 0 active for approximately
1.011425 seconds, unlike the two very short earlier activations.

## What the PID-8288 window export adds

The export does not reveal a hidden user-mode event that identifies the exact
`SET_AOS_CONFIG` call. Around the requests it mainly records:

- Kernel-Power `PowerRequired`, device-power and component-state bookkeeping;
- component veto-mask transitions;
- Kernel-Processor-Power veto accounting;
- classic NT kernel Thread/PerfInfo events;
- a small number of Kernel-Process thread-start events.

The first two windows also contain thread creation/activity in PID 8288, but the
recorded thread entry points resolve to normal runtime/system DLL entry points,
not directly to `qcAlwaysOnSensing.dll`. They therefore do not identify the
specific AOS routine.

In the third window PID 8288 emits the CAMP request and then has no retained
user-mode provider event that explains the roughly one-second hold. The later
component idle and `PowerRequired=false` completion execute in PID 4/System.

## Relationship to static disassembly

Static analysis independently proves that the camera-platform
`SET_AOS_CONFIG` path performs:

```text
first platform reference
  -> PoFxActivateComponent(PoHandle, 0, 1)
  -> PlatformPowerState = ON
  -> CPAS AON mux store
  -> release platform reference
  -> PoFxIdleComponent(PoHandle, 0, 1)
```

The runtime trace now proves that the real `qcAlwaysOnSensing.dll` host does
request CAMP through PoFx. However, because the WPR Power profile does not
capture a Qualcomm/WUDF event that names the IOCTL, timing alone cannot prove
which of the three PID-8288 windows contains the `0x101` route-to-AOS store or
the `0x000` restore-to-AP store.

The two ~20-microsecond component-active intervals are compatible with a very
short synchronous platform operation, but that is only a timing inference and
must not be treated as proof of the mux write. The approximately one-second
third activation is qualitatively different and may represent a longer-lived
AOS camera operation or another concurrent platform reference.

## Trace limitations

The boot trace dropped 235691 events. Positive retained CAMP transitions are
valid evidence, but an absent provider/resource event cannot be treated as
proof that it did not occur.

The WPR Power profile also was not configured specifically for Qualcomm AOS WPP
logging. Repeatedly rescanning this same 2.7 GB ETL is therefore no longer a
useful way to discover the exact user-mode `SET_AOS_CONFIG` boundary.

## Closed offline boundary for this ETL

The existing boot ETL has now established:

1. the boot-specific CAMP PoFx token;
2. real CAMP registration and runtime activation cycles;
3. the process identity of the AOS, HPS and Camera Frame Server clients;
4. separation of Camera Frame Server performance votes from AOS requests;
5. the three exact PID-8288 CAMP lifetimes;
6. absence of a retained Qualcomm/WUDF event directly naming the AOS platform
   IOCTL in the current Power-profile capture.

Do not perform further expensive variants of whole-file PID/provider scanning on
this same ETL unless a new concrete query is identified.

## Safety boundary and next evidence

Direct CPAS `+0x1e0` MMIO remains quarantined. SSC activation remains blocked.
ICP remains blocked until Linux has a legitimate device/runtime-PM owner.

The next useful evidence should come from either:

- offline recovery of the WPP/control GUID and trace configuration used by
  `qcAlwaysOnSensing.dll`, followed by a small targeted Windows trace around a
  normal supported AOS transition; or
- additional static mapping of the Windows PEP/CAMP resource sequence to Linux
  framework-owned resources.

A new Linux register-access experiment is not justified by this window export.
