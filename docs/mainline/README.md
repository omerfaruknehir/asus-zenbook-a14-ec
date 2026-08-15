# ASUS Zenbook A14 plain-mainline enablement

Goal: start from an unmodified upstream Linux source tree and layer all UX3407RA-specific support from this repository on top. Ubuntu downstream camera code is evidence/backport material, not a runtime or source-tree dependency.

## Layers

1. **Platform HID / shortcut keys** — works independently of the camera stack and should build against ordinary upstream headers. The A14 HID device is ASUS `0b05:0220`, feature-report ID `0x5a`.
   - Fn+F4: keyboard-backlight cycle through the standard LED class.
   - Fn+F5/F6: `KEY_BRIGHTNESSDOWN` / `KEY_BRIGHTNESSUP`.
   - Fn+F8: emoji picker key.
   - Fn+F9: microphone mute key.
   - Fn+F10: camera-access toggle event. This is **not** treated as an enforced privacy lock until a real camera-blocking backend is proven.
   - Fn+F11: touchpad toggle.
   - Fn+F12: programmable key.
   - Fn+F: ordered A14 profile cycle: Whisper → Quiet → Normal → Turbo → Full Speed → Whisper.
   - Fn+Esc: firmware function-key-mode/Fn-lock support belongs here; do not depend on ASUS-WMI on this ARM64 platform.

2. **EC / thermal / fan support** — out-of-tree A14 EC module until it is suitable for upstream subsystem integration. It must retain the existing warm-reboot/suspend safety rules and restore firmware automatic fan ownership on teardown. Quiet, Normal, Turbo and Full Speed are ASUS native firmware modes. Whisper is the sole synthetic acoustic-first mode.

3. **CPU DVFS / CPUFreq** — a required upstream X1E subsystem, not an A14-specific fake. Hamoa maps its three four-core Oryon clusters onto SCMI Performance domains 0, 1 and 2 through the Qualcomm CPUCP mailbox. A correct boot must expose Linux CPUFreq policies (normally `policy0`, `policy4`, `policy8`). This is required for:
   - Resources live/max CPU frequency reporting;
   - Whisper CPU `freq_qos` caps;
   - ordinary Linux CPUFreq tools and governors.

   The A14 mainline config helper deliberately builds the whole path in:

   ```text
   QCOM_CPUCP_MBOX
          ↓
   ARM_SCMI_TRANSPORT_MAILBOX
          ↓
   ARM_SCMI_PROTOCOL / Performance protocol 0x13
          ↓
   ARM_SCMI_CPUFREQ
          ↓
   policy0 / policy4 / policy8
   ```

4. **Camera** — upstream-oriented CAMSS/CCI/CSIPHY + OV02C10 + HM1092 + EEPROM patches under `kernel-patches/camera/`. The current board patch stack still needs the X1E80100/Hamoa camera DT infrastructure backported when the selected upstream tag does not contain it.

5. **AOS / Human Presence** — SSC/QMI/IIO work under `kernel/aos/` and `kernel-patches/aos/`. Direct CPAS ownership-mux MMIO remains prohibited because both reads and writes reset this machine.

6. **Userspace** — only for policy/image processing that does not belong in the kernel: libcamera SoftISP tuning, UI, desktop integration, and (if required) a camera-privacy policy frontend. Userspace must not fake hardware support. In particular, Resources must display CPU frequency from kernel CPUFreq/SCMI data rather than hard-coded X1E clocks.

## SCMI CPUFreq setup

After preparing the upstream source tree, either create `.config` first and let `a14-mainline-compose.sh` enforce the required options, or run the helper directly:

```bash
make ARCH=arm64 defconfig
/path/to/asus-zenbook-a14-ec/scripts/a14-mainline-scmi-cpufreq-config.sh /path/to/linux
```

It requires these options built-in:

```text
CONFIG_CPU_FREQ=y
CONFIG_CPU_FREQ_STAT=y
CONFIG_CPU_FREQ_GOV_SCHEDUTIL=y
CONFIG_PM_OPP=y
CONFIG_MAILBOX=y
CONFIG_QCOM_CPUCP_MBOX=y
CONFIG_ARM_SCMI_PROTOCOL=y
CONFIG_ARM_SCMI_TRANSPORT_MAILBOX=y
CONFIG_ARM_SCMI_CPUFREQ=y
```

After booting the kernel, audit the live path with:

```bash
./scripts/a14-cpufreq-diag.sh --try-load
```

A healthy X1E boot should produce at least three CPUFreq policies, with the three four-core clusters associated with SCMI domains 0/1/2. If no policies exist, do **not** paper over the problem in Resources; inspect the SCMI/CPUCP/config/kernel log section from the diagnostic output.

## Build philosophy

The canonical source is this repository. Downloaded Linux source trees are disposable build inputs. A build should be reproducible from:

- an upstream Linux tag/commit;
- this repository commit;
- optional proprietary firmware already present on the machine, verified by hashes rather than redistributed.

The final workflow should be one command that checks the upstream tree, applies the required backports and A14 patches in dependency order, validates the SCMI CPUFreq configuration, builds the affected DTB/modules, and emits a manifest. Rebuilding the complete kernel image is required when changing built-in SCMI/CPUFreq configuration; it is optional for changes deliverable entirely as modules/DTB.

## Validation records

Keep hardware observations in the repository so later changes can be compared against an explicit baseline.

- [`docs/suspend/2026-08-14-deep-suspend-battery.md`](../suspend/2026-08-14-deep-suspend-battery.md) — approximately one hour in `deep` suspend, 50% → 42% battery, with no immediate auto-resume.
- [`docs/ec/2026-08-14-native-profile-validation.md`](../ec/2026-08-14-native-profile-validation.md) — EC transport/manual PWM validation, quiet-profile load evidence, and the DT `platform_profile` host-tool blocker.

## Privacy rule

`KEY_CAMERA_ACCESS_TOGGLE` means the shortcut was decoded. It does **not** prove capture is blocked. The integration must only report an enforced camera privacy lock once a kernel/V4L2/firmware mechanism has been implemented and tested to reject capture.
