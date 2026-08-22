# UX3407RA BIOS 312 EC reconstruction

This directory holds a clean-room behavioral reconstruction of selected code
paths in the embedded controller shipped inside the official UX3407RA BIOS 312
capsule. It intentionally contains no ASUS firmware binary.

Reference image:

- EC identity: `ITE51300-EC-V0.00`
- EC payload size: 262,144 bytes
- EC SHA-256: `353eb0d125d76a14f15faa72f2153d57e25efd8d212f42b18a9f11c16e3fc39d`
- Architecture: RISC-V RV32IMC

Run the static validator:

```sh
python3 scripts/a14-ec-reverse.py ~/Downloads/UX3407RA.313.ec.bin \
  --json /tmp/ux3407ra-312-ec-map.json
```

Build and run the C++ model:

```sh
g++ -std=c++20 -Wall -Wextra -Werror -O2 \
  firmware/ux3407ra-312/ec_behavior_model.cpp \
  -o /tmp/a14-ec-model
/tmp/a14-ec-model
```

The model is not replacement firmware and must never be passed to an EC flash
tool. It is an executable specification for behavior already verified in the
original image. Unknown behavior remains in the feature ledger rather than
being guessed in code.
