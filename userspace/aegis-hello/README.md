# Aegis Hello — A14 IR integration

The UX3407RA PM8550 flash device exposes two distinct hardware paths:

- **Flash/strobe** — short synchronized pulses.
- **Torch** — continuous illumination through V4L2 `led_mode=2` and `intensity_torch_mode`.

Aegis Hello 0.8.3 used the LED-class `brightness` file for continuous IR. On this A14 that is not the same control path as the PM8550 V4L2 Torch mode, which explains why flash works while continuous illumination stays dark.

`patches/aegis-hello-0.8.3-v4l2-torch.patch` changes continuous mode to use the real PM8550 V4L2 Torch controls. `patches/aegis-hello-0.8.3-v4l2-torch-force-gate.patch` then fixes the A14-specific HM1092 safety-gate interaction: `force_off=1` is the immediate-LOW state used by synchronized flash windows, so continuous Torch must release it (`force_off=0`) before selecting Torch. A synchronized flash window can temporarily drive the emitter after establishing the LOW safety state; a continuous Torch request has no such window and otherwise remains physically dark even if V4L2 reads back `led_mode=2`.

The resulting continuous path:

1. disables the SOF/strobe route;
2. discovers the V4L2 flash subdevice containing `led_mode` and `intensity_torch_mode`;
3. sets `intensity_torch_mode` using the driver's advertised min/max/step;
4. releases the HM1092 immediate-LOW `force_off` gate;
5. selects `led_mode=2` (Torch);
6. verifies the mode/current readback;
7. restores `led_mode=0` and the forced-LOW safety state on disable or error.

It leaves the already-working synchronized flash/strobe capture path alone.

## Source-tree application

From an unmodified Aegis Hello 0.8.3 source tree:

```sh
/path/to/asus-zenbook-a14-ec/scripts/a14-apply-aegis-ir-torch-fix.sh /path/to/aegis-hello-0.8.3
sudo /path/to/aegis-hello-0.8.3/scripts/install.sh
```

For an already-installed 0.8.3 system, including one with the older A14 V4L2 Torch patch, use:

```sh
sudo /path/to/asus-zenbook-a14-ec/scripts/a14-hotfix-installed-aegis-ir-torch.sh
```

The implementation requires `v4l2-ctl` (`v4l-utils`) at runtime for the Torch control path.

The patch is intentionally fail-safe: continuous enable releases the A14 gate only while Torch is requested; disable/error paths restore the forced-LOW state. Physical steady-IR operation should be verified with `scripts/a14-ir-torch-smoke.sh` on the laptop.
