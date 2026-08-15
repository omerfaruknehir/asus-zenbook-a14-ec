# Aegis Hello — A14 IR integration

The UX3407RA PM8550 flash device exposes two distinct hardware paths:

- **Flash/strobe** — short synchronized pulses.
- **Torch** — continuous illumination through V4L2 `led_mode=2` and `intensity_torch_mode`.

Aegis Hello 0.8.3 used the LED-class `brightness` file for continuous IR. On this A14 that is not the same control path as the PM8550 V4L2 Torch mode, which explains why flash works while continuous illumination stays dark.

`patches/aegis-hello-0.8.3-v4l2-torch.patch` changes continuous mode to:

1. disable the SOF/strobe route;
2. discover the V4L2 flash subdevice containing `led_mode` and `intensity_torch_mode`;
3. set `intensity_torch_mode` using the driver's advertised min/max/step;
4. select `led_mode=2` (Torch);
5. verify the mode/current readback;
6. return to `led_mode=0` on disable or error.

It leaves the already-working flash/strobe capture path alone.

## Source-tree application

From an unmodified Aegis Hello 0.8.3 source tree:

```sh
patch -p1 < /path/to/asus-zenbook-a14-ec/userspace/aegis-hello/patches/aegis-hello-0.8.3-v4l2-torch.patch
./scripts/build.sh
sudo ./scripts/install.sh
```

The implementation requires `v4l2-ctl` (`v4l-utils`) at runtime for the Torch control path.

The patch was Python-compiled and the Aegis Hello 0.8.3 Python test suite passed after application. Physical steady-IR operation still has to be confirmed on the laptop; the patch deliberately verifies V4L2 readback so a failed hardware transition is reported instead of being assumed successful.
