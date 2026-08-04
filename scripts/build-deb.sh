#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VERSION=${1:-1.0.0}
PKG=asus-zenbook-a14-ec-dkms
SRC_NAME=asus-zenbook-a14-ec
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

OUT="$ROOT/dist"
PKGROOT="$WORK/${PKG}_${VERSION}_all"
SRCROOT="$PKGROOT/usr/src/${SRC_NAME}-${VERSION}"
mkdir -p "$SRCROOT/scripts" "$PKGROOT/DEBIAN" "$PKGROOT/usr/sbin" \
    "$PKGROOT/usr/lib/systemd/system" "$PKGROOT/etc/modprobe.d" "$OUT"

install -m 0644 "$ROOT/asus_zenbook_a14_ec.c" "$ROOT/hid_asus_ec.c" \
    "$ROOT/Kbuild" "$ROOT/Makefile" "$ROOT/dkms.conf" "$SRCROOT/"
install -m 0755 "$ROOT/scripts/prepare-source.py" "$SRCROOT/scripts/prepare-source.py"
install -m 0755 "$ROOT/scripts/finalize-source.py" "$SRCROOT/scripts/finalize-source.py"
sed -i "s/^PACKAGE_VERSION=.*/PACKAGE_VERSION=\"$VERSION\"/" "$SRCROOT/dkms.conf"
install -m 0755 "$ROOT/tools/a14-ecctl" "$PKGROOT/usr/sbin/a14-ecctl"
install -m 0644 "$ROOT/systemd/asus-zenbook-a14-ec.service" \
    "$PKGROOT/usr/lib/systemd/system/asus-zenbook-a14-ec.service"
install -m 0644 "$ROOT/modprobe.d/asus-zenbook-a14-ec.conf" \
    "$PKGROOT/etc/modprobe.d/asus-zenbook-a14-ec.conf"
[[ -f "$ROOT/README.md" ]] && install -m 0644 "$ROOT/README.md" "$SRCROOT/README.md"
[[ -f "$ROOT/LICENSE" ]] && install -m 0644 "$ROOT/LICENSE" "$SRCROOT/LICENSE"

cat > "$PKGROOT/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Section: kernel
Priority: optional
Architecture: all
Maintainer: Ömer Faruk Nehir <omerfaruknehir@gmail.com>
Depends: dkms, make, gcc, python3, kmod, systemd
Description: ASUS Zenbook A14 EC and HID drivers (DKMS)
 Fan monitoring/control, platform profiles, keyboard backlight, and Fn hotkeys
 for supported ASUS Zenbook A14 Snapdragon systems. The direct EC module is
 loaded late by systemd and explicitly quiesced during shutdown.
EOF

cat > "$PKGROOT/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
NAME=$SRC_NAME
VERSION=$VERSION
if dkms status -m "\$NAME" -v "\$VERSION" 2>/dev/null | grep -q .; then
    dkms remove -m "\$NAME" -v "\$VERSION" --all || true
fi
dkms add -m "\$NAME" -v "\$VERSION"
dkms build -m "\$NAME" -v "\$VERSION"
dkms install -m "\$NAME" -v "\$VERSION"
depmod -a
systemctl daemon-reload || true
systemctl enable asus-zenbook-a14-ec.service || true
modprobe hid_asus_ec || true
systemctl restart asus-zenbook-a14-ec.service || true
printf '%s\n' 'Installed. Run: sudo a14-ecctl status'
EOF
chmod 0755 "$PKGROOT/DEBIAN/postinst"

cat > "$PKGROOT/DEBIAN/prerm" <<EOF
#!/bin/sh
set -e
if [ "\${1:-}" = remove ] || [ "\${1:-}" = deconfigure ]; then
    systemctl disable --now asus-zenbook-a14-ec.service 2>/dev/null || true
    modprobe -r asus_zenbook_a14_ec 2>/dev/null || true
    modprobe -r hid_asus_ec 2>/dev/null || true
    dkms remove -m $SRC_NAME -v $VERSION --all 2>/dev/null || true
fi
EOF
chmod 0755 "$PKGROOT/DEBIAN/prerm"

cat > "$PKGROOT/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
systemctl daemon-reload 2>/dev/null || true
depmod -a 2>/dev/null || true
EOF
chmod 0755 "$PKGROOT/DEBIAN/postrm"

dpkg-deb --build --root-owner-group "$PKGROOT" "$OUT/${PKG}_${VERSION}_all.deb"
printf '%s\n' "$OUT/${PKG}_${VERSION}_all.deb"
