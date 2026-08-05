# X1E80100 CAMSS AOS ownership handoff

This directory contains the next core-kernel patch series for the ASUS Zenbook
A14 human-presence path.

## Purpose

Windows configures `CPAS_TOP_CPAS_0_MAIN_CAM_AON_CAM_SEL_CTRL` before sending
SSC camera-handshake INIT 576. Linux currently skips that operation, so QMI and
SUID discovery succeed but ACK 832 never arrives.

The series adds a proper CAMSS-owned handoff rather than mapping the physical
address in the SSC/IIO driver.

## Patch order

1. `0001-dt-bindings-media-qcom-x1e80100-camss-add-cpas-top.patch`
   describes the missing CPAS-top MMIO resource.
2. `0002-media-qcom-camss-add-aon-ownership-handoff.patch`
   maps the resource, powers it, controls the AP/AON mux, and arbitrates normal
   V4L2 pipelines against AOS ownership.
3. `0003-arm64-dts-qcom-hamoa-add-cpas-top.patch`
   adds the `0x0ac19000 + 0x0c000` resource through an A14-specific DTS include
   in Ubuntu's camera-enabled X1E kernel tree.

After booting a kernel containing those patches, build the repository's SSC
development module with `AOS_CAMSS_HANDOFF=1`. The guarded integration in
`kernel/aos/qcom_ssc_hpd_camss.c` obtains the CAMSS provider, creates a device
link, switches ownership before INIT 576, and restores it on every exit path.
Default module builds remain discovery-only and do not reference the provider.

## Applying to a kernel source tree

```bash
./kernel-patches/aos/cpas-handoff/apply.sh /path/to/linux-source
```

The source tree must contain Ubuntu's camera-enabled `camss: isp@acb7000` node.
The script checks every patch before modifying the tree and refuses an already
patched, incomplete, or incompatible source tree.

## Safety invariants

- No hard-coded `ioremap()` in the HPD driver.
- No `/dev/mem`, debugfs write, userspace daemon, or boot-time register script.
- AP camera preparation is rejected while AOS owns the mux.
- AOS acquisition is rejected while any AP camera pipeline is prepared.
- `0x101` is read back before SSC INIT is allowed.
- `0x000` is restored before clocks/power are released.
- Failure, suspend, service loss, and unload all restore the AP path.

## Current validation boundary

The patch series is kept separate from the installed EC package and from
automatic module loading. It must compile against the Ubuntu X1E kernel source,
pass DT schema validation, boot with both cameras enumerating, and then produce
ACK 832 before it is considered ready for persistent installation.
