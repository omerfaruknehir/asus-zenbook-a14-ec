#!/usr/bin/env bash
set -euo pipefail
VERSION="0.2.0"
NAME="asus-zenbook-a14-ec"
if [[ ${EUID} -ne 0 ]]; then exec sudo "$0" "$@"; fi
modprobe -r asus_zenbook_a14_ec 2>/dev/null || true
modprobe -r hid_asus_ec 2>/dev/null || true
dkms remove -m "$NAME" -v "$VERSION" --all 2>/dev/null || true
rm -rf "/usr/src/${NAME}-${VERSION}"
rm -f /etc/modules-load.d/asus-zenbook-a14-ec.conf /etc/modprobe.d/asus-zenbook-a14-ec.conf
depmod -a
echo "Removed ${NAME} ${VERSION}."
