#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo"
sh -n install.sh scripts/build-deb.sh scripts/asus-a14-control \
  scripts/asus-zenbook-a14-ec-load scripts/asus-zenbook-a14-ec-unload
version=$(cat VERSION)
grep -q "PACKAGE_VERSION=\"$version\"" dkms.conf
if [ -e "/lib/modules/$(uname -r)/build/Makefile" ]; then
  make clean >/dev/null 2>&1 || true
  make -j2
fi
./scripts/build-deb.sh >/dev/null
test -s "dist/asus-zenbook-a14-ec-dkms_${version}_all.deb"
dpkg-deb --info "dist/asus-zenbook-a14-ec-dkms_${version}_all.deb" >/dev/null
dpkg-deb --contents "dist/asus-zenbook-a14-ec-dkms_${version}_all.deb" | \
  grep -q "usr/src/asus-zenbook-a14-ec-${version}/asus_zenbook_a14_ec.c"
echo "Validation passed"
