# Resources CPU information correction

This directory contains a source-level correction for the GNOME **Resources**
application on the ASUS Zenbook A14 / Snapdragon X platform.

It is a desktop application patch, not a hardware bridge:

- no service or daemon is installed;
- no kernel interface is emulated;
- no privileged runtime helper is used;
- no firmware, device-tree, or CPU settings are changed.

## Problem

Resources primarily derives topology from aggregate `lscpu` fields. On the A14
this can report the possible CPU set instead of the online set, producing 16
logical/physical cores, and it does not identify the Qualcomm Oryon
microarchitecture. The model may therefore be shown below an `Unknown CPU`
title even when `lscpu` knows the X1E part number.

## Correct data sources

The patch keeps `lscpu` for its useful model string but gives standard Linux
interfaces precedence for topology and frequency:

- `/sys/devices/system/cpu/online` for online CPU IDs;
- `cpu*/topology/{physical_package_id,core_id}` for core/socket topology;
- `cpu*/cpufreq/{cpuinfo_max_freq,scaling_max_freq}` and policy fallback for
  maximum frequency;
- `/proc/device-tree/compatible` for the generic `qcom,x1e80100` platform ID.

On X1E80100 it labels the microarchitecture as
`Qualcomm Oryon (ARMv8.7-A)`, keeps the exact model reported by `lscpu` such as
`Snapdragon X1E-80-100`, and uses the online topology rather than the possible
CPU count.

## Apply safely

Use the safe wrapper rather than invoking the legacy patcher directly:

```bash
sh desktop/resources/apply-a14-cpu-info-safe.sh ~/Projects/resources-a14
```

The wrapper applies the source patch and then validates/repairs GTK
`CompositeTemplate` metadata. It is safe to run again on an already-patched
checkout.

For a checkout that was patched before the template fix and currently fails
with `possibly missing #[template_child] attribute`, run only the repair pass:

```bash
python3 desktop/resources/repair-a14-cpu-info.py ~/Projects/resources-a14
```

The scripts:

1. verify that the target has the expected Resources source files;
2. create timestamped source backups;
3. write timestamped unified patches for review;
4. modify only CPU information and UI metadata;
5. exit cleanly without duplicating changes when run again.

Build Resources using that checkout's normal Meson workflow after the source
change. Do not run `meson install` after a failed `ninja` build; doing so may
install data files while leaving the previous executable in place.

## Expected result

The CPU page should show:

- `Qualcomm Oryon (ARMv8.7-A)` instead of `Unknown CPU`;
- the exact Snapdragon X1E model string as the subtitle;
- the online logical-core count;
- physical cores and socket count from kernel topology, with an ARM one-thread-
  per-core fallback;
- maximum frequency from cpufreq sysfs.

## Compatibility

The structural patcher supports the Resources 1.8-era layout and current
upstream layout. It fails rather than making a speculative edit when the source
has diverged around a required marker.
