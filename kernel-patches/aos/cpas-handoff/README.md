# X1E80100 CAMSS AOS ownership handoff

This directory contains the experimental core-kernel work for the ASUS Zenbook
A14 human-presence camera path.

## Confirmed protocol state

Linux can discover the SSC `camera_handshake`, `human_presence_detect`, and
`camera_face_detect` SUIDs, but camera-handshake INIT 576 does not receive ACK
832 in the normal AP-owned camera state.

Windows configures `CPAS_TOP_CPAS_0_MAIN_CAM_AON_CAM_SEL_CTRL` before the SSC
camera-handshake lifecycle. Reverse engineering identified these values:

- `0x00000101`: route the path to AOS
- `0x00000000`: route the path to the AP

The register was identified at offset `0x1e0` in the firmware-described
`0x0ac19000 + 0x0c000` camera-platform window.

## Hardware validation boundary

Direct Linux access to that register is not safe in the prerequisite state used
by the original experiment.

- Runtime PM alone returned successfully.
- Runtime PM plus `cpas_ahb` and `cpas_fast_ahb` returned successfully.
- A register read caused an abrupt platform reset.
- Stage 3 then performed only `writel(0x000)`—the expected AP value, with no
  readback and no SSC traffic—and the platform reset before the sysfs write
  returned.

Therefore this is not a read-only-versus-write-only problem. Direct host MMIO
access to the AON mux is quarantined. **Do not run the former Stage 4 AON
switch/restore test.**

## Confirmed Windows prerequisite

Static analysis of the exact installed ARM64 driver resolves the store path:

```text
SET_AOS_CONFIG
  -> acquire camera-platform reference
  -> PoFxActivateComponent(component 0, flags 1)
  -> PlatformPowerState = ON
  -> str value, [CPAS base + 0x1e0]
  -> release reference
  -> PoFxIdleComponent(component 0, flags 1) on the last reference
```

The direct register store occurs only after PoFx component 0 has been
activated. The driver performs no readback around the store.

The matching Windows PEP resource graph names Titan-top GDSC, camera core and
CPAS AHB clocks, CAMNOC RT/NRT AXI clocks, GCC camera clocks, interconnect
masters, and performance states.

## Linux prerequisite comparison

CAMSS runtime PM already retains the named `top` power domain and raises the
four configured ICC paths. The original Stage 3 explicitly enabled only two
local clocks.

The X1E80100 CAMSS binding exposes seven direct Linux-visible equivalents for
the Windows base camera-platform clock state:

- `camnoc_rt_axi`
- `camnoc_nrt_axi`
- `cpas_ahb`
- `core_ahb`
- `cpas_fast_ahb`
- `gcc_axi_hf`
- `gcc_axi_sf`

The leading explanation is therefore that Stage 3 accessed the CPAS window
while it was only partially clocked relative to Windows' PoFx state. This is
still a hardware hypothesis; it does not weaken the MMIO quarantine.

## Patch order

1. `0001-dt-bindings-media-qcom-x1e80100-camss-add-cpas-top.patch`
   describes the firmware-reported CPAS-top resource.
2. `0002-media-qcom-camss-add-aon-ownership-handoff.patch`
   adds the CAMSS-owned provider and AP/AOS ownership arbitration.
3. `0003-arm64-dts-qcom-hamoa-add-cpas-top.patch`
   adds the A14-specific resource.
4. `0004-media-qcom-camss-treat-aon-mux-as-write-only.patch`
   records the earlier read-reset result and removes readback.
5. `0005-media-qcom-camss-quarantine-direct-aon-mmio.patch`
   records the write-reset result and makes acquisition fail with
   `-EOPNOTSUPP` before any register access.

Always apply the complete production series with:

```bash
./kernel-patches/aos/cpas-handoff/apply.sh /path/to/linux-source
```

Do not apply only the earlier experimental patches.

## Current safety invariants

- The SSC/IIO consumer never maps the physical CPAS address.
- The production provider does not read or write the AON mux.
- AOS activation fails closed with `-EOPNOTSUPP`.
- The normal AP camera path remains available.
- No boot-time register script, `/dev/mem` access, or userspace MMIO workaround
  is permitted.
- The former write-capable diagnostic builder and installer are retired.
- The safe power probe contains no register access and never contacts SSC.

## Safe prerequisite test

The separate diagnostic patch under `../power-diagnostics/` reproduces the
Linux-visible part of the Windows component-0 power state without accessing the
CPAS window. It:

1. obtains CAMSS runtime PM;
2. retains the existing top-GDSC and ICC state;
3. enables the seven platform clocks listed above;
4. logs their rates and holds them for 250 ms;
5. unwinds all resources in reverse.

Build and install it from a normal boot:

```bash
bash ./scripts/a14-aos-power-diag-build.sh
bash ./scripts/a14-aos-power-diag-install-test.sh
```

Manually select the generated isolated GRUB entry. In that boot, run:

```bash
bash ./scripts/a14-aos-power-diag-run.sh
```

The runner rejects a loaded `qcom_ssc_hpd`, verifies camera nodes are idle,
records a persistent marker before the operation, captures the kernel log, and
checks normal camera enumeration after the resources are released.

A successful result proves only that the expanded power prerequisite is safe.
It does **not** authorize another mux read or write.
