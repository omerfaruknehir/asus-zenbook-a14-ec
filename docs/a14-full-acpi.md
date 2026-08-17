# ASUS Zenbook A14 UX3407RA full-ACPI experiment

This branch tests **ACPI as the only platform firmware description**. The dedicated GRUB entry deliberately does not load a DTB. The normal DT kernel remains installed and is the rollback path.

## Firmware basis

The captured UX3407RA firmware has valid FADT/MADT/GTDT/IORT/MCFG/PPTT tables. The FADT is HW-reduced, advertises Low Power S0 Idle, and marks PSCI compliant. The DSDT exposes the Qualcomm/ASUS Windows-on-ARM device namespace, including `QCOM0C17` (PEP), `QCOM0C0D` (TLMM/GPIO), `QCOM0C10` (GENI I2C), `PNP0C14` WMI mappers, and the ASUS EC under `\_SB.I2C6`.

Linux v7.1.5 still lacks several bindings for those current-generation WoA ACPI IDs. `scripts/apply-a14-full-acpi.py` adds only the minimum Linux-side bindings needed for the first experiment; the firmware tables themselves are not modified.

## What v0 adds

- ACPI-WMI build support on ARM64.
- Architecture-neutral build of the existing `asus-wmi` and `asus-nb-wmi` sources.
- `QCOM0C10` matching and ACPI timing discovery for GENI I2C.
- `QCOM0C0D` matching for X1E80100 TLMM.
- A minimal `QCOM0C17` PEP dependency bridge so `_DEP` consumers can enumerate.
- TPM/CRB config for observation only. **TPM2 StartMethod 9 is not guessed or overridden.**

The PEP compatibility driver is deliberately not presented as a complete Windows PEP implementation. It only removes the enumeration deadlock. Runtime power policy will be added from evidence gathered by the ACPI-only boot.

## Build and install

```bash
git switch agent/a14-full-acpi
git pull --ff-only
bash scripts/a14-full-acpi-kernel.sh build
sudo bash scripts/a14-full-acpi-kernel.sh install
```

The installer creates an **additional** GRUB entry:

```text
ASUS Zenbook A14 — FULL ACPI experimental (7.1.5-a14-acpi-full0)
```

It does not replace `7.1.5-070105-generic`, does not overwrite its DTB, and does not set the experimental entry as default.

## First boot

Select the full-ACPI entry manually. Its GRUB stanza contains `acpi=force` and intentionally contains **no `devicetree` command**.

After boot:

```bash
bash scripts/a14-full-acpi-kernel.sh status | tee ~/Downloads/a14-full-acpi-status.txt
sudo journalctl -b -k > ~/Downloads/a14-full-acpi-kernel.log
```

A successful first stage does not require every peripheral to work. The first target is EFI framebuffer/console, CPU/PSCI, GIC/timers, initramfs, ACPI PCI root enumeration, NVMe root filesystem, and enough userspace to collect logs.

## Rollback

If the entry fails or hardware is unusable, reboot and select the normal DT kernel. Then optionally remove the experiment:

```bash
sudo bash scripts/a14-full-acpi-kernel.sh remove
```

Removal refuses to run while the experimental kernel is active.

## Known v0 gaps

- Qualcomm Windows PEP power policy is not yet implemented; the v0 bridge only satisfies `_DEP` ordering.
- WoA virtual GPIO/PDC number translation may still be required for some GPIO interrupts.
- CPU frequency may be absent because this DSDT does not expose a conventional `_CPC` path; the DT boot uses SCMI.
- GPU/display acceleration, camera, NPU, audio and some USB-C power policy may require additional ACPI HIDs or Linux driver adaptations.
- TPM2 uses firmware StartMethod 9; v0 deliberately leaves it untouched until its Qualcomm semantics are identified.

The ACPI-only entry remains a test entry until each subsystem is validated.