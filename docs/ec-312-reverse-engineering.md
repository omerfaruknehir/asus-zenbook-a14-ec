# UX3407RA BIOS 312 EC reverse engineering

## Scope and provenance

The official `UX3407RA.312` capsule contains a 262,144-byte ITE EC payload with
identity `ITE51300-EC-V0.00` and SHA-256
`353eb0d125d76a14f15faa72f2153d57e25efd8d212f42b18a9f11c16e3fc39d`.
Its reset code and compressed instructions identify it as RISC-V RV32IMC.

The full UEFI inventory was also checked. `AsusEc`, `I2cKbDxe`, and
`HWIODxeDriver` are AArch64 PE/COFF modules, but none contains the literal HID
Fn-switch or keyboard-light feature payload. A single `5a d0 4e` byte match in
the extracted image was inside the high-entropy `QCWLAN_XZFW2/amss.bin` payload
and is a compression coincidence. The authoritative command implementation is
inside the EC image.

## Recovered Fn-switch path

The feature parser at EC offsets `0xED3A..0xEE1E` recognizes the exact report
used by Windows and the early Linux implementation:

```text
5a d0 4e 00 ...  -> queue action/media keys as primary
5a d0 4e 01 ...  -> queue ordinary F1..F12 as primary
```

The state byte does not switch the row synchronously. The two handlers set
request bits in EC RAM byte `0x00803049`:

| Handler | Request bit | Meaning |
|---|---:|---|
| `0xF82C` | `0x04` | action/media row requested |
| `0xF83E` | `0x08` | F1-F12 row requested |

The service routine at `0xF850` applies a queued request only when:

- byte `0x00800410` is zero; and
- bit 7 of halfword `0x0080041A` is set.

When serviced, bit 1 of `0x00803049` is the current Fn-row state. This explains
why a successful HID transfer alone does not prove that the physical row
changed: the EC can accept and queue a request while its internal service gates
prevent application.

## Recovered D0/8F auxiliary state path

The original base driver initialization command is a real EC command:

```text
5a d0 8f 01 ...
```

The dispatcher calls `0x10310`, which sets bit 7 and clears bit 6 in
`0x008012A0`, then calls `0x102F8` to clear the associated mode/counter at
`0x008012A1..0x008012A3`. Callers at `0x11000` and `0x11F6C` show that this is a
separate timed state machine. No instruction path from these bytes to the
Fn-switch gates has been found.

Package 0.5.15 restored this transaction before `D0/4E`; hardware testing still
showed no physical row change. It is therefore disproven as a sufficient
Fn-lock prerequisite and has been removed from the production sequence. Its
public purpose remains unknown.

## Recovered keyboard-light path

The parser recognizes:

```text
5a ba c5 c4 <level> ...
```

The target at `0xFFDC` is a four-way selector. It accepts logical levels 0..3
and maps them to internal values `00`, `43`, `87`, and `CC`. Any other value,
including 255, follows the level-zero path. The stock EC command therefore does
not expose native 8-bit keyboard-light PWM despite accepting a 64-byte feature
report.

## HID feature ledger

This is the complete set of command families currently recovered from the
`0xEB10..0xEE5A` report parser. “Unknown” means the dispatcher and target are
located but the external feature name has not been guessed.

| Report prefix | Recovered behavior | Confidence |
|---|---|---|
| `5a 05 20 31 00 08` | capability/configuration response | parser and response proven |
| `5a ba c5 c4 <0..3>` | four-level keyboard-light target | handler proven |
| `5a d0 4e <0\|1>` | queue Fn-row selection | handler and service proven |
| `5a d0 7c <0\|1>` | set internal channel `0x3a` | dispatch proven; public meaning unknown |
| `5a d0 85 ff 00` | status/query response | response construction proven; fields unknown |
| `5a d0 85 ff 80` | set bit 7 of EC byte `0x00803024` | handler proven; public meaning unknown |
| `5a d0 8f 01` | start/reset auxiliary timed state | handler proven; public purpose unknown |
| `5a f4 6b ...` | refresh/copy a 12-byte EC data block | dispatch proven; payload meaning unknown |

The machine-readable copy is emitted as `feature_ledger` by
`scripts/a14-ec-reverse.py`. It is deliberately evidence-labelled so an
unknown feature cannot silently become a made-up driver API.

## Regression boundary in this repository

| Driver generation | Initialization | Fn-row behavior |
|---|---|---|
| `5527892` / `6f29241` | retained `D0/8F/01` | submitted real `D0/4E` request; physical result not established per build |
| `eebd37a` / `a7762f2` | added ASUS identity before request | submitted real `D0/4E` request |
| `5c95732` and later Windows-common-init variants | replaced and removed `D0/8F/01` | submitted real request; EC gate remained unresolved |
| `0d5f05a` / package 0.5.14 | same incomplete firmware init | software Fn-row emulation added |
| package 0.5.15 | restored `D0/8F/01` before `D0/4E` | hardware-disproven and withdrawn |
| package 0.5.16 candidate | BIOS DSDT `ECCW(02,87,00)` then `ECCW(02,86,01)` before `D0/4E` | pending physical validation |

The software emulation is not firmware Fn-lock and must not be presented as
such. Neither may a successful HID transfer be logged as hardware state. The
BIOS 312's DSDT supplies the missing host-enable path: it serializes
`ECCW(02,87,00)` and `ECCW(02,86,01)` before using the Fn-switch feature. EC
disassembly independently shows that internal opcode `0x86` sets the ready
gate checked by the Fn-row service, while zero clears it. Package 0.5.16 is a
hardware-validation candidate that submits that exact mailbox sequence before
the exact 64-byte `D0/4E` report and preserves `KEY_FN_ESC` for OSD. It must not
be described as fixed until the physical F-row changes on the target machine.

The corrected addresses above matter: RISC-V `lui a5,0x800` produces
`0x00800000`, not `0x80000000`. The associated controller record is therefore
at `0x00800430`.

## Reproducibility

`scripts/a14-ec-reverse.py` rejects any EC image whose size, identity, or hash
does not match the recovered BIOS 312 payload. It validates the instruction
semantics at every offset used by the C++ model. The executable specification is
`firmware/ux3407ra-312/ec_behavior_model.cpp`.
