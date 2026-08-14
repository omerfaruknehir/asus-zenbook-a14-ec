# A14 native EC/profile validation — 2026-08-14

Permanent hardware-validation record for the ASUS Zenbook A14 UX3407RA.

## Runtime transport/manual-PWM validation

Using `scripts/a14-ec-runtime-validation.sh` on Linux `7.1.5-070105-generic`:

- local `asus_zenbook_a14_ec.ko` inserted successfully;
- private profile node exposed `quiet balanced performance full-speed` at the time of this capture;
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

## Complete fresh-load four-native-mode capture

The revised validator used six CPU load threads, an 82 C cutoff, and a fresh/cool start for every requested native firmware profile. All four recovered firmware modes completed without reaching the cutoff:

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

Full-speed is a genuine separate firmware mode, not an alias for performance. The native full-speed curve approached but did not reach PWM 255 in this short capture.

## Linux policy derived from the hardware capture

The firmware modes and desktop power modes must not be conflated. Version 0.3.0 implements the following Linux-facing policy on top of the validated firmware controls:

- `quiet`: acoustic-first. Native Quiet plus a strong per-cpufreq-policy QoS cap (default 45%). At the emergency threshold, retain the CPU cap but temporarily request native Turbo cooling. If cpufreq QoS is unavailable entirely, immediately force Turbo cooling and notify rather than pretending throttle-first Quiet is safe.
- `power-saver` / standard `low-power`: ordinary battery-saving behavior. Native Normal plus a moderate per-cpufreq-policy cap (default 70%).
- `balanced`: native Normal with no artificial CPU cap.
- `performance`: native Turbo with no artificial CPU cap.
- `full-speed` / standard `max-power`: native Full Speed plus literal PWM 255 on both fans, with no artificial CPU cap. Hardware/firmware/kernel thermal protection remains intact.
- `custom`: direct hwmon manual PWM only.

The 0.3.0 implementation makes named profile transitions transactional across low-level fan ownership, native firmware marker, CPU QoS, and Quiet-emergency state. Failed transitions restore the previous coherent named policy; arbitrary `custom` PWM is not replayed after unsafe transitions or sleep.

## CPU-frequency control evidence

Earlier A14 captures show working per-CPU cpufreq telemetry such as `/sys/devices/system/cpu/cpuN/cpufreq/cpuinfo_avg_freq`, including values from roughly 0.8 GHz to 3.4 GHz depending on core/load. Therefore Linux `freq_qos` is the appropriate kernel mechanism for the Quiet and Power Saver caps. The first load validator looked only for `policy*/scaling_cur_freq`, so its `cpu_freq_* = unavailable` output did not prove cpufreq was absent.

The 0.3.0 validator now reads the A14's real per-CPU average-frequency telemetry and also records the effective `scaling_max_freq`/native maximum values so the percentage-based QoS policy can be verified on hardware.

## Standard Linux platform_profile validation

The earlier DT `platform_profile` source transform applied cleanly, but the temporary out-of-tree framework-module build was blocked by an Ubuntu/mainline header-package host-tool mismatch:

```text
CONFIG_ACPI_PLATFORM_PROFILE=m
CONFIG_GENDWARFKSYMS=y
.../scripts/gendwarfksyms/gendwarfksyms: ELF 64-bit x86-64
... Exec format error
```

A later fallback also found that the packaged headers do not contain an executable `scripts/genksyms/genksyms`. This is a host-tool packaging/architecture problem, not an EC source-code compile error.

The current 0.3.0 validation script no longer changes symbol-versioning schemes. If the packaged tool is wrong-architecture, it builds a native ARM64 `gendwarfksyms` from the exact Linux 7.1.5 source in an isolated output tree and overrides Kbuild's host-tool command only for this disposable framework-module validation.

Expected standard mapping after runtime validation:

```text
low-power   -> power-saver
quiet       -> quiet
balanced    -> balanced
performance -> performance
max-power   -> full-speed
```

## GNOME integration implemented in 0.3.0

GNOME's stock three-mode power UI maps to Power Saver / Balanced / Performance. Quiet is deliberately not collapsed into Power Saver, and Full Speed is not collapsed into Performance.

The package therefore also installs a narrow root-owned system D-Bus profile service and an **A14 Mode** GNOME Quick Settings menu exposing all five modes:

```text
Quiet
Power Saver
Balanced
Performance
Full Speed
```

The desktop API exposes only named profile selection and Quiet-emergency state; it exposes no raw EC registers, manual PWM, firmware mailbox, or MMIO access.

Quiet emergency state is available at:

```text
/sys/devices/platform/asus_zenbook_a14_ec/quiet_emergency
```

and kernel uevents carry a reason (`thermal`, `recovered`, `profile-change`, or `qos-unavailable`) so desktop notifications accurately explain why cooling was escalated.

## Status after implementation, before 0.3.0 hardware revalidation

- EC byte transport: **validated**
- firmware AUTO ownership: **validated**
- manual PWM: **validated**
- balanced native mode: **validated under load**
- quiet native mode: **validated under load**
- performance native mode: **validated under load**
- full-speed native mode: **validated under load**
- ordering `quiet < balanced << performance < full-speed`: **validated**
- Quiet vs Power Saver OS policy separation: **implemented in 0.3.0; hardware revalidation pending**
- percentage-based Quiet/Power Saver CPU QoS: **implemented; hardware revalidation pending**
- literal PWM-255 Full Speed policy: **implemented; hardware revalidation pending**
- Quiet thermal emergency + desktop notification: **implemented; safe threshold-based validation pending**
- Quiet missing-QoS fail-safe: **implemented; structural/CI validation pending, runtime fault injection optional**
- standard Linux `platform_profile`: **implementation ready; runtime validation pending with native ARM64 host-tool workaround**
- GNOME stock three-profile mapping: **implemented; runtime validation pending**
- GNOME all-five-mode A14 Quick Settings menu: **implemented; runtime validation pending**
