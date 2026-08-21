# UX3407RA ECFlashApp static analysis

This note records the fail-closed static analysis of the `ECFlashApp` module
embedded in the authenticated `UX3407RA.312` FMP image. It documents behavior;
it is not a flashing procedure.

## Exact inputs

| Artifact | Size | SHA-256 |
| --- | ---: | --- |
| FMP firmware image | 21,334,608 bytes | `87ebb5520eab8ec2d1538fb3d068512dc20d4194ff5682cbae9c0e7e95d304dd` |
| `ECFlashApp.efi` | 307,200 bytes | `1d245aa84b9e3f209d46d7b317ca3719dab47ad8549f7b8d0d86ce62579f97ed` |
| EC raw image | 262,144 bytes | `353eb0d125d76a14f15faa72f2153d57e25efd8d212f42b18a9f11c16e3fc39d` |

`ECFlashApp.efi` is a PE32+ AArch64 UEFI boot-service driver. Its PE Security
Directory is empty. That fact does not bypass authentication of the outer FMP
capsule or prove that an altered container will be accepted.

## Raw-image validation

The application does not cryptographically authenticate the 256 KiB raw EC
payload:

1. It copies the portion after image offset `0x10000`, replaces NUL bytes with
   underscores, locates `$ECDH$`, and extracts the display version beginning 16
   bytes after that marker.
2. Failure to find `$ECDH$` is not converted into a validation failure by that
   routine, and its return value is ignored by the caller.
3. The enforced compatibility check compares the ASCII string at image offset
   `0x50` with `ITE51300-EC-V0.00`.

The `$ECDH$` block therefore supplies version metadata, not a signature or
payload checksum. This says nothing about a possible validity check performed
later by the EC's own boot ROM. The stock image also has a 16-byte A5/55-style
header at offset `0x40`; its exact semantics are not yet proven.

## Flash transport and geometry

The application uses an EC-mediated I2C transport at address `0x5b` to issue
standard SPI-flash commands. It accepts these three-byte JEDEC IDs:

- `EF 60 14`
- `C8 60 14`

The update sequence uses:

| Operation | SPI command | Granularity |
| --- | ---: | ---: |
| Write enable | `0x06` | before erase/program |
| Write disable | `0x04` | after erase/program |
| Sector erase | `0x20` | 4 KiB |
| Page program | `0x02` | four 128-byte transfers per 1 KiB block |
| Fast read | `0x0b` | 64-byte transfers during verification |
| Read JEDEC ID | `0x9f` | 3 bytes |

The image-size global is initialized to `0x40000`. The start-offset global is
zero, and the loaded section size is also `0x40000`. Consequently the updater:

- erases sectors from `0x00000` through `0x3f000`;
- programs non-`0xff` blocks throughout `0x00000..0x3ffff`;
- reads back the whole `0x40000` range; and
- compares it byte-for-byte with the source image.

The accepted JEDEC capacity byte describes a device larger than the updated
256 KiB range. The contents and purpose of the remaining address space are not
established by this application.

## Failure handling

Erase, program, or verify failure restarts the same update flow. A counter caps
the attempt count at three. The application reports the first mismatching
offset and source/readback bytes during verification.

There is no code path that reads the old EC image into a persistent backup
before erasing it, no alternate-image write, and no rollback after an
unsuccessful update. The only full-flash read occurs after programming for
verification.

After success the application resets/reinitializes the EC. After failure it
runs cleanup/reset writes, but those writes cannot restore sectors already
erased or partially programmed.

## Safety conclusion

The 10-byte raw-backlight patch appears to pass `ECFlashApp`'s own raw-image
identity checks, and the application would verify the altered bytes exactly if
it were asked to program them. That is not sufficient to flash safely.

Deployment remains blocked on all of the following:

- prove the EC boot-header/checksum policy with another official EC revision;
- obtain a complete live readback before writing;
- determine whether the unused flash address space contains recovery data;
- prove a recovery path that works when the main EC image does not boot;
- preserve outer firmware authentication or use a separately audited updater;
- ensure uninterrupted external power and exact board/firmware identity.

Until those conditions are met, no repository tool should erase or program EC
flash.
