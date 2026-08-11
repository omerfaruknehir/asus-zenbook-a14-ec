# CAMP F0 TLMM follow-up after the no-mux SSC handshake timeout

## Status

The full-F0/no-mux discriminator established that the known Linux clock, CCI,
ICP, runtime-PM, genpd and ICC state is not sufficient by itself for the SSC
camera handshake. With that state held for 4.5 seconds, the real
`camera_handshake` request still timed out waiting for ACK 832 while the CPAS
AON ownership mux remained untouched.

The test returned cleanly after the diagnostic HPD module was explicitly
removed: CAMSS, CCI0 and CCI1 returned to runtime suspend and both camera sensors
continued to enumerate.

## Windows control-flow clarification

Static analysis of the matching `qccamplatform8380.sys` separates two Windows
power paths that should not be conflated.

### AOS ownership path

`IOCTL_KMD_CAMERA_PLATFORM_SET_AOS_CONFIG` acquires a camera-platform reference.
On the first reference the helper at image VA `0x140003cd8` calls the component
activation helper at `0x140007aa0`. That helper resolves to:

```text
PoFxActivateComponent(PoHandle, component 0, flags 1)
```

The caller then records `PlatformPowerState = ON`. Only after that state is ON
does the AOS IOCTL choose the route value and store it at CPAS + `0x1e0`:

```text
state 0 -> 0x00000101  (route camera to AOS)
state 1 -> 0x00000000  (restore AP route)
```

The last camera-platform reference clears `PlatformPowerState` and calls the
matching `PoFxIdleComponent` helper.

### Separate PoFxPowerControl path

The driver also contains `CameraKMD_PowerControl`, which invokes
`PoFxPowerControl` with custom GUID:

```text
9942b45e-2c94-41f3-a15c-c1a591c70469
```

and has synchronous/asynchronous completion handling including
`PEP_STATE_ASYNC_PATH_COMPLETE`. Its nearby diagnostics identify this path with
P-state/performance changes (`POWER_CHANGE_P_STATEV2`). The immediate
`SET_AOS_CONFIG` ownership path does not call this routine between component
activation and the CPAS ownership store.

Therefore the current missing prerequisite should not be described simply as
"an unimplemented asynchronous PoFxPowerControl call".

## CAMP F0 resource evidence

The matching `CAMP_RES_QRD.bin` contains a block of `TLMMGPIO` resources in the
same component-resource payload as the camera clocks/interconnect resources.
The camera-relevant candidate GPIO numbers seen in that block are:

```text
96 97 98 99 100 101 102 103 104 105 106
```

There are six additional F-state entries for GPIOs 101-106 after an explicit
`FSTATE` marker.

The raw records contain several small numeric fields after each GPIO number,
but their semantics have not yet been proven. Do not translate those fields
into direction, pull, function or drive-strength labels without independent
evidence.

This matters because the completed Linux Stage-C owner hold reproduced the
known clocks, CCI and ICP resources but did not explicitly reproduce this CAMP
TLMM resource block.

## Next safe discriminator

Before changing pinctrl state, collect the current Linux state for GPIOs 96-106
with:

```bash
bash ./scripts/a14-aos-tlmm-pin-audit.sh
```

The audit is read-only. It:

- reads pinctrl debugfs only when it is already available;
- does not mount debugfs;
- searches the live device tree for camera/AOS string references;
- optionally snapshots matching `gpioinfo` lines;
- reports CAMSS/CCI runtime-PM state;
- does not load SSC/HPD;
- does not change pinmux, GPIO, clock, ICC or power-domain state;
- does not access the CPAS ownership mux.

### Interpretation

If the candidate pins already match a camera/AOS mux state under normal Linux,
TLMM becomes a weaker explanation and the remaining work should focus on the
ownership/protection transition itself.

If one or more of the CAMP-listed pins are unclaimed or in a clearly different
mux state, the next experiment should reproduce only the identified Linux
pinctrl state through the proper pinctrl owner, still without direct CPAS MMIO,
and then repeat the SSC handshake once.

No pin should be modified until its Linux role and the corresponding CAMP field
semantics are known.
