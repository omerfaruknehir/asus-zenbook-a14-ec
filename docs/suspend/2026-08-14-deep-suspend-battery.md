# UX3407RA deep-suspend battery validation — 2026-08-14

Permanent hardware-validation record for the ASUS Zenbook A14 UX3407RA.

## Observed suspend interval

User-provided boot journal:

```text
Aug 14 21:48:16 0x05AD-ZenBook kernel: PM: suspend entry (deep)
Aug 14 22:47:57 0x05AD-ZenBook kernel: PM: suspend exit
```

Battery state reported by the user:

- suspend entry: **50%**
- resume: **42%**
- elapsed wall time: **59 min 41 s**
- observed battery drop: **8 percentage points**
- coarse percentage-based rate: approximately **8.0 percentage points/hour**

## Interpretation

This is evidence that `deep` suspend remained entered for roughly one hour without the old immediate auto-resume failure. It is **not** evidence that suspend power consumption is solved: an 8-point drop in about one hour is still high and needs follow-up with energy/charge counters where available, wake-source accounting, and repeated longer samples.

Battery percentage is a coarse UI/state-of-charge measure, so do not treat the percentage-derived rate as an exact wattage measurement.

## Follow-up

Preserve this interval as the baseline when evaluating later suspend fixes. Future captures should include, when available:

- `energy_now` / `energy_full` or `charge_now` / `charge_full` immediately before suspend and after resume;
- suspend/resume timestamps;
- `/sys/kernel/debug/wakeup_sources` deltas;
- `suspend_stats`;
- any EC / HID / camera / SSC resume errors.
