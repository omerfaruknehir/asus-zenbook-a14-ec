#!/usr/bin/env bash
set -euo pipefail

VERSION="0.2.0"
NAME="asus-zenbook-a14-ec"
SRC="/usr/src/${NAME}-${VERSION}"

if [[ ${EUID} -ne 0 ]]; then
  exec sudo --preserve-env=PATH "$0" "$@"
fi

for cmd in dkms make python3; do
  command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd" >&2; exit 1; }
done
[[ -e "/lib/modules/$(uname -r)/build/Makefile" ]] || {
  echo "Missing kernel headers for $(uname -r). Install linux-headers-$(uname -r)." >&2
  exit 1
}

rm -rf "$SRC"
install -d "$SRC"
cp -a Kbuild Makefile dkms.conf asus_zenbook_a14_ec.c hid_asus_ec.c scripts "$SRC/"
chmod +x "$SRC/scripts/apply-safety-fixes.py"

dkms remove -m "$NAME" -v "$VERSION" --all >/dev/null 2>&1 || true
dkms add -m "$NAME" -v "$VERSION"
dkms build -m "$NAME" -v "$VERSION"
dkms install -m "$NAME" -v "$VERSION"
depmod -a

install -Dm644 packaging/modules-load.conf /etc/modules-load.d/asus-zenbook-a14-ec.conf
install -Dm644 packaging/modprobe.conf /etc/modprobe.d/asus-zenbook-a14-ec.conf

modprobe hid_asus_ec || true
cat <<EOF
Installed ${NAME} ${VERSION}.

The HID/backlight module is enabled automatically.
The EC fan module is intentionally NOT autoloaded yet because warm-reboot safety
still requires hardware validation on UX3407RA. Load it manually after a cold boot:
  sudo modprobe asus_zenbook_a14_ec

Before rebooting during initial testing:
  sudo modprobe -r asus_zenbook_a14_ec
EOF
