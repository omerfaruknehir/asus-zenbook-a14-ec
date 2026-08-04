# ASUS Zenbook A14 AOS kernel bring-up

The human-presence path is being implemented as normal Linux hardware support,
not as a userspace polling bridge.

Core design and acceptance criteria are documented in
[`docs/aos/ARCHITECTURE.md`](docs/aos/ARCHITECTURE.md).

## First Linux capture

From the repository root, run:

```bash
sudo ./scripts/a14-aos-kernel-probe.sh
```

The script creates a small `a14-aos-kernel-probe-*.tar.gz` archive in the
invoking user's `Downloads` directory. It is read-only: it does not reload
modules, restart ADSP, write camera registers, or install firmware.

The report is used to produce patches against both the running Ubuntu kernel
and current upstream for:

1. the existing OV02C10 V4L2 driver;
2. the A14 device tree and any required bindings;
3. Qualcomm QSH/QRTR/QMI lifecycle and firmware loading;
4. a standard IIO presence/distance interface.

Firmware provenance and known hashes are under `firmware/aos/`. Proprietary
firmware is not committed to the repository.

Optional GNOME/KDE helpers are confined to `desktop/` and are not part of the
sensor or firmware path.
