# Resources A14 patch archive

This directory keeps the exact Resources patch artifacts used during the A14/X1E bring-up, alongside the maintained repair/apply scripts one directory above.

The patch files are intentionally preserved as historical artifacts. They are useful for audit and reproduction, but they are **not all a single linear patch series**: some later patches revise or undo presentation choices from earlier ones. The canonical maintained integration is the Python patch/repair tooling under `desktop/resources/`, including the current SCMI CPUFreq repair.

## Exact artifacts

| File | SHA-256 | Purpose |
| --- | --- | --- |
| `resources-a14-msm-adreno.patch` | `421f948c6d5fa70161d357dbc4ea77e49c900e2be6d8099965ba93428c61fef7` | Initial MSM/Adreno Resources backend: DRM fdinfo usage, devfreq clock, temperature and platform GPU support. |
| `resources-a14-msm-adreno-qcom-sensors.patch` | `b42bb4abd1c177b202020fa48198d4bc67648481b5810c8f6b6488b2b835efb1` | Qualcomm CPU/GPU thermal-zone and platform presentation follow-up. |
| `resources-a14-a14-sensors-followup.patch` | `1223db795786a91e7a1702708e785b848b3c06455b89fc3c4e6931b3f12e1a16` | A14 sensor/vendor/platform-device follow-up. |
| `resources-a14-qcom-gpu-cpu-polish.patch` | `8e39ccdfa387c9555bc3bf03053d1138d184827b946bfec11c23851eb6522839` | CPU topology and Qualcomm GPU UI polish. |
| `resources-a14-real-data-only.patch` | `cc99255d111bef737dbd4810d9f967209032ddb1bd24bbc2a92223572a35be72` | Removes invented placeholder values and returns to N/A when hardware data is not exposed. |

## Current maintained A14 integration

Use the scripts in `desktop/resources/` for the current custom Resources tree rather than blindly replaying every historical patch:

- `apply-a14-cpu-info.py`
- `repair-a14-cpu-info.py`
- `repair-a14-cpu-topology.py`
- `repair-a14-gpu-metrics.py`
- `repair-a14-cpu-frequency.py`

The CPU-frequency repair reads the real Linux CPUFreq/SCMI policy data. It does not synthesize MHz values when the kernel has no registered policy.
