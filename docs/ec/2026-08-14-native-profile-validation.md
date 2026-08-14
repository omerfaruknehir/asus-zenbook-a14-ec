# A14 native EC/profile validation — 2026-08-14

Permanent hardware-validation record for the ASUS Zenbook A14 UX3407RA.

## Runtime transport/manual-PWM validation

Using `scripts/a14-ec-runtime-validation.sh` on Linux `7.1.5-070105-generic`:

- local `asus_zenbook_a14_ec.ko` inserted successfully;
- private profile node exposed `quiet balanced performance full-speed`;
- all four recovered native profile commands returned success and read back the requested state;
- manual PWM round-trip succeeded;
- returning manual mode to firmware AUTO succeeded;
- final profile was restored to balanced;
- validator result: `A14_EC_RUNTIME_VALIDATION=PASS` (transport/manual-control semantics).

Representative manual-PWM result:

```text
MANUAL_PWM_160
profile=custom
fan1_rpm=7309
fan2_rpm=2376
ec_temp_mc=43000
pwm1=160
pwm2=160
pwm1_enable=1
```

After returning to AUTO:

```text
profile=balanced
fan1_rpm=5297
fan2_rpm=1496
pwm1=85
pwm2=82
pwm1_enable=2
```

This validates the low-level fan ownership/PWM path independently of the native firmware thermal profiles.

## First native-profile load capture

A 12-thread CPU load reached the 85 C system-temperature safety cutoff while testing `quiet`, so the first capture stopped before `performance` and `full-speed`.

Balanced rose from approximately 70.6 C / 4418 RPM / PWM 86 to 79.1 C / 5170 RPM / PWM 116. Quiet then remained around 4.1–4.4k RPM and PWM ~79–86 even as the hottest system sensor climbed to 85.1 C. This was the first strong evidence that quiet is behaviorally distinct from balanced.

## Complete fresh-load four-mode capture

The revised validator used six CPU load threads, an 82 C cutoff, and a fresh/cool start for every requested profile. All four recovered firmware modes completed without reaching the cutoff:

```text
profiles_attempted=4 thermal_cutoff_profiles=0
A14_EC_PROFILE_LOAD_CAPTURE=COMPLETE
```

### Balanced / native Normal (0x01)

```text
61.0 C: fan1=3956 rpm fan2=1320 rpm pwm1=86  pwm2=77
62.2 C: fan1=4382 rpm fan2=1320 rpm pwm1=84  pwm2=81
64.2 C: fan1=4338 rpm fan2=1408 rpm pwm1=82  pwm2=82
65.0 C: fan1=4617 rpm fan2=1584 rpm pwm1=94  pwm2=94
```

### Quiet / native Quiet (0x02)

```text
65.4 C: fan1=4000 rpm fan2=1232 rpm pwm1=82 pwm2=77
66.6 C: fan1=4138 rpm fan2=1320 rpm pwm1=84 pwm2=81
67.4 C: fan1=4347 rpm fan2=1408 rpm pwm1=85 pwm2=81
68.2 C: fan1=4373 rpm fan2=1408 rpm pwm1=83 pwm2=79
```

Quiet holds a lower fan/PWM response than balanced at similar or higher temperatures. This is consistent with the recovered Windows/DSDT design: the quiet firmware mode prioritizes acoustics and host thermal throttling before fan response.

### Performance / native Turbo (0x04)

```text
71.9 C: fan1=5431 rpm fan2=2200 rpm pwm1=123 pwm2=151
71.5 C: fan1=6398 rpm fan2=2288 rpm pwm1=148 pwm2=154
71.9 C: fan1=6759 rpm fan2=2288 rpm pwm1=155 pwm2=152
72.3 C: fan1=6867 rpm fan2=2200 rpm pwm1=159 pwm2=150
```

### Full-speed / native Full Speed (0x10)

```text
71.8 C: fan1=7092 rpm fan2=2288 rpm pwm1=161 pwm2=153
71.8 C: fan1=6978 rpm fan2=2288 rpm pwm1=159 pwm2=151
72.7 C: fan1=7927 rpm fan2=2640 rpm pwm1=219 pwm2=211
72.2 C: fan1=8837 rpm fan2=2992 rpm pwm1=244 pwm2=236
```

The hardware ordering is therefore clearly established:

```text
quiet < balanced << performance < full-speed
```

Full-speed is a genuine separate firmware mode, not an alias for performance. The native full-speed curve approached but did not reach PWM 255 in this short capture; if the Linux policy promises literal maximum fan, it should layer manual PWM 255 on top of the recovered full-speed firmware thermal mode while retaining hardware thermal protection.

## Desired Linux policy semantics after validation

The firmware modes and desktop power modes should not be conflated. The intended Linux-facing policy is:

- `quiet`: acoustic-first. Use native Quiet plus a strong CPU-frequency QoS cap. Keep fans minimal; if temperature becomes genuinely dangerous despite throttling, temporarily request a more aggressive firmware cooling curve while retaining the CPU cap.
- `power-saver` / standard `low-power`: ordinary battery-saving behavior. Use the native Normal curve plus a moderate CPU-frequency QoS cap.
- `balanced`: native Normal with no artificial CPU cap.
- `performance`: native Turbo with no artificial CPU cap.
- `full-speed` / standard `max-power`: native Full Speed plus literal maximum fan where requested, with no artificial CPU cap. Hardware/thermal safety throttling must never be disabled.
- `custom`: direct hwmon manual PWM only.

## CPU-frequency control evidence

Earlier A14 captures show working per-CPU cpufreq telemetry such as `/sys/devices/system/cpu/cpuN/cpufreq/cpuinfo_avg_freq`, including values from roughly 0.8 GHz to 3.4 GHz depending on core/load. Therefore Linux `freq_qos` is the appropriate kernel mechanism for the Quiet and Power Saver caps. The first load validator looked only for `policy*/scaling_cur_freq`, so its `cpu_freq_* = unavailable` output did not prove cpufreq was absent.

## Standard Linux platform_profile validation

The DT `platform_profile` source transform applies cleanly, but the temporary out-of-tree framework-module build is currently blocked by an Ubuntu/mainline header-package host-tool mismatch:

```text
CONFIG_ACPI_PLATFORM_PROFILE=m
CONFIG_GENDWARFKSYMS=y
.../scripts/gendwarfksyms/gendwarfksyms: ELF 64-bit x86-64
... Exec format error
```

A later fallback also found that the packaged headers do not contain an executable `scripts/genksyms/genksyms`. This is a host-tool packaging/architecture problem, not an EC source-code compile error. The correct validation fix is to build the native ARM64 host `gendwarfksyms` from the same Linux 7.1.5 source rather than changing the kernel's module-versioning algorithm.

## Status after the complete capture

- EC byte transport: **validated**
- firmware AUTO ownership: **validated**
- manual PWM: **validated**
- balanced native mode: **validated under load**
- quiet native mode: **validated under load**
- performance native mode: **validated under load**
- full-speed native mode: **validated under load**
- ordering `quiet < balanced << performance < full-speed`: **validated**
- Quiet vs Power Saver OS policy separation: **to implement**
- literal PWM-255 Full Speed policy: **to implement/validate**
- standard Linux `platform_profile` on DT boot: **source transform ready; runtime framework validation blocked by wrong-arch packaged host tool**
- GNOME stock Power Saver/Balanced/Performance mapping: **fallback bridge exists; Power Saver must map to the new distinct `power-saver` policy, not Quiet**
