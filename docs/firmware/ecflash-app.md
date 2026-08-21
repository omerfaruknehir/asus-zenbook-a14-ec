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

## Cross-revision boot-header evidence

The official UX3407RA BIOS 309 package supplies a second raw EC revision:

| Host package | Embedded EC UI | EC SHA-256 | Header at `0x40..0x4f` |
| --- | --- | --- | --- |
| UX3407RA BIOS 309 | `F0184104.UX3407RA.312` | `84867e47ca24e9205b56ddcfdd3b8a90c93e567972e1680f415f21fc2373cdc8` | `a5 a5 a5 a5 a5 a5 a7 94 85 12 df e2 aa b0 55 55` |
| UX3407RA BIOS 312 | `F0184104.UX3407RA.313` | `353eb0d125d76a14f15faa72f2153d57e25efd8d212f42b18a9f11c16e3fc39d` | `a5 a5 a5 a5 a5 a5 a7 94 85 12 f7 bb aa b0 55 55` |

Two additional official samples from the closely related UX3407QA provide a
same-model revision comparison:

| Host package | Embedded EC UI | EC SHA-256 | Bytes `0x4a..0x4b` |
| --- | --- | --- | --- |
| UX3407QA BIOS 313 | `F0174104.UX3407QA.313` | `0284032e712f971cd1b0ac69fc53a199eec8985cc289d47eb50540246249ddd0` | `a3 ca` |
| UX3407QA BIOS 315 | `F0174104.UX3407QA.314` | `99a98da4527880285b6189da9456320be9d5a3333488b4f4eeef071988abc5ed` | `91 65` |

The fixed magic and identity remain stable, while bytes `0x4a..0x4b` vary
between revisions of the same model as well as between models. This proves
that the two bytes are neither fixed header magic nor merely a model tag. It does **not** yet prove that they are a checksum. Tests against common
CRC-16 parameter sets, whole-image CRC residues, byte/word sums, XOR,
Fletcher-16, and CRC-32 halves did not reproduce a shared stock-image rule.
They may be a proprietary integrity field, a build identifier, or input to an
EC boot-ROM policy.

The raw-backlight patch currently leaves these bytes unchanged. Its generated
image is therefore an analysis artifact and is explicitly marked
`flash_ready=NO` until the field is derived or shown to be irrelevant by
direct boot-path evidence.

## Windows package staging

The official `Install.bat` only launches the signed `BIOSInstall.ps1`.
That script discovers the `UEFI\\RES_...` firmware device, removes the
currently installed firmware INF when necessary, and stages the package's INF
with `pnputil /add-driver ... /install`. It contains no EC-image checksum
generator, pre-write backup, direct flash transport, or recovery routine.

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

- derive the image-dependent EC header field at `0x4a..0x4b`, or prove from
  boot-path evidence that modified code is accepted without regenerating it;
- obtain a complete live readback before writing;
- determine whether the unused flash address space contains recovery data;
- prove a recovery path that works when the main EC image does not boot;
- preserve outer firmware authentication or use a separately audited updater;
- ensure uninterrupted external power and exact board/firmware identity.

Until those conditions are met, no repository tool should erase or program EC
flash.
