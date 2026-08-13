# ASUS Zenbook A14 camera stack

This directory is the integration point for the camera work validated on the ASUS Zenbook A14 UX3407RA.

The rule for this tree is simple: hardware description, power, transport, sensor controls, NVMEM and media-pipeline lifetime handling belong in the kernel. Image processing, 3A policy, calibration interpretation and camera UI belong in userspace.

## Layer split

### Kernel

The kernel patch series under `kernel-patches/camera/` owns:

- Qualcomm X1E80100 CAMSS/CCI/CSIPHY enablement needed by the A14 camera graph;
- OV02C10 RGB sensor wiring on CCI1/I2C1 -> CSIPHY4;
- HM1092 NIR sensor wiring on CCI0/I2C0 -> CSIPHY0;
- the HM1092 V4L2 sensor driver with real exposure, analogue gain, digital gain, VBLANK and pixel-array geometry;
- the standard camera privacy LED relationship;
- the standard PM8550 V4L2 flash/torch relationship for the NIR illuminator;
- the OV02C10 module M24C64-family calibration EEPROM as a read-only `at24`/NVMEM provider at Linux I2C address `0x50`;
- the A14/X1E CAMSS stream-switch fixes that prevent stale CSID state and correctly unwind subdevices when stream start fails;
- the CSIPHY resource-size correction required by the tested A14 camera tree.

No camera stream is started from a suspend hook. The old post-resume one-frame camera primer is intentionally not part of this integration: after the underlying camera/runtime-PM fixes, resume was re-tested repeatedly without it.

### libcamera / SoftISP

The userspace integration under `userspace/libcamera-a14/` owns image-processing policy and camera-specific tuning:

- automatic exposure integration used by the SoftISP pipeline;
- OV02C10 AWB with conservative first-frame initialization;
- two-update fast AWB acquisition followed by the stable slow tracker;
- persistence of the last valid automatic AWB solution across stream/resolution reconfiguration so a new IPA context does not restart from zero/green;
- manual AWB gains, gamma, contrast, saturation, black level, CCM and tone-curve controls;
- per-unit OV02C10 factory flat-field calibration derived from the kernel NVMEM provider;
- a channel-order-independent neutral 17x13 lens-shading map; undocumented EEPROM WB fields are deliberately not guessed or applied;
- local HDR/tone-mapping implementation retained for experimentation but disabled by default;
- the EGL fast-HDR path and CPU quality path used by the experimental HDR implementation;
- sensor tuning for OV02C10 and HM1092.

True multi-exposure sensor HDR is not implemented because no trusted OV02C10 HDR register sequence has been established.

### A14 Manual Camera

`userspace/a14-manual-camera/` is a direct GTK4/libcamera diagnostic and control application. It is not a camera bridge and does not replace PipeWire/libcamera integration.

It provides:

- dynamic camera/role/format/size enumeration;
- processed and raw capture;
- live preview with stride-correct buffer handling;
- generic runtime libcamera controls plus the A14 image-pipeline controls;
- interactive tone-curve/CCM/WB/gamma/contrast/saturation/black-level controls;
- HM1092 IR torch/flash control through the standard V4L2 Flash API;
- safe stream restart when camera, role, format or size changes.

The application does not fabricate HM1092 resolutions or capabilities that the kernel driver does not expose.

## Explicitly excluded

The integrated stack does **not** include:

- privacy-LED suppression or bypass;
- the old userspace post-resume camera-prime hook;
- Aegis-specific camera interfaces;
- the experimental custom CCI synchronizer;
- guessed OV02C10 EEPROM WB semantics;
- invented sensor-HDR register programming;
- Windows runtime dependencies.

Windows camera files were used only as one-time reverse-engineering evidence. Runtime Linux calibration comes from the physical module EEPROM through kernel NVMEM.

## Current branch

The complete integration is staged on `agent/a14-camera-kernel-integration`, based on the already-tested `agent/camss-camera-switch-race` branch.
