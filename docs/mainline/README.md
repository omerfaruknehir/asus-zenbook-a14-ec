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
   - Fn+F: performance/profile key.
   - Fn+Esc: firmware function-key-mode/Fn-lock support belongs here; do not depend on ASUS-WMI on this ARM64 platform.

2. **EC / thermal / fan support** — out-of-tree A14 EC module until it is suitable for upstream subsystem integration. It must retain the existing warm-reboot/suspend safety rules and restore firmware automatic fan ownership on teardown.

3. **Camera** — upstream-oriented CAMSS/CCI/CSIPHY + OV02C10 + HM1092 + EEPROM patches under `kernel-patches/camera/`. The current board patch stack still needs the X1E80100/Hamoa camera DT infrastructure backported when the selected upstream tag does not contain it.

4. **AOS / Human Presence** — SSC/QMI/IIO work under `kernel/aos/` and `kernel-patches/aos/`. Direct CPAS ownership-mux MMIO remains prohibited because both reads and writes reset this machine.

5. **Userspace** — only for policy/image processing that does not belong in the kernel: libcamera SoftISP tuning, UI, desktop integration, and (if required) a camera-privacy policy frontend. Userspace must not fake hardware support.

## Build philosophy

The canonical source is this repository. Downloaded Linux source trees are disposable build inputs. A build should be reproducible from:

- an upstream Linux tag/commit;
- this repository commit;
- optional proprietary firmware already present on the machine, verified by hashes rather than redistributed.

The final workflow should be one command that checks the upstream tree, applies the required backports and A14 patches in dependency order, builds the affected DTB/modules, and emits a manifest. Rebuilding the complete kernel image is optional unless a required change cannot be delivered as a module/DTB.

## Privacy rule

`KEY_CAMERA_ACCESS_TOGGLE` means the shortcut was decoded. It does **not** prove capture is blocked. The integration must only report an enforced camera privacy lock once a kernel/V4L2/firmware mechanism has been implemented and tested to reject capture.