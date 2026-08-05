# Optional desktop integrations

Desktop integrations are explicitly separate from kernel hardware support.
Nothing in this directory may be required for fan control, camera operation,
human-presence sensing, suspend/resume, or firmware loading.

Acceptable helpers include:

- a fan/profile status icon reading standard `hwmon`/`platform_profile` state;
- a camera block/privacy indicator reading a standard LED trigger, privacy
  switch, V4L2 control, or PipeWire camera state;
- settings panels that configure an already-working standard kernel interface;
- source-level fixes for desktop applications that misinterpret standard Linux
  interfaces, such as the Resources Snapdragon CPU-information correction.

Helpers must not access camera I²C registers, open QRTR/QMI services directly,
replay firmware messages, or impersonate an IIO/HID sensor.

## Resources

`resources/` contains a source patcher for the GNOME Resources application. It
uses device tree, CPU topology and cpufreq sysfs data already supplied by the
kernel. It installs no service and does not participate in hardware support.
