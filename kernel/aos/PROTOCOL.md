# Confirmed SSC protocol subset

## QMI layer

- Service: 400
- Version: 1
- Instance: 0
- Control request/response: message `0x20`
- Small report indication: `0x21`
- Large report indication: `0x22`

Control request TLVs:

- `0x10`: one-byte report type, value 1
- `0x01`: opaque SSC client request bytes

Report indication TLVs:

- `0x01`: 64-bit client ID
- `0x02`: opaque SSC event bytes

### Important Data-TLV framing rule

The SSC Data TLV is not a QMI IDL variable array with an additional encoded
array count. Its first two payload bytes are already the SSC client's own
little-endian frame length.

Correct wire layout:

```text
QMI TLV type=0x01 length=N
  SSC frame length=N-2
  SSC protobuf body
```

Incorrect layout previously emitted by the development driver:

```text
QMI TLV type=0x01 length=N+2
  QMI array length=N
  SSC frame length=N-2
  SSC protobuf body
```

That malformed request was accepted at the QMI transport layer but produced no
SUID indication. Outgoing Data TLVs therefore use a request-local
`STATIC_ARRAY` descriptor whose element count is exactly the already-framed SSC
buffer length. No `QMI_DATA_LEN` element is used for control requests.

Incoming report Data TLVs begin with the same SSC frame length. The receive
descriptor consumes that u16 into `data_len` and passes the remaining protobuf
body to the protocol parser.

## SSC client envelope

The Data TLV starts with a two-byte little-endian protobuf length, followed by:

- field 1: target SUID message
- field 2, fixed32: sensor message ID
- field 3: standard request options (`08 01 10 00`)
- field 4: sensor-specific payload

## Machine-confirmed messages

| Message | ID |
|---|---:|
| SUID request | 512 |
| SUID event | 768 |
| Camera handshake INIT | 576 |
| Camera handshake INIT ACK | 832 |
| Camera release control | 577 |
| Camera release control ACK | 833 |
| Camera revoke control | 579 |
| Camera revoke control ACK | 835 |
| HPD configuration | 512 |
| Presence event | 928 |
| Standard error event | 130 |

Handshake INIT client-data fixture:

```text
2e00
0a12 09a1964b507bf7e3e0 11eef435f8287516a7
1540020000
1a0408011000
220d 0a076f763032633130 1000 1802
```

The two SUID fixed64 values are serialized exactly as returned by the SSC SUID
service. The driver discovers them at runtime; the fixture is retained only for
regression comparison.

## Hardware validation status

The A14 now returns all three runtime SUIDs through the in-kernel QMI client:

- `camera_handshake`
- `human_presence_detect`
- `camera_face_detect`

INIT 576 is accepted by the QMI control service but the current firmware state
does not emit ACK 832. This is therefore beyond QRTR, QMI framing and SUID
discovery. The remaining investigation is camera/QSH lifecycle and AOC resource
ownership.

The previously installed Stage 12 reverse-filesystem runtime already contains
the same verified `qsh_camera.json`, `qsh_camera_ov02c10_2.json` and
`ov02c10_2.pb` files later extracted directly from Windows, including flattened
QSH camera registry groups. Do not replace the known-matched ADSP image merely
because ACK 832 is absent. First verify that the Qualcomm reverse-filesystem
service and exact registry tree are available from the beginning of the current
boot.

## Recovery requirements

A failed INIT must not leave the laptop dependent on a cold reboot. The
kernel-development driver therefore treats the SSC client as the ownership
unit:

- failed activation tears down that client immediately;
- a fresh client reconnects and rediscovers SUIDs automatically;
- suspend quiesces the client before the remote service changes state;
- resume starts clean rediscovery;
- unload/shutdown prevents reconnect work and releases the client.

Explicit RELEASE/REVOKE messages will be used once successful ownership has
been demonstrated. Until then, complete SSC-client teardown is safer than
sending an unvalidated release payload after an INIT timeout.
