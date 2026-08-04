#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=$(cat "$repo/VERSION")
package=asus-zenbook-a14-ec-dkms
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
root="$work/root"
src="$root/usr/src/asus-zenbook-a14-ec-$version"
mkdir -p "$root/DEBIAN" "$src" "$root/usr/sbin" "$root/usr/libexec" \
  "$root/usr/lib/systemd/system" "$root/etc/modprobe.d" \
  "$root/usr/share/doc/$package" "$repo/dist"

install -m 0644 "$repo/asus_zenbook_a14_ec.c" "$repo/hid_asus_ec.c" \
  "$repo/Kbuild" "$repo/Makefile" "$src/"
sed "s/PACKAGE_VERSION=\"[^\"]*\"/PACKAGE_VERSION=\"$version\"/" \
  "$repo/dkms.conf" >"$src/dkms.conf"
install -m 0755 "$repo/scripts/asus-a14-control" "$root/usr/sbin/asus-a14-control"
install -m 0755 "$repo/scripts/asus-zenbook-a14-ec-load" "$root/usr/libexec/asus-zenbook-a14-ec-load"
install -m 0755 "$repo/scripts/asus-zenbook-a14-ec-unload" "$root/usr/libexec/asus-zenbook-a14-ec-unload"
install -m 0755 "$repo/scripts/asus-zenbook-a14-ppd-bridge.py" "$root/usr/libexec/asus-zenbook-a14-ppd-bridge"
install -m 0644 "$repo/systemd/asus-zenbook-a14-ec.service" "$root/usr/lib/systemd/system/"
install -m 0644 "$repo/systemd/asus-zenbook-a14-ppd-bridge.service" "$root/usr/lib/systemd/system/"
install -m 0644 "$repo/modprobe.d/asus-zenbook-a14-ec.conf" "$root/etc/modprobe.d/"
install -m 0644 "$repo/README.md" "$root/usr/share/doc/$package/README.md"
gzip -9n -c "$repo/CHANGELOG.md" >"$root/usr/share/doc/$package/changelog.gz"
cat >"$root/usr/share/doc/$package/copyright" <<'COPYRIGHT'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: asus-zenbook-a14-ec
Source: https://github.com/omerfaruknehir/asus-zenbook-a14-ec

Files: asus_zenbook_a14_ec.c
Copyright: 2026 Sombre-Osmoze <sombre@osmoze.xyz>
           2026 Ömer Faruk Nehir <omerfaruknehir@gmail.com>
License: GPL-2.0-only

Files: hid_asus_ec.c
Copyright: 2025 Alexandru Marc Serdeliuc <serdeliuk@yahoo.com>
           2026 Ömer Faruk Nehir <omerfaruknehir@gmail.com>
License: GPL-2.0-or-later

Files: scripts/asus-zenbook-a14-ppd-bridge.py
Copyright: 2026 Sombre-Osmoze <sombre@osmoze.xyz>
           2026 Ömer Faruk Nehir <omerfaruknehir@gmail.com>
License: GPL-2.0-or-later
COPYRIGHT

installed_size=$(du -sk "$root" | awk '{print $1}')
cat >"$root/DEBIAN/control" <<CONTROL
Package: $package
Version: $version
Section: kernel
Priority: optional
Architecture: all
Maintainer: Ömer Faruk Nehir <omerfaruknehir@gmail.com>
Depends: dkms, kmod, systemd, build-essential, python3, python3-dbus, python3-gi
Recommends: linux-headers-generic | linux-headers-arm64, power-profiles-daemon
Installed-Size: $installed_size
Homepage: https://github.com/omerfaruknehir/asus-zenbook-a14-ec
Description: ASUS Zenbook A14 EC and keyboard drivers (DKMS)
 Dual-fan monitoring/control, safe power profiles, keyboard backlight and Fn
 hotkeys for ASUS Zenbook A14 UX3407RA/UX3407QA Snapdragon systems. Includes
 an optional systemd D-Bus fallback for kernels without platform_profile.
CONTROL

cat >"$root/DEBIAN/postinst" <<POSTINST
#!/bin/sh
set -e
version='$version'
module='asus-zenbook-a14-ec'
kernel="\$(uname -r)"
if [ ! -e "/lib/modules/\$kernel/build/Makefile" ]; then
  echo "Missing headers for \$kernel." >&2
  echo "Install them, then run: sudo dpkg --configure $package" >&2
  exit 1
fi
dkms remove -m "\$module" -v "\$version" --all >/dev/null 2>&1 || true
dkms add -m "\$module" -v "\$version"
dkms build -m "\$module" -v "\$version" -k "\$kernel"
dkms install -m "\$module" -v "\$version" -k "\$kernel" --force
depmod -a "\$kernel"
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable asus-zenbook-a14-ec.service >/dev/null 2>&1 || true
if [ "\${1:-}" = configure ]; then
  systemctl restart asus-zenbook-a14-ec.service >/dev/null 2>&1 || \
    echo "Driver installed but could not be started; inspect: journalctl -u asus-zenbook-a14-ec" >&2
fi
exit 0
POSTINST

cat >"$root/DEBIAN/prerm" <<PRERM
#!/bin/sh
set -e
version='$version'
if [ "\${1:-}" = remove ] || [ "\${1:-}" = deconfigure ]; then
  bridge_enabled=false
  if systemctl is-enabled --quiet asus-zenbook-a14-ppd-bridge.service 2>/dev/null || \
     systemctl is-active --quiet asus-zenbook-a14-ppd-bridge.service 2>/dev/null; then
    bridge_enabled=true
  fi
  systemctl disable --now asus-zenbook-a14-ppd-bridge.service >/dev/null 2>&1 || true
  systemctl disable --now asus-zenbook-a14-ec.service >/dev/null 2>&1 || true
  modprobe -r hid_asus_ec >/dev/null 2>&1 || true
  dkms remove -m asus-zenbook-a14-ec -v "\$version" --all >/dev/null 2>&1 || true
  if [ "\$bridge_enabled" = true ]; then
    systemctl unmask power-profiles-daemon.service >/dev/null 2>&1 || true
    systemctl enable --now power-profiles-daemon.service >/dev/null 2>&1 || true
  fi
fi
exit 0
PRERM

cat >"$root/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
systemctl daemon-reload >/dev/null 2>&1 || true
depmod -a >/dev/null 2>&1 || true
exit 0
POSTRM

chmod 0755 "$root/DEBIAN/postinst" "$root/DEBIAN/prerm" "$root/DEBIAN/postrm"
out="$repo/dist/${package}_${version}_all.deb"
dpkg-deb --root-owner-group --build "$root" "$out"
echo "$out"
