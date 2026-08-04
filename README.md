# ASUS Zenbook A14 EC drivers

Out-of-tree Linux drivers for ASUS Zenbook A14 Snapdragon systems, originally
reverse-engineered for the **UX3407RA / X1E80100**. The repository provides:

- dual-fan RPM, PWM and EC-temperature reporting through `hwmon`;
- automatic/manual fan control;
- `quiet`, `balanced` and `performance` platform profiles;
- keyboard-backlight control and ASUS Fn hotkeys through HID;
- DKMS installation and an easy Debian/Ubuntu `.deb` package;
- `a14-ecctl`, a small status and control utility.

## Install on Debian or Ubuntu

```bash
sudo apt install build-essential dkms linux-headers-$(uname -r) python3
bash scripts/install.sh
sudo a14-ecctl status
```

Or build without installing:

```bash
make
make deb
```

The finished package is written to `dist/`.

## Why the build uses `build-src/`

The original reverse-engineering baseline is preserved. `make` runs
`scripts/prepare-source.py`, which creates a hardened build copy and refuses to
continue if the expected baseline no longer matches. DKMS uses the same path,
so manual and packaged builds are identical.

## Controls

```bash
a14-ecctl status
a14-ecctl profile quiet
a14-ecctl profile balanced
a14-ecctl profile performance
a14-ecctl fan auto
a14-ecctl fan manual both 120
a14-ecctl backlight 2
```

Manual PWM accepts `0` or `75-255`; unstable values below the measured spin
floor are rejected.

## Safety changes in this fork

- restores automatic fan mode through a platform shutdown callback;
- loads the direct EC module late through systemd instead of early boot;
- delays the first direct EC transaction by 1.5 seconds;
- uses a stable near-silent fan floor in quiet mode instead of forcing both fans
  off;
- removes the hard-coded 3.4176 GHz “uncapped” limit;
- initializes probe telemetry instead of logging uninitialized values;
- preserves keyboard-backlight brightness across suspend/resume;
- makes the HID debug response and lock per device.

Read [`docs/SAFETY.md`](docs/SAFETY.md) before enabling manual fan control.

## Build against another kernel tree

```bash
make KDIR=/path/to/linux
```

The target kernel must provide the modern multi-handler `platform_profile` API.
Device-tree-only kernels may still need
`patches/0001-platform_profile-allow-non-ACPI-systems.patch` applied to the
kernel itself.

## License

- EC driver and kernel patch: GPL-2.0-only
- HID driver: GPL-2.0-or-later
