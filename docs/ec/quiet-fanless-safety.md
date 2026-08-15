# A14 fanless Quiet safety contract

This document records the hardware findings behind the A14 Quiet policy so the
implementation does not regress to either an always-audible firmware curve or
an unsafe blind fan stop.

## Why native Quiet alone is not silent

The recovered ASUS native profile `0x02` is a real firmware thermal policy, but
hardware load captures showed that it still runs the fans at an audible low
speed. Therefore selecting the native Quiet marker alone does not satisfy the
A14 Linux Quiet contract.

## cpufreq ordering issue

The EC module is intentionally loaded late, but the Snapdragon cpufreq provider
can still be unavailable when the EC driver first calls `cpufreq_cpu_get()`.
The machine has subsequently been observed with working per-CPU cpufreq data at
`/sys/devices/system/cpu/cpuN/cpufreq/cpuinfo_avg_freq`, so a zero-request probe
result must not be treated as permanent.

The driver therefore retries freq-QoS attachment when Quiet/Power Saver is
selected and while a QoS-unavailable Quiet fail-safe remains active.

## Real UX3407RA thermal zones

The original driver looked for generic names such as `cpu0-thermal`. The actual
A14 thermal inventory uses CPU/cluster names in these families:

- `cpu0-0-top-thermal` ... `cpu0-3-btm-thermal`
- `cpu1-0-top-thermal` ... `cpu1-3-btm-thermal`
- `cpu2-0-top-thermal` ... `cpu2-3-btm-thermal`
- `cpuss0-top-thermal`, `cpuss0-btm-thermal`
- `cpuss1-top-thermal`, `cpuss1-btm-thermal`
- `cpuss2-top-thermal`, `cpuss2-btm-thermal`

Adjacent Qualcomm builds have also exposed underscore spellings, so the driver
accepts both forms. The hottest readable zone plus the EC temperature is used
for Quiet emergency decisions.

## Fail-closed prerequisites

Quiet may command fan PWM 0 only when BOTH conditions are true:

1. at least one cpufreq `FREQ_QOS_MAX` request has been attached; and
2. at least one real A14 CPU/CPU-subsystem thermal zone was found.

If either prerequisite is missing, Quiet remains selected from the user's point
of view but the fans stay firmware-owned and the native Turbo cooling profile
is requested. A critical desktop notification explains the missing safety
prerequisite.

## Quiet policy

Normal Quiet:

1. select native ASUS Quiet (`0x02`);
2. apply the configured per-policy CPU frequency cap (default 45%);
3. take low-level fan ownership;
4. command both fans to `quiet_fan_pwm` (default 0);
5. continuously monitor the real CPU thermal zones.

Thermal emergency:

1. retain CPU throttling;
2. return low-level fan ownership to firmware AUTO;
3. select native Turbo (`0x04`);
4. emit the Quiet emergency uevent/desktop notification.

Recovery:

1. select native Quiet (`0x02`);
2. re-establish the CPU cap;
3. re-enter the configured Quiet fan PWM;
4. clear the emergency notification.

The machine's independent SoC/kernel/firmware critical thermal protection is
not disabled by this policy.

## Validation rule

Do not start with a thermal stress test. First run the no-load fanless validator
while the hottest CPU thermal zone is below 70 C. It must prove real-zone
availability, emergency state 0, manual fan ownership, PWM 0/0 and fan spin-down,
then restore Balanced. Only after that passes should emergency hysteresis be
validated.
