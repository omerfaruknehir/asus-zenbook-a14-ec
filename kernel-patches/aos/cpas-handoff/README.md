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
masters, CCI clocks and the ICP clock pair.

## Linux prerequisite comparison

CAMSS runtime PM already retains the named `top` power domain and raises the
four configured ICC paths. The X1E80100 CAMSS binding also exposes the seven
Linux-visible platform clocks used by the earlier safe diagnostics:

- `camnoc_rt_axi`
- `camnoc_nrt_axi`
- `cpas_ahb`
- `core_ahb`
- `cpas_fast_ahb`
- `gcc_axi_hf`
- `gcc_axi_sf`

The combined framework-managed prerequisite test subsequently held CAMSS, both
CCI controllers and the five Windows-matched CAMSS rates concurrently for
232.6 ms without a reset. The remaining named Windows F0 clock gap was the ICP
pair:

- `icp_ahb` -> `CAM_CC_ICP_AHB_CLK` (Windows default 80 MHz)
- `icp` -> `CAM_CC_ICP_CLK` (Windows default 400 MHz)

Patch 0006 represents those as **AOS-only CAMSS consumer clocks** and obtains
only managed optional handles at probe time. Production code contains no
prepare/enable or rate-change operation for either ICP clock.

Patch 0007 adds the matching **CCI-owned platform-hold API**. The helper uses
the CCI device's own runtime-PM and `cci` clock handle, requires an exactly
roundable rate, reference-counts same-rate holds, restores the pre-hold rate on
the final put, and prevents normal I2C transfers from overlapping a platform
hold. No production CAMSS/AOS caller is wired to it.

Patch 0008 hardens that API fail-closed: a failed exact restore latches the CCI
owner faulted so normal I2C cannot resume with uncertain timing.

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
6. `0006-media-qcom-camss-own-aos-icp-platform-clocks.patch`
   adds the AOS-only `icp_ahb` / `icp` consumer handles without activating
   either clock.
7. `0007-i2c-qcom-cci-add-platform-clock-hold-api.patch`
   adds compile-only CCI runtime-PM/rate ownership plumbing without wiring a
   camera-platform caller.
8. `0008-i2c-qcom-cci-fail-closed-on-hold-restore-error.patch`
   keeps CCI transfer access blocked if exact rate restoration ever fails.

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
- The ICP pair is represented only through CAMSS-owned optional clock handles;
  production code does not prepare, enable or set their rate.
- The CCI platform-hold API has no production caller.
- Normal CCI transfers cannot overlap a platform hold; a failed exact restore
  leaves that CCI owner faulted/fail-closed.
- No boot-time register script, `/dev/mem` access, raw CPAS `ioremap`, or
  userspace MMIO workaround is permitted.
- The former write-capable Stage 3/4 diagnostics remain retired.

## Stage C — isolated real-owner F0 diagnostic

Stage A/B are now represented and compile/static validated. The next permitted
Linux hardware experiment is the isolated Stage C prerequisite test. It is the
**first diagnostic that may actually enable the ICP clocks**, and it still:

- performs no CPAS mux MMIO;
- never loads or contacts `qcom_ssc_hpd`;
- uses CAMSS's real `icp_ahb` / `icp` consumer handles;
- uses the CCI driver's exported owner API for both 37.5 MHz holds;
- recreates the already validated CAMSS 300/300/80/80/100 MHz state;
- programs ICP AHB / ICP to 80/400 MHz;
- holds the complete state for 250 ms;
- disables/restores ICP before releasing the other owners;
- requires exact ICP and CCI restoration;
- tolerates only the already-known CAMNOC 19.2 -> 240 MHz parking limitation;
- checks normal camera enumeration after the hold.

The build path itself does not activate hardware:

```bash
bash ./scripts/a14-aos-f0-icp-owner-diag-build.sh
bash ./scripts/a14-aos-f0-icp-owner-diag-install-test.sh
```

The installer creates a one-shot GRUB entry and preserves the existing HM1092
DTB by applying a symbolic CAMSS overlay that adds `cpas-top` plus the complete
31-clock consumer list. It refuses a base DTB without `camcc` and `gcc` symbols.

After explicitly booting that isolated entry, the hardware trigger is still
manual:

```bash
bash ./scripts/a14-aos-f0-icp-owner-diag-run.sh
```

The runner writes and syncs a persistent `status=started` marker before the
first real-owner ICP activation. If the platform resets during the 250 ms hold,
the next normal boot therefore preserves evidence that the operation did not
return.

A successful Stage C result would prove only that the full Windows-named F0
resource prerequisite can be held through legitimate Linux owners. It still
would **not** authorize direct `CPAS + 0x1e0` access or SSC activation.
