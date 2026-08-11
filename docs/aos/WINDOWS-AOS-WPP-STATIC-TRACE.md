# Windows AOS WPP static trace identity

This document records the static WPP/ETW identity recovered from the installed
`qcAlwaysOnSensing.dll` used on the ASUS Zenbook A14 UX3407RA. It is evidence
only and does not authorize direct CPAS MMIO, SSC activation, or any camera
platform IOCTL replay.

## Classic WPP provider registration

The focused Windows payload shows that `qcAlwaysOnSensing.dll` imports the
classic ETW/WPP APIs:

- `RegisterTraceGuidsW`;
- `UnregisterTraceGuids`;
- `TraceMessage`;
- `GetTraceEnableFlags`;
- `GetTraceEnableLevel`;
- `GetTraceLoggerHandle`;
- `WppAutoLogStart` / `WppAutoLogStop` / `WppAutoLogTrace`.

ARM64 disassembly resolves the WPP initialization path around image VA
`0x180010d98`.

At `0x180010e2c` the DLL loads the imported `RegisterTraceGuidsW` pointer. The
call is prepared as follows:

```text
x0 = 0x180010c60        control callback
x1 = WPP context
x2 = *(0x18012c818)     control-GUID pointer
w3 = 1                  one trace GUID registration
x4 = TRACE_GUID_REGISTRATION[1]
x5 = NULL
x6 = NULL
x7 = registration handle storage
```

During initialization `*(0x18012c818)` is populated with
`0x1800faaf8`. The 16 bytes at that address decode using Windows `GUID` memory
layout to:

```text
DDF06AD3-2B53-4825-B2C6-B9CAE6E680C1
```

This is the classic WPP **control/provider GUID** registered by
`qcAlwaysOnSensing.dll`.

The same pointer is placed into the one-element `TRACE_GUID_REGISTRATION`
array, so this provider registers one trace class from that WPP registration
path.

The corresponding cleanup path calls `UnregisterTraceGuids`, and the DLL also
starts/stops WPP Recorder auto logging through `WppAutoLogStart` and
`WppAutoLogStop`.

## WPP message GUID used by the AOS platform path

The `SET_AOS_CONFIG` path uses the WPP message GUID stored at image VA
`0x1800fab08`. Those bytes decode to:

```text
66E62EB6-C99F-34ED-A782-B77E267F4B2D
```

The nearby trace helpers eventually call classic `TraceMessage`, for which the
message GUID and message number identify the TMF/WPP message independently of
whether the format string can be decoded on the collection machine.

## Message numbers around the platform AOS IOCTL

Static disassembly already proves that the platform AOS operation is
`IOCTL_KMD_CAMERA_PLATFORM_SET_AOS_CONFIG` (`0x002326bb`) with these payloads:

```text
{version=1,state=0} -> route camera ownership to AOS
{version=1,state=1} -> restore camera ownership to AP
```

The first AOS configuration function begins at `0x18000d6d0`. WPP callsites in
that function use message GUID `66E62EB6-C99F-34ED-A782-B77E267F4B2D` and these
message numbers:

```text
267  entry-side trace before platform-handle/config work
268-277  state=0 / route-AOS result and follow-up paths
335-339  state=1 / restore-AP path in the same function
```

Important instruction anchors are:

```text
0x18000d844  stores 8-byte {version=1,state=0} input
0x18000d868  loads IOCTL 0x002326bb
0x18000d86c  DeviceIoControl(state=0)
0x18000da24  WPP message 273 on the successful DeviceIoControl branch

0x18000dbd0  materializes 0x0000000100000001
0x18000dbdc  stores {version=1,state=1}
0x18000dc08  loads IOCTL 0x002326bb
0x18000dc0c  DeviceIoControl(state=1)
0x18000dc5c  WPP message 337 on the successful DeviceIoControl branch
```

A second teardown/restore function beginning around `0x18000df18` also issues
`{version=1,state=1}` at `0x18000e104`/`0x18000e130`; its local WPP message
numbers are `278` through `284`.

These message numbers are valuable even without a TMF file: a targeted WPP
capture can distinguish a successful `state=0` call (message `273`) from a
successful `state=1` call in the main function (message `337`) and from the
separate teardown/restore path.

## Why this replaces broad boot tracing

The existing 2.7 GiB WPR boot trace established the real CAMP PoFx activation
sequence but dropped 235,691 events and did not enable this Qualcomm WPP
provider. Further broad scans of that ETL cannot recover events that were never
recorded.

The correct next capture is therefore a small targeted ETW session that enables:

1. classic WPP provider `{DDF06AD3-2B53-4825-B2C6-B9CAE6E680C1}` at verbose
   level/all flags;
2. `Microsoft-Windows-Kernel-Power` for timestamp correlation with CAMP PoFx.

The user should then perform one normal Windows display off -> on cycle. Static
strings in `qcAlwaysOnSensing.dll` include `DisplayOnConfig`,
`DisplayOffConfig`, and the DLL imports `PowerSettingRegisterNotification`, so
a display transition is the best supported OS action to exercise before any
more invasive experiment.

No direct camera-platform IOCTL is sent by the collector.

## Safety boundary

Unchanged:

- no direct CPAS `+0x1e0` access;
- no `/dev/mem` or raw `ioremap`;
- no diagnostic AON-mux `readl`/`writel`;
- no SSC activation;
- no deviceless ICP clock activation;
- production AOS acquisition remains fail-closed with `-EOPNOTSUPP`.
