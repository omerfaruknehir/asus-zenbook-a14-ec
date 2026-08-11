# Windows CAMP boot PoFx trace

This document records the first boot-time WPR Power trace that captures real
runtime PoFx activation/idle transitions for the ASUS Zenbook A14 UX3407RA
camera-platform ACPI device `\_SB.CAMP` (`ACPI\QCOM0C32\1b`).

It is evidence only. It does not authorize direct CPAS MMIO, SSC activation, or
raw Linux clock/resource manipulation.

## Source trace

The boot trace was recorded with the repository's supported WPR boot autologger
helper. The resulting ETL was 2,708,471,808 bytes. The targeted Kernel-Power
export resolved the boot-specific CAMP token as:

```text
0xffffd30c46ce4b20
```

The targeted export retained 178 events carrying that token.

## CAMP registration

The first runtime sequence is:

```text
23:11:03.856754  Event 302  DevicePreparation
                    Id=\_SB.CAMP
                    Prepared=true

23:11:04.121189  Event 303  DeviceRegistration
                    Status=0
                    ComponentCount=1
                    PowerState=0

23:11:04.121190  Event 310  ComponentRegistration
                    Component=0
                    Active=true
                    IdleState=0
                    IdleStateCount=2

23:11:04.230042  Event 312  ComponentCondition
                    Component=0
                    Active=false

23:11:04.230046  Event 313  ComponentIdleState
                    Component=0
                    IdleState=1

23:11:04.248790  Event 307/317
                    PowerRequired=false
```

This is runtime registration, not end-of-trace rundown.

## Real runtime activation cycles

After registration, component 0 repeatedly transitions into and out of F0.
The observed `Active=true -> Active=false` windows are approximately:

```text
23:11:07.157864 -> 23:11:07.158897     1.032 ms
23:11:09.500209 -> 23:11:09.500228     0.019 ms
23:11:14.267928 -> 23:11:14.267948     0.020 ms
23:11:16.123880 -> 23:11:16.123899     0.019 ms
23:11:16.156064 -> 23:11:17.591294  1435.230 ms
23:11:18.620827 -> 23:11:20.188457  1567.630 ms
23:11:20.223975 -> 23:11:21.235400  1011.425 ms
```

The activation sequence around the long windows is consistently:

```text
PowerRequired=true
  -> DevicePowered
  -> component veto/transition work
  -> IdleState=0
  -> Active=true
```

and the release sequence is:

```text
Active=false
  -> IdleState=1
  -> transition completion
  -> PowerRequired=false
```

This directly confirms that the Windows camera-platform component is genuinely
being activated through PoFx during boot, rather than the earlier traces merely
showing registration rundown.

## Registered component performance sets

CAMP registers seven discrete component performance sets. `Unit=1` is frequency
(Hz) and `Unit=2` is bandwidth (bits/s) in the Windows PoFx API.

The boot-time registration reports `CurrentState=0` for every set:

| Set | Name | Unit | State 0 value |
|---:|---|---|---:|
| 0 | `cam_cc_cci_0_clk` | Hz | 37,500,000 |
| 1 | `cam_cc_cci_1_clk` | Hz | 37,500,000 |
| 2 | `NRT_BANDWIDTH` | bit/s | 12,000,000,000 |
| 3 | `RT_COMP_BANDWIDTH` | bit/s | 38,000,000,000 |
| 4 | `cam_cc_camnoc_axi_rt_clk` | Hz | 400,000,000 |
| 5 | `cam_cc_camnoc_axi_nrt_clk` | Hz | 400,000,000 |
| 6 | `CAM_PRLD` | opaque | 0 |

This corrects the earlier assumption that entering CAMP F0 immediately means
CAMNOC RT/NRT at 300 MHz and bandwidth at the previously inferred low default.
The runtime trace shows that the component is registered at the high state-0
values and that selected sets are lowered later by explicit performance-state
requests.

`CAM_PRLD` remains treated as Privacy LED evidence, not as an ownership rail.

## Decoding Event 325

Kernel-Power Event 325 carries one or more `PO_FX_PERF_STATE_CHANGE` records.
All CAMP sets in this trace are discrete (`Type=0`), so each record is decoded as
`Set` plus `StateIndex`; the unused padding/high union bytes are ignored.

During the longest observed F0 window (`23:11:18.620827` through
`23:11:20.188457`) Windows issued eight requests and every matching Event 327
reported `Succeeded=true`:

| Time | Set | Requested state | Registered value |
|---|---:|---:|---:|
| 23:11:18.802227 | RT bandwidth (3) | 24 | 500,000,000 bit/s |
| 23:11:18.802298 | CAMNOC RT (4) | 3 | 300,000,000 Hz |
| 23:11:18.948028 | RT bandwidth (3) | 21 | 1,100,000,000 bit/s |
| 23:11:19.050719 | NRT bandwidth (2) | 36 | 100,000,000 bit/s |
| 23:11:19.174921 | RT bandwidth (3) | 23 | 700,000,000 bit/s |
| 23:11:19.175051 | CAMNOC RT (4) | 3 | 300,000,000 Hz |
| 23:11:19.232978 | RT bandwidth (3) | 26 | 300,000,000 bit/s |
| 23:11:20.033228 | NRT bandwidth (2) | 36 | 100,000,000 bit/s |

No corresponding dynamic request for CAMNOC NRT, CCI0, CCI1, or `CAM_PRLD` is
present in this window.

The trace therefore distinguishes two different things that had previously
been conflated:

1. the prerequisite state in which PoFx first brings CAMP component 0 into F0;
2. later workload-specific performance votes issued while the component is
   already active.

The CPAS AON mux store in `qccamplatform8380.sys` occurs only after
`PoFxActivateComponent(..., component 0, flags 1)` returns. Consequently the
state that matters for safe ownership handoff is the first category, not merely
the later reduced performance votes.

## End-of-trace rundown

At `23:12:16.607` the trace contains the expected rundown records:

- Event 304 device-registration rundown;
- Event 311 component-registration rundown (`Active=false`, `IdleState=1`);
- Event 322/324 performance-set rundown;
- Event 320 identifies the device as
  `Qualcomm(R) Spectra(TM) 695 ISP Camera Platform Device (\_SB.CAMP)` with
  instance `ACPI\QCOM0C32\1b`.

These are explicitly separated from the runtime transitions above.

## Next evidence boundary

Do not retry direct CPAS `+0x1e0` access yet.

The next offline step is to resolve the boot-trace tokens for CAMP's known ACPI
power dependencies and correlate their runtime transitions against the two long
CAMP F0 windows. In particular, inspect `QCOM0C17`, `QCOM0C2B`, and `QCOM0C0C`,
as well as the AOS/HPS devices where present.

Only after that correlation should another Linux framework-managed prerequisite
experiment be designed. ICP remains blocked until a legitimate Linux device
owner/runtime-PM lifecycle exists.
