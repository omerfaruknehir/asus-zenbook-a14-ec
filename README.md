# ASUS Zenbook A14 EC drivers

Out-of-tree Linux kernel drivers and a DKMS Debian package for the Snapdragon
ASUS Zenbook A14 family:

- **UX3407RA** — Qualcomm X1E80100
- **UX3407QA** — Qualcomm X1P42100

The direct EC driver is model-gated and refuses to load elsewhere unless the
explicit development-only `force=1` module option is used.

## Features

### `asus_zenbook_a14_ec`

- Two independently readable and writable fans through standard `hwmon`
- EC temperature monitoring
- Automatic/manual fan modes
- Safe quiet, balanced, and performance profiles
- CPU frequency QoS cap in quiet mode
- Manual-mode safety monitor that restores EC automatic control at 85 °C or
  after repeated temperature-read failures
- Suspend/resume restoration
- Reboot/shutdown quiesce path that restores automatic fan control, removes CPU
  caps, cancels safety work, and clears the compound-operation mailbox
- Delayed systemd loading with an explicit I²C-controller readiness check instead of fragile early `systemd-modules-load`
- Optional modern `platform_profile` registration when the running kernel
  exposes it on DT-only systems; a driver-local profile interface always exists

### `hid_asus_ec`

- Keyboard backlight LED class with levels 0–3
- Fn hotkeys for screen brightness, microphone, camera, touchpad, emoji picker,
  programmable key, and performance key
- Non-blocking Fn+F4 handling
- Correct keyboard-backlight save/restore across suspend
- Root-only raw HID debug interface, disabled by default

## Recommended installation: DEB + DKMS

```bash
git clone https://github.com/omerfaruknehir/asus-zenbook-a14-ec.git
cd asus-zenbook-a14-ec
./install.sh
```

The installer:

1. verifies the device-tree model;
2. installs DKMS, build tools, and the exact running-kernel headers when needed;
3. builds `dist/asus-zenbook-a14-ec-dkms_<version>_all.deb`;
4. installs both modules through DKMS;
5. enables the late-loading EC systemd service.

You can also only build the package:

```bash
./scripts/build-deb.sh
sudo apt install ./dist/asus-zenbook-a14-ec-dkms_*_all.deb
```

## Systemd services

The package includes two separate units:

- `asus-zenbook-a14-ec.service` — enabled by default; waits for the Qualcomm I²C
  controller, loads the direct EC module late, and unloads it during orderly
  shutdown/reboot so the driver quiesce path runs.
- `asus-zenbook-a14-ppd-bridge.service` — disabled by default; an optional
  D-Bus fallback for kernels where the standard `platform_profile` class cannot
  register on a DT-only system.

The fallback bridge maps desktop profiles to the driver-local interface:

| Desktop profile | Driver profile |
|---|---|
| `power-saver` | `quiet` |
| `balanced` | `balanced` |
| `performance` | `performance` |

Check whether the fallback is needed:

```bash
asus-a14-control ppd-bridge status
```

Enable it only when GNOME/KDE does not expose the A14 profiles:

```bash
sudo asus-a14-control ppd-bridge enable
```

The bridge conflicts with `power-profiles-daemon`, so enabling it temporarily
masks the normal daemon. Disabling the bridge restores the distribution daemon:

```bash
sudo asus-a14-control ppd-bridge disable
```

## Control utility

```bash
asus-a14-control status
sudo asus-a14-control profile quiet
sudo asus-a14-control profile balanced
sudo asus-a14-control profile performance
sudo asus-a14-control auto
sudo asus-a14-control manual 180
sudo asus-a14-control fan left 160
sudo asus-a14-control backlight 2
```

Manual PWM accepts `75–255`; fan-off manual values are rejected. The safety monitor remains active in manual
mode and falls back to automatic fan control if temperature reaches the
configured trip point.

## Profile behaviour

| Profile | Fan control | CPU frequency |
|---|---|---|
| `quiet` | EC automatic curve | capped to 1.44 GHz by default |
| `balanced` | EC automatic curve | uncapped |
| `performance` | both fans at PWM 220 by default | uncapped |

Defaults can be changed in `/etc/modprobe.d/asus-zenbook-a14-ec.conf`.

The driver-local interface is always available at:

```text
/sys/devices/platform/asus_zenbook_a14_ec/profile
/sys/devices/platform/asus_zenbook_a14_ec/profile_choices
```

On kernels where `platform_profile` supports DT-only machines, the standard
class interface is registered as well. Older or unpatched kernels continue to
work through the driver-local interface, `asus-a14-control`, or the optional
PPD bridge.

## Direct module build

```bash
make
sudo insmod ./hid_asus_ec.ko
sudo insmod ./asus_zenbook_a14_ec.ko
```

For a different kernel tree:

```bash
make KDIR=/path/to/kernel/build
```

## Exposed hwmon interfaces

| Interface | Meaning |
|---|---|
| `fan1_input`, `fan2_input` | left/right fan RPM |
| `pwm1`, `pwm2` | left/right fan PWM, 0–255 |
| `pwm1_enable` | `1` manual, `2` automatic |
| `temp1_input` | EC temperature in millidegrees Celsius |

The tachometer conversion is based on the original hardware calibration:
`RPM ≈ raw tach × 88`.

## Warm reboot safety

The original PoC could leave the EC in a state where the next warm boot hung on
the first I²C transfer. This fork addresses the parts under driver control:

- `.shutdown()` and `.remove()` both quiesce the EC;
- the package loads the direct EC module late through a systemd service;
- systemd unloads it during an orderly reboot/shutdown;
- probe validates the first EC transactions and aborts cleanly on errors;
- ignored/uninitialised probe reads were removed.

An I²C controller or firmware that hard-hangs inside `i2c_transfer()` cannot be
made interruptible by an out-of-tree client driver. Test the first warm reboot
in a controlled setting. A cold power cycle remains the recovery path for a
firmware-level bus wedge.

## Uninstall

```bash
sudo apt remove asus-zenbook-a14-ec-dkms
```

If the optional bridge was enabled, package removal disables it and restores
`power-profiles-daemon`.

## Development/debugging

Raw HID commands are disabled by default. Enable them only temporarily:

```bash
sudo modprobe -r hid_asus_ec
sudo modprobe hid_asus_ec enable_debug_commands=1
```

The resulting `hid_cmd` sysfs attribute is mode `0600`.

## Validation

The modules are compile-tested against Linux 6.12 headers. The modern
`platform_profile` path is conditionally enabled on Linux 6.14 and newer, while
older kernels retain the local profile interface.

The package validation also checks shell syntax, Python bridge syntax, DEB
metadata, both systemd units, and packaged file paths.

Hardware tests still required after installation:

- both fan tachometers and PWM channels;
- quiet/balanced/performance switching;
- suspend/resume;
- keyboard backlight restore;
- normal `power-profiles-daemon` integration or the optional bridge;
- one shutdown, one warm reboot, and one cold boot.

## Credits

- Sombre-Osmoze — EC reverse engineering, initial hwmon/profile driver,
  tachometer calibration, and original PPD bridge
- Alexandru Marc Serdeliuc — Original HID keyboard-backlight driver and protocol
- icecream95 — Early EC protocol documentation
- Ömer Faruk Nehir — safety hardening, compatibility, DKMS/DEB packaging,
  systemd integration, and maintenance of this fork

## License

- `asus_zenbook_a14_ec.c`: GPL-2.0-only
- `hid_asus_ec.c`: GPL-2.0-or-later
- `scripts/asus-zenbook-a14-ppd-bridge.py`: GPL-2.0-or-later
