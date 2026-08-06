# X1E80100 CAMSS AOS ownership handoff

This directory contains the experimental core-kernel work for the ASUS Zenbook
A14 human-presence camera path.

## Confirmed protocol state

Linux can discover the SSC `camera_handshake`, `human_presence_detect`, and
`camera_face_detect` SUIDs, but camera-handshake INIT 576 does not receive ACK
832 in the normal AP-owned camera state.

Windows configures `CPAS_TOP_CPAS_0_MAIN_CAM_AON_CAM_SEL_CTRL` before sending
INIT 576. Reverse engineering identified these values:

- `0x00000101`: route the path to AOS
- `0x00000000`: route the path to the AP

The register was identified at offset `0x1e0` in the firmware-described
`0x0ac19000 + 0x0c000` camera-platform window.

## Hardware validation boundary

Direct Linux access to that register is not safe on this machine.

- Runtime PM alone returned successfully.
- The staged CPAS-clock-only path returned successfully.
- A register read caused an abrupt platform reset.
- Stage 3 then performed only `writel(0x000)`—the already expected AP value,
  with no readback and no SSC traffic—and the platform reset before the sysfs
  write returned.

Therefore this is not a read-only-versus-write-only problem. Direct host MMIO
access to the AON mux is quarantined. **Do not run the former Stage 4 AON
switch/restore test.**

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

Always apply the complete series with:

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

## Next investigation

The next step is evidence gathering, not another MMIO attempt. Determine what
`qccamplatform8380.sys` or its dependent Windows camera stack does before the
register operation: secure/XPU authorization, a firmware-mediated request,
additional CPAS/CAMNOC power sequencing, or another platform ownership call.
Any replacement backend must be proven non-resetting before the quarantine is
removed and before SSC INIT 576 is sent.