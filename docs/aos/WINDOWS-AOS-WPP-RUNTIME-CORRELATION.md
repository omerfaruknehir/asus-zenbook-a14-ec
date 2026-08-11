# Windows AOS WPP runtime correlation

This document correlates the targeted `qcAlwaysOnSensing.dll` WPP capture with
CAMP Kernel-Power events from the same ETL. It follows
`WINDOWS-AOS-WPP-STATIC-TRACE.md`.

This is evidence only. It does **not** authorize direct CPAS MMIO, SSC
activation, deviceless ICP clock manipulation, or replay of the Windows camera
platform IOCTL from Linux or from a diagnostic utility.

## Source capture

The targeted trace was collected on 2026-08-08 using
`scripts/a14-windows-aos-wpp-trace.ps1` and contains a 6,488,064-byte ETL.
The collector enabled only:

- classic WPP provider `{DDF06AD3-2B53-4825-B2C6-B9CAE6E680C1}` from
  `qcAlwaysOnSensing.dll`;
- `Microsoft-Windows-Kernel-Power`.

The AOS UMDF host in this Windows session is:

```text
WUDFHost.exe PID 8472
qcAlwaysOnSensing.dll 4934.953.0.0
```

The monitor-power action markers are:

```text
trace_started          19:35:35.9780165 +03:00
action_before          19:35:53.4110017 +03:00
display_off_requested  19:35:54.9038247 +03:00
display_off_returned   19:35:55.0520659 +03:00
action_after           19:36:03.1058990 +03:00
trace_stopped          19:36:04.1627049 +03:00
```

Presence Sensing woke the display automatically because the camera was not
covered. That did not invalidate the capture: the resulting transition exercised
the real AOS configuration path and produced the WPP state-0 success message.

## Decisive route-to-AOS correlation

The CAMP DeviceNode/token used by PID 8472 in this trace is:

```text
0xffffc988575ec010
```

Static disassembly documented in `WINDOWS-AOS-WPP-STATIC-TRACE.md` establishes
that WPP message **273** is emitted on the successful
`DeviceIoControl(... IOCTL_KMD_CAMERA_PLATFORM_SET_AOS_CONFIG ...)` branch for
payload `{version=1,state=0}`. State 0 routes camera ownership to AOS and the
camera-platform driver then writes the AOS mux value after obtaining its CAMP
platform-power reference.

The targeted runtime trace contains message 273 exactly once. Its timeline is:

```text
19:35:59.793692  Kernel-Power 317  PID 8472  CAMP PowerRequired=true
19:35:59.794243  Kernel-Power 312  PID 4     component 0 Active=true
19:35:59.794259  AOS WPP message 273 PID 8472/TID 8492
19:36:00.797715  Kernel-Power 312  PID 4     component 0 Active=false
19:36:00.813501  Kernel-Power 317  PID 4     CAMP PowerRequired=false
```

Relative timing:

```text
PowerRequired=true -> Active=true       +0.551 ms
Active=true        -> WPP 273 success   +0.016 ms
PowerRequired=true -> WPP 273 success   +0.567 ms
component Active=true duration          ~1.003472 s
PowerRequired lifetime                   ~1.019809 s
display-off request -> route request     ~4.889867 s
```

This is the first direct runtime proof that the approximately one-second
PID-owned CAMP activation is the **successful route-to-AOS path**. The earlier
boot trace had shown the same long-window shape but could only classify it as an
AOS-host activation by process identity and timing.

It also directly validates the ordering recovered from
`qccamplatform8380.sys`: CAMP component 0 reaches Active/F0 before the successful
AOS configuration operation completes. In this capture the WPP success trace is
only about 16 microseconds after `Active=true`.

## Earlier short AOS-host cycle

The same trace contains an earlier short PID-8472 CAMP cycle:

```text
19:35:58.238947  Event 317  PID 8472  PowerRequired=true
19:35:58.239336  Event 312  PID 4     component 0 Active=true
19:35:58.239346  Event 312  PID 8472  component 0 Active=false
19:35:58.255740  Event 317  PID 8472  PowerRequired=false
```

Nearby WPP messages include:

```text
19:35:58.219086  message 278
19:35:58.255753  message 283
19:35:58.255754  message 284
```

Static analysis places messages 278 through 284 in the secondary
teardown/restore function that issues `{version=1,state=1}`. The trace therefore
strongly associates this short CAMP cycle with that teardown/restore family,
but the exact state-1 success callsite within messages 278..284 is not yet pinned
down tightly enough to label a specific message as the successful restore.

No WPP message 337, the known successful state-1 message in the main
configuration function, is present in this capture.

## Performance-state observation

Eight CAMP Event-325 performance-state requests are retained in the targeted
trace. They are issued by PID 14836 before the PID-8472 route-to-AOS request.
Their pattern matches the adaptive camera-pipeline performance requests observed
in the earlier boot trace.

There is **no Event-325 performance-state request inside the confirmed
PID-8472 route-to-AOS CAMP lifetime** from `19:35:59.793692` through
`19:36:00.813501`.

This is useful evidence that the route operation itself does not issue a new
explicit PoFx performance-state request at the handoff boundary. It does not,
however, prove the exact CCI/CAMNOC/bandwidth state already in force when the
component becomes active because this small trace does not contain CAMP
registration/rundown Event-323/324 state tables.

The Frame Server's lower dynamic votes therefore remain non-AOS evidence, and
no Linux rate/bandwidth value should be inferred solely from these Event-325
records.

## What is now proven

The Windows evidence chain is now:

```text
qcAlwaysOnSensing.dll state=0 request
        |
        v
CAMP PowerRequired=true
        |
        v
CAMP component 0 Active/F0
        |
        |  ~16 us in this capture
        v
WPP message 273: state=0 SET_AOS_CONFIG succeeded
        |
        v
AOS route remains active for about one second in this transaction
```

Together with the static camera-platform disassembly, this removes the previous
ambiguity about the long CAMP window: it is a real successful route-to-AOS
transaction.

## Linux consequence

The next Linux step is **not** direct access to CPAS `+0x1e0`.

Instead, Linux should first validate the closest framework-managed equivalent of
CAMP component Active/F0 using only legitimate device/runtime-PM owners:

1. runtime-resume CAMSS through its normal device;
2. runtime-resume both CCI controllers through their normal devices;
3. hold CCI0/CCI1 at the already validated 37.5 MHz target;
4. simultaneously hold the already validated CAMSS subset:
   - CAMNOC RT/NRT at 300/300 MHz;
   - CPAS/Core/Fast AHB at 80/80/100 MHz;
   - Linux-managed GCC AXI branches enabled through CAMSS runtime PM;
5. leave CAMSS interconnect voting under the existing Linux framework owner;
6. rely on the existing genpd/MMCX/Titan-top hierarchy;
7. hold briefly, then restore all reversible state;
8. perform no CPAS mux access, no SSC activation and no ICP clock manipulation.

That combined prerequisite hold is only a safety/coverage test. Even if it
succeeds, it does not by itself authorize a direct AON mux access: Windows may
still depend on PEP-only resources or ownership sequencing not represented by
the current upstream Linux device graph.

## Safety boundary

Unchanged:

- direct CPAS `+0x1e0` access remains quarantined;
- no `/dev/mem`, raw `ioremap`, diagnostic `readl`/`writel`;
- no SSC activation;
- no deviceless ICP clock activation;
- no raw interconnect manipulation;
- production AOS acquisition remains fail-closed with `-EOPNOTSUPP`.
