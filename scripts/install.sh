#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
bash "$ROOT/scripts/build-deb.sh"
DEB=$(find "$ROOT/dist" -maxdepth 1 -name 'asus-zenbook-a14-ec-dkms_*_all.deb' \
    -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)
[[ -n $DEB ]] || { echo 'DEB build failed' >&2; exit 1; }
sudo apt install "$DEB"
