# AOS kernel patch series

This directory is reserved for reviewable kernel patches. It intentionally does
not contain a speculative all-in-one module.

Planned split:

1. `media: ov02c10`: support multiple modes and add the A14 320×240 AOS mode.
2. `dt-bindings`: describe any physical AOS/QSH relationship not covered by an
   existing generic binding.
3. `arm64: dts: qcom`: add the A14 wiring/resources using the binding.
4. `soc: qcom` or the appropriate sensor subsystem: restart-safe QSH client.
5. `iio`: expose standard presence/distance data if a new frontend is needed.

Patch files will be added only after they build against the running Ubuntu
kernel and current upstream, pass DT schema checks where applicable, and have a
hardware report showing the exact interfaces available on the machine.
