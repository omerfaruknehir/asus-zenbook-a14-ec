# Resources CPU information correction

This directory contains source-level corrections for the GNOME **Resources**
application on the ASUS Zenbook A14 / Snapdragon X platform.

They are desktop application patches, not hardware bridges:

- no service or daemon is installed;
- no kernel interface is emulated;
- no privileged runtime helper is used;
- no firmware, device-tree, CPU, or GPU limits are changed.

## Problem

Resources primarily derives topology and maximum frequency from `lscpu`, and
its live-frequency reader assumes per-CPU CPUFreq links/attributes are always
present. On the A14 this can produce incorrect topology, `Max: N/A`, or missing
live core frequency even though qcom-cpufreq-hw is exposing the data through
standard CPUFreq policy directories.

## Correct data sources

The A14 CPU patch keeps `lscpu` for its useful model string but gives standard
Linux interfaces precedence:

- `/sys/devices/system/cpu/online` for online CPU IDs;
- `cpu*/topology/{physical_package_id,core_id}` for core/socket topology;
- `cpu*/cpufreq` when the normal per-CPU CPUFreq symlink exists;
- `/sys/devices/system/cpu/cpufreq/policy*` as the canonical fallback;
- `cpuinfo_avg_freq`, `cpuinfo_cur_freq`, then `scaling_cur_freq` for live
  frequency;
- `cpuinfo_max_freq`, then `scaling_available_frequencies`, then
  `stats/time_in_state`, with `scaling_max_freq` only as a last resort for
  maximum frequency;
- `/proc/device-tree/compatible` for the generic `qcom,x1e80100` platform ID.

The maximum-frequency order matters because A14 **Whisper** may intentionally
lower the runtime `scaling_max_freq`; Resources should still display the
hardware/OPP maximum when the kernel exposes one.

On X1E80100 the broader patch labels the microarchitecture as
`Qualcomm Oryon (ARMv8.7-A)`, keeps the exact model reported by `lscpu`, and
uses online topology rather than the possible CPU count.

## Existing custom A14 Resources checkout

If `~/Projects/resources-a14` already contains the previous A14/Qualcomm GPU,
temperature, topology and UI work, **do not reapply the whole patch stack just
to fix frequency reporting**. Use the surgical repair:

```bash
python3 desktop/resources/repair-a14-cpu-frequency.py \
  ~/Projects/resources-a14
```

It requires the existing `A14_RESOURCES_CPU_INFO_V1` marker and modifies only
`src/utils/cpu.rs` frequency helpers/readers. Existing Qualcomm/Adreno code is
left in place. The script creates a timestamped backup and unified diff and is
idempotent.

Then rebuild the same custom checkout:

```bash
cd ~/Projects/resources-a14
rm -rf build-release
meson setup build-release --prefix=/usr --buildtype=release -Dprofile=default
ninja -C build-release
sudo meson install -C build-release --no-rebuild
killall resources 2>/dev/null || true
/usr/bin/resources
```

## Fresh Resources checkout

For a fresh/unpatched Resources checkout, use the full safe wrapper:

```bash
sh desktop/resources/apply-a14-cpu-info-safe.sh ~/Projects/resources-a14
```

The wrapper applies the source patch and then validates/repairs GTK
`CompositeTemplate` metadata. It is safe to run again on an already-patched
checkout.

For a checkout that was patched before the template fix and currently fails
with `possibly missing #[template_child] attribute`, run only:

```bash
python3 desktop/resources/repair-a14-cpu-info.py ~/Projects/resources-a14
```

Do not run `meson install` after a failed `ninja` build; doing so may install
data files while leaving the previous executable in place.

## Expected result

The CPU page should show:

- the existing A14/Oryon model and topology information from the custom build;
- live core frequencies sourced from the CPUFreq policy for each CPU;
- a non-`N/A` maximum frequency whenever the kernel exposes a hardware maximum,
  OPP frequency list, CPUFreq stats table, or at minimum a scaling maximum.

## Compatibility

The full structural patcher supports the Resources 1.8-era layout and current
upstream layout. The frequency-only repair deliberately requires an existing
A14 CPU-patched tree and fails rather than making a speculative edit to an
unrelated Resources checkout.
