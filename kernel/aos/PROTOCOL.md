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
- `0x01`: variable-length SSC client request bytes

Report indication TLVs:

- `0x01`: 64-bit client ID
- `0x02`: variable-length SSC event bytes

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
| Camera handshake ACK | 832 |
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
