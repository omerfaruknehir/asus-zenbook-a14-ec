#!/usr/bin/env bash
set -euo pipefail
NAME="asus-zenbook-a14-ec"
VERSION="0.2.0"
ARCH="all"
ROOT="$(pwd)/build/deb/${NAME}_${VERSION}_${ARCH}"
OUT="$(pwd)/dist"
rm -rf "$(pwd)/build/deb" "$OUT"
install -d "$ROOT/DEBIAN" "$ROOT/usr/src/${NAME}-${VERSION}" "$ROOT/usr/share/doc/${NAME}" "$OUT"
cp -a Kbuild Makefile dkms.conf asus_zenbook_a14_ec.c hid_asus_ec.c scripts packaging "$ROOT/usr/src/${NAME}-${VERSION}/"
cat >"$ROOT/DEBIAN/control" <<EOF
Package: ${NAME}
Version: ${VERSION}
Section: kernel
Priority: optional
Architecture: ${ARCH}
Depends: dkms, make, python3, kmod
Recommends: linux-headers-generic
Maintainer: Ömer Faruk Nehir <omerfaruknehir@gmail.com>
Description: ASUS Zenbook A14 EC and HID DKMS drivers
 Fan monitoring/control, platform profiles, keyboard backlight and Fn hotkeys
 for supported ASUS Zenbook A14 systems.
EOF
cat >"$ROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
cd /usr/src/asus-zenbook-a14-ec-0.2.0
./scripts/install.sh
EOF
cat >"$ROOT/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
if [ -x /usr/src/asus-zenbook-a14-ec-0.2.0/scripts/uninstall.sh ]; then
  /usr/src/asus-zenbook-a14-ec-0.2.0/scripts/uninstall.sh
fi
EOF
chmod 0755 "$ROOT/DEBIAN/postinst" "$ROOT/DEBIAN/prerm" "$ROOT/usr/src/${NAME}-${VERSION}/scripts/"*.sh "$ROOT/usr/src/${NAME}-${VERSION}/scripts/"*.py
cp README.md "$ROOT/usr/share/doc/${NAME}/README.md"
dpkg-deb --root-owner-group --build "$ROOT" "$OUT/${NAME}_${VERSION}_${ARCH}.deb"
echo "Built: $OUT/${NAME}_${VERSION}_${ARCH}.deb"
