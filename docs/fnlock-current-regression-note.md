# UX3407RA Fn-lock current regression note

This note supersedes the earlier sentence in `fnlock-geni-datapath-analysis.md`
that said the keyboard-backlight regression had been corrected.

The tester subsequently clarified that keyboard backlight and related keyboard
functionality are still not working correctly in Linux after the cold-boot
HIDI2C skip-probe experiment. Treat the regression as unresolved until the
experimental `i2c-hid` override is explicitly removed, stock `i2c-hid` and
stock `i2c-qcom-geni` resolve for kernel 7.1.5, and a full power-off/power-on
baseline is tested.

Do not stack further Fn-lock HIDI2C/GENI experiments on this Linux state. The
next Fn-lock work remains measurement-first on Windows (qci2c IFR/live
controller state) once the Linux baseline is restored.
