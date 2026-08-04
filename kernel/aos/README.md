# Qualcomm SSC human-presence kernel development driver

This is a kernel driver development step, not a userspace bridge. It uses the
in-kernel Qualcomm QMI/QRTR framework and exposes data through IIO.

It is deliberately separate from the EC DKMS package and is never built,
installed, or loaded by `install.sh`.

## Current scope

- Dynamically discovers QMI service 400/version 1/instance 0.
- Reconnects using the advertised QRTR node and port rather than hard-coding
  transient endpoint numbers.
- Discovers SUIDs for:
  - `camera_handshake`
  - `human_presence_detect`
  - `camera_face_detect`
- Sends the machine-confirmed OV02C10 handshake INIT 576.
- Requires successful ACK 832 before sending HPD configuration 512.
- Decodes presence event 928 and exposes it as an IIO proximity channel with
  change events.
- Releases the QMI client on disable or service loss, which removes all SSC
  requests owned by that client.
- Is gated to `asus,zenbook-a14-ux3407ra`.

## Build

```bash
cd kernel/aos
make
```

The build requires headers for the running kernel and `CONFIG_QRTR`,
`CONFIG_QCOM_QMI_HELPERS`, and `CONFIG_IIO` support.

## Initial safe test

Loading the module performs only QMI service and SUID discovery. It does not
activate the camera handshake automatically.

```bash
sudo insmod ./qcom_ssc_hpd.ko
sudo dmesg --ctime | grep -E 'qcom-ssc-hpd|SSC datatype|SSC QMI'
```

Expected discovery messages include the service endpoint and all available
SUIDs. Find the IIO device with:

```bash
for d in /sys/bus/iio/devices/iio:device*; do
    [ "$(cat "$d/name" 2>/dev/null)" = qcom-ssc-human-presence ] && echo "$d"
done
```

## Lifecycle activation test

The IIO event-enable attribute invokes the real camera handshake and then the
HPD subscription. Locate rather than assume the kernel-generated filename:

```bash
IIO=/sys/bus/iio/devices/iio:deviceX
find "$IIO/events" -maxdepth 1 -type f -print
```

Then write `1` to the `*_en` file. On the current firmware state, the most
likely first result is a three-second timeout waiting for ACK 832. That is a
useful kernel-level reproduction of the remaining QSH lifecycle failure, not a
claim that presence is already fixed.

Writing `0` closes the QMI client and reconnects in an idle discovery state.

## Removal

```bash
sudo rmmod qcom_ssc_hpd
```

## Not yet complete

- The exact QSH configuration-loading path for the machine-specific OV02C10
  JSON/protobuf/module blobs is still being decoded.
- Camera ownership release should eventually use the documented QSH release
  message in addition to client teardown.
- The development module must be converted into subsystem patches and reviewed
  for generic Qualcomm machine support before upstream submission.
