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
- Automatic/manual fan ownership
- Recovered native ASUS firmware thermal modes: Normal, Quiet, Turbo and Full Speed
- Five Linux-facing policies: **Quiet, Power Saver, Balanced, Performance, Full Speed**
- Per-cpufreq-policy QoS ceilings for heterogeneous Snapdragon X Elite clusters
- Quiet emergency cooling with hysteresis, observable sysfs state, kernel uevent,
  and desktop notification
- Transactional policy switching: firmware mode, fan ownership, CPU QoS and
  emergency state roll back together on failure
- Manual-mode safety monitor that restores EC automatic control at the configured
  trip point or after repeated temperature-read failures
- Suspend/resume restoration
- Reboot/shutdown quiesce path that restores automatic fan ownership, removes CPU
  caps, cancels safety work, and clears the compound-operation mailbox
- Delayed systemd loading with an explicit I²C-controller readiness check instead
  of fragile early `systemd-modules-load`
- Modern Linux `platform_profile` integration where supported; a driver-local
  profile interface always exists

### `hid_asus_ec`

- Keyboard backlight LED class with native 8-bit brightness (0–255)
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
2. installs DKMS/build requirements and exact running-kernel headers when needed;
3. builds `dist/asus-zenbook-a14-ec-dkms_<version>_all.deb`;
4. installs the EC and HID modules through DKMS;
5. enables the late-loading EC service and narrow A14 profile D-Bus service;
6. selects native `platform_profile` + distribution `power-profiles-daemon` when
   available, otherwise enables the packaged PPD-compatible fallback;
7. installs the GNOME **A14 Mode** Quick Settings extension and emergency
   notification integration.

You can also only build/install the package:

```bash
./scripts/build-deb.sh
sudo apt install ./dist/asus-zenbook-a14-ec-dkms_*_all.deb
```

A system-wide GNOME extension installed while a Wayland Shell session is already
running may require one logout/login before Shell discovers it. An XDG autostart
helper then enables it automatically.

## Power/profile model

The recovered firmware profile command is independent from the low-level fan
AUTO/MANUAL bit. Linux keeps those two controls separate.

| Linux policy | Firmware cooling policy | CPU policy | Fan ownership |
|---|---|---|---|
| `quiet` | Quiet `0x02` | strong per-cluster cap, default 45% of each policy maximum | firmware AUTO |
| `power-saver` | Normal `0x01` | moderate per-cluster cap, default 70% | firmware AUTO |
| `balanced` | Normal `0x01` | no artificial cap | firmware AUTO |
| `performance` | Turbo `0x04` | no artificial cap | firmware AUTO |
| `full-speed` | Full Speed `0x10` | no artificial cap | literal PWM 255 on both fans |
| `custom` | not a named policy | no artificial cap | direct hwmon manual PWM |

“Uncapped” means this driver adds no artificial CPU frequency ceiling. It does
**not** disable SoC, firmware, kernel, or hardware thermal protection.

### Quiet emergency cooling

Quiet is acoustic-first: it throttles CPU frequency aggressively and leaves the
fans on the recovered native Quiet curve. If the hottest monitored temperature
reaches `quiet_emergency_mc` (default **90 °C**) or temperature telemetry
repeatedly fails, the user-facing policy remains **Quiet** but the driver
requests the firmware Turbo cooling curve. The strong CPU cap stays in place.

After the system cools to `quiet_recover_mc` (default **75 °C**), the native
Quiet curve is restored. The transition exposes:

```text
/sys/devices/platform/asus_zenbook_a14_ec/quiet_emergency
```

and emits a `KOBJ_CHANGE` uevent. The packaged udev/userspace path shows a
critical persistent desktop notification when emergency cooling engages and a
replacement “cleared” notification after recovery.

## GNOME integration

GNOME's stock Power Mode UI has three standard modes. The driver maps them as:

| GNOME / power-profiles-daemon | Linux platform_profile | A14 policy |
|---|---|---|
| Power Saver | `low-power` | `power-saver` |
| Balanced | `balanced` | `balanced` |
| Performance | `performance` | `performance` |

Quiet is intentionally **not** an alias for Power Saver. Full Speed is also a
separate policy (`max-power` in the standard Linux class where available).

Because stock GNOME only renders its three standard profile names, the package
also installs an **A14 Mode** Quick Settings menu with all five choices:

```text
Quiet
Power Saver
Balanced
Performance
Full Speed
```

The Quick Settings extension talks to the root-owned
`io.github.omerfaruknehir.AsusA14` system D-Bus service. That service exposes
only named profile get/set operations and emergency state; it does **not** expose
raw EC registers, manual PWM, firmware mailbox access, or MMIO to the desktop.

The A14 Quick Settings indicator normally adds no extra top-bar icon. A warning
indicator appears while Quiet emergency cooling is active.

## Profile backends and services

The package includes:

- `asus-zenbook-a14-ec.service` — loads/unloads the EC module safely.
- `asus-zenbook-a14-profile.service` — narrow root-owned system D-Bus API for
  the five A14 modes, used by the GNOME extension.
- `asus-zenbook-a14-ppd-bridge.service` — PPD-compatible fallback only for
  kernels where the A14 standard `platform_profile` handler cannot register.

Backend selection is automatic. To re-evaluate it manually:

```bash
sudo asus-a14-control profile-backend refresh
```

The fallback bridge maps only GNOME's standard three names:

| Desktop profile | Driver profile |
|---|---|
| `power-saver` | `power-saver` |
| `balanced` | `balanced` |
| `performance` | `performance` |

When native `platform_profile` is available, the fallback bridge is disabled and
the distribution `power-profiles-daemon` is restored.

## Control utility

```bash
asus-a14-control status
sudo asus-a14-control profile quiet
sudo asus-a14-control profile power-saver
sudo asus-a14-control profile balanced
sudo asus-a14-control profile performance
sudo asus-a14-control profile full-speed
sudo asus-a14-control auto
sudo asus-a14-control manual 180
sudo asus-a14-control fan left 160
sudo asus-a14-control backlight 170
```

Direct manual PWM accepts `75–255`; fan-off manual values are rejected. Direct
hwmon manual control is represented as `custom`. The manual safety monitor falls
back to firmware automatic control if temperature reaches the configured trip
point or temperature reads repeatedly fail.

## Driver-local and standard interfaces

The driver-local interface is always available at:

```text
/sys/devices/platform/asus_zenbook_a14_ec/profile
/sys/devices/platform/asus_zenbook_a14_ec/profile_choices
/sys/devices/platform/asus_zenbook_a14_ec/quiet_emergency
```

The standard Linux profile class, when available, exposes the A14 mapping through
`/sys/class/platform-profile/`. The expected standard choices are:

```text
low-power quiet balanced performance max-power
```

Older/unpatched kernels continue to work through the local sysfs interface,
`asus-a14-control`, and the packaged PPD-compatible fallback.

## Policy parameters

Safe defaults are installed in `/etc/modprobe.d/asus-zenbook-a14-ec.conf`:

```text
quiet_max_percent=45
power_saver_max_percent=70
quiet_emergency_mc=90000
quiet_recover_mc=75000
manual_trip_mc=85000
```

`performance_pwm` remains only the default used when direct hwmon manual mode is
entered; the named Performance policy uses the recovered firmware Turbo mode.

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

- `.shutdown()` and `.remove()` quiesce the EC;
- the package loads the EC late through systemd;
- systemd unloads it during orderly reboot/shutdown;
- probe validates initial EC transactions and aborts cleanly on errors;
- profile transitions restore the previous coherent policy on partial failure.

An I²C controller or firmware that hard-hangs inside `i2c_transfer()` cannot be
made interruptible by an out-of-tree client driver. Test the first warm reboot in
a controlled setting. A cold power cycle remains the recovery path for a
firmware-level bus wedge.

## Validation

After installing the current package, the main hardware checks are:

```bash
sudo sh ./scripts/a14-ec-profile-load-validation.sh
sudo sh ./scripts/a14-quiet-emergency-validation.sh
sudo sh ./scripts/a14-platform-profile-dt-validation.sh
sh ./scripts/a14-gnome-profile-validation.sh
```

The Quiet emergency validator safely lowers the temporary test threshold rather
than deliberately heating the laptop to the real 90 °C emergency point, then
restores the original thresholds/profile.

The standard profile validator detects the known ARM64 header-package case where
`gendwarfksyms` is accidentally an x86-64 host binary; it builds a native host
tool from the same kernel source rather than changing the running kernel's symbol
versioning scheme.

## Uninstall

```bash
sudo apt remove asus-zenbook-a14-ec-dkms
```

Package removal disables the A14 services and restores the distribution
`power-profiles-daemon` when the fallback bridge had been active.

## Development/debugging

Raw HID commands are disabled by default. Enable them only temporarily:

```bash
sudo modprobe -r hid_asus_ec
sudo modprobe hid_asus_ec enable_debug_commands=1
```

The resulting `hid_cmd` sysfs attribute is mode `0600`.

## Credits

- Sombre-Osmoze — EC reverse engineering, initial hwmon/profile driver,
  tachometer calibration, and original PPD bridge
- Alexandru Marc Serdeliuc — original HID keyboard-backlight driver and protocol
- icecream95 — early EC protocol documentation
- Ömer Faruk Nehir — safety hardening, compatibility, DKMS/DEB packaging,
  systemd/GNOME integration, and maintenance of this fork

## License

- `asus_zenbook_a14_ec.c`: GPL-2.0-only
- `hid_asus_ec.c`: GPL-2.0-or-later
- packaged Python/GNOME integration: GPL-2.0-or-later
