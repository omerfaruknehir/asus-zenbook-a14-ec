# A14 AOS firmware provenance

The files referenced here were extracted from the matching Windows installation
for one ASUS Zenbook A14 UX3407RA. They are proprietary and are intentionally
not redistributed in this repository.

`manifest.sha256` records the known-good basenames and hashes. Verify an
extracted directory with:

```bash
./scripts/verify-a14-aos-firmware.sh /path/to/extracted/files
```

The verification script does not install anything.

## Important separation

The existing ADSP firmware and `adsp_dtbs.elf` remain owned by the normal
Qualcomm remoteproc firmware path. QSH camera JSON/protobuf and camera module
blobs are separate inputs. Do not replace the working ADSP pair merely to add
camera configuration.

A final installed location will be selected by the kernel driver/binding. Until
that interface exists, do not copy these files into arbitrary `/lib/firmware`
paths and do not restart ADSP to test guessed locations.
