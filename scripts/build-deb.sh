#!/usr/bin/env bash
set -euo pipefail
NAME="asus-zenbook-a14-ec"
VERSION="0.2.0"
ARCH="all"
ROOT="$(pwd)/build/deb/${NAME}_${VERSION}_${ARCH}"
OUT="$(pwd)/dist"
rm -rf "$(pwd)/build/deb" "$OUT"
install -d "$ROOT/DEBIAN" "$ROOT/usr/src/${NAME}-${VERSION}" "$ROOT/usr/share/doc/${NAME}" "$ROOT/etc/modules-load.d" "$OUT"
cp -a Kbuild Makefile dkms.conf asus_zenbook_a14_ec.c hid_asus_ec.c scripts packaging "$ROOT/usr/src/${NAME}-${VERSION}/"
cp packaging/modules-load.conf "$ROOT/etc/modules-load.d/asus-zenbook-a14-ec.conf"
cat >"$ROOT/DEBIAN/control" <<EOF
Package: ${NAME}
Version: ${VERSION}
Section: kernel
Priority: optional
Architecture: ${ARCH}
Depends: dkms, make, python3, kmod
Maintainer: Ömer Faruk Nehir <omerfaruknehir@gmail.com>
Description: ASUS Zenbook A14 EC and HID DKMS drivers
 Fan monitoring/control, platform profiles, keyboard backlight and Fn hotkeys.
EOF
cat >"$ROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
NAME=asus-zenbook-a14-ec
VERSION=0.2.0
dkms remove -m "$NAME" -v "$VERSION" --all >/dev/null 2>&1 || true
dkms add -m "$NAME" -v "$VERSION"
dkms build -m "$NAME" -v "$VERSION"
dkms install -m "$NAME" -v "$VERSION"
depmod -a
modprobe hid_asus_ec 2>/dev/null || true
exit 0
EOF
cat >"$ROOT/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
dkms remove -m asus-zenbook-a14-ec -v 0.2.0 --all >/dev/null 2>&1 || true
modprobe -r asus_zenbook_a14_ec 2>/dev/null || true
modprobe -r hid_asus_ec 2>/dev/null || true
exit 0
EOF
chmod 0755 "$ROOT/DEBIAN/postinst" "$ROOT/DEBIAN/prerm" "$ROOT/usr/src/${NAME}-${VERSION}/scripts/"*.sh "$ROOT/usr/src/${NAME}-${VERSION}/scripts/"*.py
cp README.md "$ROOT/usr/share/doc/${NAME}/README.md"
dpkg-deb --root-owner-group --build "$ROOT" "$OUT/${NAME}_${VERSION}_${ARCH}.deb"
echo "Built: $OUT/${NAME}_${VERSION}_${ARCH}.deb"
