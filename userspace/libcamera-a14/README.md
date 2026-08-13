# libcamera A14 integration

This directory contains the image-processing and tuning layer for the ASUS Zenbook A14 camera stack. Raw hardware description and V4L2 device support remain in the kernel patch series.

## RGB / OV02C10

The current working userspace stack includes automatic exposure, bounded temporal AWB, conservative first-frame gains, two-update fast AWB acquisition, persistent automatic AWB state across stream or resolution reconfiguration, manual colour controls, factory flat-field correction, and an optional local tone-mapping path that is disabled by default.

The optional tone-mapping implementation has an EGL accelerated path and a CPU quality fallback. Multi-exposure sensor HDR is not implemented because no trusted OV02C10 register sequence has been established.

## NIR / HM1092

HM1092 uses the real RAW10 mode and timing controls exposed by its V4L2 driver. Colour gains stay at unity for this monochrome/NIR sensor and no synthetic camera modes are added.

## Factory calibration

The OV02C10 module exposes an 8192-byte M24C64-family EEPROM through the kernel NVMEM interface. The calibration helper reads that provider and derives a neutral 17x13 flat-field map from the two redundant 1768-byte factory mesh records.

The exact channel order and the exact meaning of footer values have not been proven. The current decoder therefore combines the four channels into a neutral response map and does not apply unverified white-balance fields.

## Source transforms

`source-transforms/` preserves the staged source transformations used to reach the current working libcamera build. The stages cover AE, AWB/WDR, pipeline controls, local tone mapping, factory lens shading, stable AWB startup, optional EGL acceleration, default-off local tone mapping, fast AWB acquisition, and persistent AWB reconfigure state.

The current sensor tuning files are under `tuning/` and the per-unit calibration helpers are under `calibration/`.
