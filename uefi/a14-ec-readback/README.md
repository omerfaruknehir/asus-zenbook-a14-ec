# A14 EC full-flash readback

`A14ECReadback.efi` is a deliberately write-incapable AArch64 UEFI application
for the UX3407RA. It reads the complete 1 MiB EC SPI device three times and
writes three independent images plus a report to the FAT volume from which it
was launched.

The transport is reconstructed from the exact ASUS `ECFlashApp` embedded in
BIOS 312:

- Qualcomm I2C protocol GUID `b27ae8b1-3e10-4d07-ab5c-eb9a6dc6fa8f`;
- I2C instance 6, 400 kHz, slave `0x5b`;
- EC command port `0x17`, data port `0x18`;
- SPI read-ID `0x9f` and fast-read `0x0b` only.

There is no write-enable, write-disable, erase, page-program, status-register
write, EC-flash reset, or fallback initialization path. The application reads
EC register `0x1059` and refuses to continue unless the already-existing value
is zero. It does not alter that register. I2C write transactions are still
required to select read registers and transmit read commands; they are not SPI
flash writes.

Successful output:

- `A14EC001.BIN`, `A14EC002.BIN`, `A14EC003.BIN` — 1,048,576 bytes each;
- `A14EC.TXT` — JEDEC ID, bridge state, CRC32 values, and equality result.

Build with the pinned EDK II `edk2-stable202605` toolchain. The previous
standalone Clang/LLD link produced a PE image with a nonzero preferred base but
no base-relocation directory; the UX3407RA firmware rejected that image before
calling its entry point. The EDK II build emits the 4 KiB-aligned, relocatable
PE/COFF layout expected by this firmware.

```sh
git clone --depth 1 --branch edk2-stable202605 \
  https://github.com/tianocore/edk2.git /tmp/edk2
make -C /tmp/edk2/BaseTools -j"$(nproc)"
cd uefi/a14-ec-readback
EDK2_DIR=/tmp/edk2 ./build.sh
```

The build runs `audit.py`, which checks the source allowlist, AArch64 EFI
identity, 4 KiB section/file alignment, zero image base, and nonempty base
relocation directory.

Do not run the raw-backlight firmware patch or any updater after readback. First
return to Linux and validate all three images:

```sh
python3 scripts/a14-ec-readback-verify.py /path/to/usb \
  --output "$HOME/Downloads/UX3407RA-live-full-1MiB.bin"
```

Any read error, unexpected bridge state, wrong JEDEC ID, unequal pass, wrong
file size, or filesystem error is fatal. No backup is accepted from a failed
or unequal run.
