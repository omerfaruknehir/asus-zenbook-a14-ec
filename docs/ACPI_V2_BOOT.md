# ASUS Zenbook A14 UX3407RA — factory ACPI boot v2

This is the clean restart of the full-ACPI experiment.

## Milestone v2.0

The first milestone is deliberately narrow:

- boot from factory UEFI ACPI tables;
- **do not load a DTB**;
- enumerate PCIe/NVMe;
- find and mount the existing Linux root filesystem;
- switch root;
- reach `multi-user.target` with a usable console;
- collect a complete boot report;
- leave the normal DT kernels and DTBs untouched as rescue boots.

GPU acceleration, camera, audio, SSC, NPU, suspend, Type-C and desktop graphics are **not** v2.0 pass criteria.

## Why the first v2 checkpoint stays on 7.1.5

The historical `7.1.5-a14-acpi-full0` checkpoint at repository commit
`74c9bd5ebc77e2563b8be50d8cb4af67202c71fe` has already booted the factory
ACPI namespace without a hardware DTB, enumerated the Qualcomm PCIe host,
found the NVMe device and root UUID, mounted the real root filesystem and
switched into the installed userspace.

Changing both the firmware-description architecture and kernel baseline in one
experiment makes regressions ambiguous. Therefore v2.0 first reproduces only
the proven minimal ACPI infrastructure. Linux 7.2 remains the DT rescue/current
baseline. Once this clean checkpoint is captured, the minimal ACPI changes will
be forward-ported to 7.2 as a separate milestone.

## Known current defects

These are expected and are not reasons to call v2.0 a failed boot:

1. `x1e80100-tlmm QCOM0C0D:00` currently fails probe with `-22`.
2. ACPI methods using `ROP1` can fail because Linux has no GenericSerialBus
   operation-region handler attached for that path; `PRTC._GRT` is one observed
   victim.
3. DRM/MSM GPU acceleration is not part of the clean baseline.
4. DT-only/custom services may deliberately not start because
   `/proc/device-tree/model` is absent.
5. Multimedia/peripheral functionality is intentionally postponed until the
   common ACPI infrastructure is correct.

Do not add synthetic GPU children, fixed-rate GPU clock proxies or broad
machine-specific fake-DT infrastructure to make this milestone look more
functional. Those experiments remain useful evidence, but are not the v2 base.

## Safety model

`a14-acpi-v2.sh` creates two dedicated entries:

- **safe console** — retains `clk_ignore_unused pd_ignore_unused` while we map
  firmware ownership; use this first;
- **strict console** — removes those two hold-open arguments; do not use until a
  complete safe-boot report exists.

Both entries:

- use `acpi=force`;
- contain no GRUB `devicetree` command;
- boot `systemd.unit=multi-user.target`;
- keep verbose EFI-framebuffer logging;
- leave ordinary Ubuntu/7.2 DT entries unchanged.

The script uses `grub-reboot`, so the ACPI selection is a **one-shot next boot**.
It never reboots the machine automatically.

## Build and install

From the known-good DT boot:

```bash
cd ~/Downloads/asus-zenbook-a14-ec
git fetch origin
git switch agent/a14-acpi-v2
git pull --ff-only origin agent/a14-acpi-v2

bash scripts/a14-acpi-v2.sh preflight
bash scripts/a14-acpi-v2.sh build
sudo bash scripts/a14-acpi-v2.sh install
sudo bash scripts/a14-acpi-v2.sh arm-next
```

Inspect the `arm-next` output. Only when ready:

```bash
sudo reboot
```

Do **not** suspend the machine during the first ACPI v2 boot.

## After a successful ACPI boot

Log in on the local console and run:

```bash
cd ~/Downloads/asus-zenbook-a14-ec
sudo bash scripts/a14-acpi-v2.sh status
sudo bash scripts/a14-acpi-v2.sh collect
```

The collector writes a timestamped report under `~/Downloads/` and is read-only.
It records:

- whether ACPI tables are present;
- whether a live DT is absent;
- ACPI table hashes;
- root/NVMe state;
- PCI enumeration;
- ACPI and platform-device binding;
- IOMMU groups;
- framebuffer/DRM state;
- CPU/power state;
- systemd state;
- targeted ACPI/TLMM/GenericSerialBus errors;
- full current-boot kernel log.

The final result section should contain:

```text
acpi_tables_present=1
device_tree_absent=1
root_mounted=1
root_on_nvme=1
multi_user_active=1
milestone_acpi_userspace=PASS
```

`known_tlmm_error_seen=1` and/or `known_rop1_error_seen=1` are currently expected.

## Recovery

Because the experiment is one-shot, a normal subsequent boot should return to
your default DT entry automatically.

If the screen remains unusable or the machine wedges:

1. power it off;
2. boot again and choose the normal Linux 7.2 DT entry in GRUB if necessary;
3. from the DT boot, clear any pending one-shot selection:

```bash
sudo bash scripts/a14-acpi-v2.sh unarm
```

Nothing in this workflow deletes `/boot/dtb-*`, edits the normal distro DTB
post-install hook, or replaces the normal default kernel.

## Next milestones

After v2.0 produces a clean report:

### v2.1 — TLMM/GPIO

Make the real `QCOM0C0D` TLMM device bind from ACPI using firmware resources and
normal Linux GPIO/pinctrl abstractions. No fabricated OF node.

### v2.2 — GenericSerialBus operation regions

Provide the required controller/handler relationship so firmware AML using
`ROP1` works, including the observed `PRTC._GRT` path.

### v2.3 — remove hold-open power arguments

Boot the strict entry without `clk_ignore_unused` and `pd_ignore_unused`, fix the
actual clock/power ownership gaps exposed by that transition.

### v2.4 — forward-port minimal ACPI base to Linux 7.2

Only the proven infrastructure changes move forward. Historical debug
checkpoints and synthetic GPU experiments do not.

### v2.5+ — GPU, remoteproc, audio, camera, SSC, HTP

Bring each subsystem up through native ACPI/fwnode support on top of the stable
common infrastructure.
