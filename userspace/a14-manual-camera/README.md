# A14 Manual Camera

A GTK4/libcamera diagnostic application used while bringing up the ASUS Zenbook A14 RGB and NIR devices.

The application discovers cameras, roles, formats, sizes and controls at runtime instead of hard-coding sensor capabilities. It supports processed and raw capture, live preview, request metadata, safe stream restart when configuration changes, image-pipeline controls exposed by the A14 SoftISP build, and the standard V4L2 flash interface associated with the NIR device.

It intentionally does not add virtual camera devices or fake sensor modes. When the kernel exposes another real mode or control it becomes visible through normal libcamera enumeration.

The current validated application lineage is 0.7.x. Source import is tracked separately from the kernel patch series because this program is a userspace diagnostic tool, not a kernel driver.
