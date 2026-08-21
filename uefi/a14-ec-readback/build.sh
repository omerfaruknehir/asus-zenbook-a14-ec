#!/bin/sh
set -eu

CLANG=${CLANG:-clang}
LLD_LINK=${LLD_LINK:-lld-link}
OUT=${OUT:-dist/A14ECReadback.efi}
OBJ=${OBJ:-dist/a14_ec_readback.obj}

mkdir -p "$(dirname "$OUT")"
"$CLANG" --target=aarch64-pc-windows-msvc \
  -std=c11 -Os -ffreestanding -fno-builtin -fno-stack-protector \
  -fno-exceptions -fno-unwind-tables -fno-asynchronous-unwind-tables \
  -Wall -Wextra -Werror -c a14_ec_readback.c -o "$OBJ"
"$LLD_LINK" /machine:arm64 /subsystem:efi_application /entry:efi_main \
  /nodefaultlib /opt:ref /opt:icf /timestamp:0 /out:"$OUT" "$OBJ"

python3 audit.py "$OUT"
sha256sum "$OUT"
