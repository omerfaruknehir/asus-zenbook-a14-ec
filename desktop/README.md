# Optional desktop integrations

Desktop integrations are explicitly separate from kernel hardware support.
Nothing in this directory may be required for fan control, camera operation,
human-presence sensing, suspend/resume, or firmware loading.

Acceptable helpers include:

- a fan/profile status icon reading standard `hwmon`/`platform_profile` state;
- a camera block/privacy indicator reading a standard LED trigger, privacy
  switch, V4L2 control, or PipeWire camera state;
- settings panels that configure an already-working standard kernel interface.

Helpers must not access camera I²C registers, open QRTR/QMI services directly,
replay firmware messages, or impersonate an IIO/HID sensor.
