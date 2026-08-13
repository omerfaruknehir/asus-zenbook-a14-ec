# A14 camera kernel patch stack

Apply the kernel pieces in this order. The first two patches predate the full integration branch and were already exercised by the A14 camera-switch stress tests.

1. `0001-media-qcom-camss-x1e80100-force-csid-reconfigure-on-stream-switch.patch`
   - force fresh X1E80100 CSID programming when switching camera pipelines.
2. `0002-media-qcom-camss-unwind-subdevs-on-stream-start-failure.patch`
   - unwind already-started media subdevices if a later stream-start stage fails.
3. HM1092 v6 binding + sensor driver
   - run `./fetch-hm1092-v6.sh ../hm1092-v6.mbox` to retrieve the upstream-oriented two-patch series;
   - the download is pinned to SHA-256 `34724a360d07c5142b3cb58cdab34eeb095bf4439bb8867f37f02e2579c20c1c`;
   - it provides the real 560x360 RAW10 mode, 180 MHz link frequency, 1296x736 native array, 1280x720 active array, exposure, analogue gain, digital gain, VBLANK and runtime PM.
4. `0003-arm64-dts-qcom-x1-asus-zenbook-a14-ov02c10-rgb.patch`
   - A14 OV02C10 RGB wiring on CCI1/I2C1 -> CSIPHY4, including the standard camera indicator relationship and camera rails.
5. `0004-arm64-dts-qcom-x1-asus-zenbook-a14-hm1092-ir.patch`
   - HM1092 NIR wiring on CCI0/I2C0 -> CSIPHY0, PMIC-M rails and standard PM8550 flash/torch relationship.
6. `0005-arm64-dts-qcom-x1-asus-zenbook-a14-ov02c10-eeprom.patch`
   - read-only 8 KiB OV02C10 module EEPROM at CCI1/I2C1 address `0x50`, exposed by at24/NVMEM.
7. `0006-arm64-dts-qcom-hamoa-camss-csiphy-resource-size.patch`
   - older Hamoa camera-tree correction for the CSIPHY0/1/2 CAMSS register windows (`0x2000`).

## Base-kernel prerequisite

The board patches expect the target kernel to already contain the X1E80100 CAMCC, CCI0/CCI1, CAMSS and CSIPHY nodes. Ubuntu's qcom-x1e camera-capable tree used during bring-up contains that SoC support; plain mainline 7.1 does not contain the complete Hamoa camera DT infrastructure.

Use `check-kernel-prereqs.sh /path/to/linux` before applying the board patches. It exits cleanly only when the expected SoC labels and A14 board file are present.

## Kernel/userspace boundary

The kernel exposes raw hardware capability, media topology, standard controls, the illuminator relationship and raw EEPROM bytes. AWB, tone mapping, lens-shading interpretation and UI policy live under `userspace/`.

The old post-resume camera-primer is not part of this stack. The final hardware/runtime-PM path was re-tested without that workaround.
