# A14 native EC/profile validation — 2026-08-14

Permanent hardware-validation record for the UX3407RA.

## Runtime transport/manual-PWM validation

Using `scripts/a14-ec-runtime-validation.sh` on Linux `7.1.5-070105-generic`:

- local `asus_zenbook_a14_ec.ko` inserted successfully;
- private profile node exposed `quiet balanced performance full-speed`;
- all four native profile writes returned success and read back the requested state;
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

This strongly validates the low-level fan ownership/PWM path independently of the native firmware thermal profiles.

## Native profile load test

A 12-thread CPU load was started. The test reached the 85 C system-temperature safety cutoff while testing `quiet`, so it stopped before `performance` and `full-speed`.

### Balanced under load

Samples progressed from:

```text
system_max_temp_mc=70600 fan1_rpm=4418 fan2_readout=1320 pwm1=86 pwm2=77
```

to:

```text
system_max_temp_mc=79100 fan1_rpm=5170 fan2_readout=1672 pwm1=116 pwm2=112
```

### Quiet under load

Samples progressed from:

```text
system_max_temp_mc=79500 fan1_rpm=4418 fan2_readout=1496 pwm1=86 pwm2=89
```

to the safety cutoff:

```text
system_max_temp_mc=85100 fan1_rpm=4321 fan2_readout=1320 pwm1=79 pwm2=79
thermal_cutoff=true hottest_mc=85100 cutoff_mc=85000
```

The hottest zone at cutoff was `cpu2-3-btm-thermal`.

### Interpretation

The quiet profile is behaviorally distinct from balanced under sustained load: while package/system temperature continued rising, firmware-requested PWM/fan response stayed materially lower than the preceding balanced run. This is consistent with the recovered Windows/DSDT design, where native profile selection changes thermal policy rather than commanding a fixed fan duty.

This capture does **not** yet validate performance or full-speed behavior because the safety cutoff ended the test first. A revised test must use lower load and per-profile cooldown/reset periods.

## Standard Linux platform_profile validation

The DT platform-profile transform applied cleanly, but the temporary out-of-tree `platform_profile.ko` build failed before compilation completed:

```text
/usr/src/linux-headers-7.1.5-070105-generic/scripts/gendwarfksyms/gendwarfksyms: Exec format error
platform_profile_build_rc=2
A14_PLATFORM_PROFILE_DT_VALIDATION=FAIL
```

`CONFIG_ACPI_PLATFORM_PROFILE=m` is enabled in the running kernel.

This is a host-tool packaging/architecture problem in the installed header tree, not a source-code compile diagnostic from the DT transform. The ordinary A14 EC/HID modules build because they do not export symbols; `platform_profile.c` exports symbols and therefore triggers the `CONFIG_GENDWARFKSYMS` path.

## Status after this capture

- EC byte transport: **validated**
- firmware AUTO ownership: **validated**
- manual PWM: **validated**
- balanced native profile command: **accepted**
- quiet native profile: **accepted and behaviorally differentiated under load**
- performance native profile: **command accepted; loaded behavior still to validate**
- full-speed native profile: **command accepted; loaded behavior still to validate**
- standard Linux `platform_profile`: **source transform pending runtime validation because of host-tool build failure**
