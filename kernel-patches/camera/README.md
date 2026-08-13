# A14 camera kernel patch stack

Apply these to the kernel tree in order. The first two patches predate this integration and are already validated on the A14 camera-switch stress path.

1. `0001-media-qcom-camss-x1e80100-force-csid-reconfigure-on-stream-switch.patch`
   - Prevent stale X1E80100 CSID programming when alternating between the RGB and NIR pipelines.
2. `0002-media-qcom-camss-unwind-subdevs-on-stream-start-failure.patch`
   - Correctly stop already-started subdevices when a later stream-start stage fails.
3. `0003-media-i2c-hm1092-v6.mbox`
   - Upstream-oriented Himax HM1092 binding + sensor driver series. The v6 driver exposes the tested 560x360 RAW10 mode, 180 MHz link frequency, 1296x736 native array, 1280x720 active array, exposure, analogue gain, digital gain, VBLANK and runtime PM.
4. `0004-arm64-dts-qcom-a14-camera-hardware.patch`
   - Board wiring for HM1092 + OV02C10, camera privacy LED, standard PM8550 IR flash, the required camera rails and CSI endpoints.
5. `0005-arm64-dts-qcom-a14-ov02c10-eeprom.patch`
   - Read-only M24C64-family OV02C10 module EEPROM at CCI1/I2C1 address `0x50`, exposed by `at24`/NVMEM.
6. `0006-arm64-dts-qcom-x1e80100-csiphy-resource-size.patch`
   - A14 camera-tree backport fix: CSIPHY0/1/2 register windows are `0x2000`, matching the tested X1E camera tree.

## Kernel vs userspace boundary

The kernel exposes raw hardware capability and calibration bytes. It does not contain AWB, local HDR, tone curves, factory-map decoding, or UI policy. Those live under `userspace/`.

The old resume camera-primer is intentionally absent. It streamed real frames after every resume and therefore legitimately activated the privacy indicator. After the underlying stack fixes, suspend/resume was repeatedly tested without that workaround.

## Base-kernel note

The user's current camera build is based around Linux 7.1.x plus Qualcomm/X1E camera enablement. Some X1E camera infrastructure has moved between Qualcomm/Ubuntu trees and mainline development over time. Treat board and SoC backports independently: do not duplicate a CAMSS/CCI/CAMCC node that is already present in the target kernel.
