# UX3407RA EC keyboard-backlight target

## Confirmed firmware behavior

The `F0184104.UX3407RA.313` EC image is 256 KiB of RV32IMC code with SHA-256
`353eb0d125d76a14f15faa72f2153d57e25efd8d212f42b18a9f11c16e3fc39d`.

The QTEC HID handler at `0xed70` recognizes `5A BA C5 C4 VALUE` and jumps to
`0xffdc`. That routine maps the public values to PWM targets:

| HID value | Target byte |
| ---: | ---: |
| `0` | `0x00` |
| `1` | `0x43` |
| `2` | `0x87` |
| `3` | `0xcc` |
| any other value | `0x00` |

The target is stored at EC RAM `0x0080304a`. The periodic routine at `0xff62`
reads PWM channel 4 and moves it toward that target in increments of three.
This explains both observed facts: values above three turn the keyboard off,
and a one-shot raw PWM write does not create a stable brightness.

The ordinary host mailbox exposes channel 4 at major `0x01`, read minor
`0x07`, and write minor `0x87`. The write calls the generic PWM setter at
`0x15698`, but it changes the current duty cycle rather than the target at
`0x0080304a`; the ramp loop therefore overwrites it. No host-visible handler in
this firmware writes an arbitrary value to the target.

## Minimal real fix

The function at `0xffdc` can be replaced with the following 10-byte RV32IMC
implementation:

```text
lui a5, 0x803
sb  a0, 0x4a(a5)
ret
```

After that change, the existing HID command accepts a genuine `0..255` target
and the existing firmware ramp remains responsible for smooth hardware PWM.
`scripts/a14-ec-backlight-raw-patch.py` creates this variant only when both the
complete input hash and original instruction bytes match.

## Safety boundary

The patch generator never flashes hardware and never rewrites a signed BIOS or
FMP capsule. A deployable implementation remains blocked until the EC update
transport, signature policy, backup, recovery, power-loss behavior, and exact
board/firmware match have all been validated. Do not substitute a continuously
rewritten Linux PWM value: it races the EC ramp loop and is not a proper ABI.
