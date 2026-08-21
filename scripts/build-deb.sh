#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo"

# stdout is the public machine-readable API of this helper: exactly one line,
# the absolute path of the generated .deb. Human/build chatter goes to stderr
# so callers may safely use: deb=$(./scripts/build-deb.sh)
make prepare >&2
version=$(cat "$repo/VERSION")
package=asus-zenbook-a14-ec-dkms
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
root="$work/root"
src="$root/usr/src/asus-zenbook-a14-ec-$version"
ext_uuid=asus-a14-modes@omerfaruknehir
ext_dir="$root/usr/share/gnome-shell/extensions/$ext_uuid"
mkdir -p "$root/DEBIAN" "$src/scripts" "$root/usr/sbin" "$root/usr/libexec" \
  "$root/usr/lib/systemd/system" "$root/usr/share/dbus-1/system.d" \
  "$ext_dir" "$root/etc/xdg/autostart" "$root/etc/modprobe.d" \
  "$root/usr/share/doc/$package" "$repo/dist"

install -m 0644 "$repo/asus_zenbook_a14_ec.c" "$repo/hid_asus_ec.c" \
  "$repo/Kbuild" "$repo/Makefile" "$src/"

# Keep the installed DKMS source reproducible from either a clean checkout or
# the already-composed source shipped in the package.
for script in \
  a14-kbuild-compat.sh \
  prepare-a14-ec.py \
  apply-a14-ec-hardening.py \
  apply-a14-native-fan-profile.py \
  apply-a14-native-hardening-compat.py \
  apply-a14-native-max-power.py \
  apply-a14-native-fan-telemetry.py \
  apply-a14-native-mode-names-hotkey.py \
  apply-a14-whisper.py \
  apply-a14-hid-fnlock.py \
  apply-a14-hid-profile-hotkey.py \
  apply-a14-kbd-backlight-255.py
do
  install -m 0755 "$repo/scripts/$script" "$src/scripts/$script"
done

sed "s/PACKAGE_VERSION=\"[^\"]*\"/PACKAGE_VERSION=\"$version\"/" \
  "$repo/dkms.conf" >"$src/dkms.conf"

install -m 0755 "$repo/scripts/asus-a14-control" "$root/usr/sbin/asus-a14-control"
install -m 0755 "$repo/scripts/asus-zenbook-a14-ec-load" "$root/usr/libexec/asus-zenbook-a14-ec-load"
install -m 0755 "$repo/scripts/asus-zenbook-a14-ec-unload" "$root/usr/libexec/asus-zenbook-a14-ec-unload"
install -m 0755 "$repo/scripts/asus-zenbook-a14-ppd-bridge.py" "$root/usr/libexec/asus-zenbook-a14-ppd-bridge"
install -m 0755 "$repo/scripts/asus-zenbook-a14-profile-integration" "$root/usr/libexec/asus-zenbook-a14-profile-integration"
install -m 0755 "$repo/scripts/asus-zenbook-a14-profile-service.py" "$root/usr/libexec/asus-zenbook-a14-profile-service"
install -m 0755 "$repo/scripts/asus-zenbook-a14-enable-gnome-extension" "$root/usr/libexec/asus-zenbook-a14-enable-gnome-extension"

install -m 0644 "$repo/systemd/asus-zenbook-a14-ec.service" "$root/usr/lib/systemd/system/"
install -m 0644 "$repo/systemd/asus-zenbook-a14-ppd-bridge.service" "$root/usr/lib/systemd/system/"
install -m 0644 "$repo/systemd/asus-zenbook-a14-profile.service" "$root/usr/lib/systemd/system/"
install -m 0644 "$repo/dbus-1/system.d/io.github.omerfaruknehir.AsusA14.conf" "$root/usr/share/dbus-1/system.d/"
install -m 0644 "$repo/gnome-shell/$ext_uuid/metadata.json" "$ext_dir/metadata.json"
install -m 0644 "$repo/gnome-shell/$ext_uuid/extension.js" "$ext_dir/extension.js"
install -d -m 0755 "$ext_dir/icons" "$root/usr/share/icons/hicolor/scalable/status"
for profile in whisper quiet normal turbo full-speed; do
  icon="a14-power-profile-$profile-symbolic.svg"
  if ! cmp -s "$repo/userspace/gnome/icons/$icon" "$repo/gnome-shell/$ext_uuid/icons/$icon"; then
    echo "GNOME icon copies differ: $icon" >&2
    exit 1
  fi
  install -m 0644 "$repo/gnome-shell/$ext_uuid/icons/$icon" "$ext_dir/icons/$icon"
  install -m 0644 "$repo/userspace/gnome/icons/$icon" \
    "$root/usr/share/icons/hicolor/scalable/status/$icon"
done
install -m 0644 "$repo/xdg/autostart/asus-zenbook-a14-gnome-extension.desktop" "$root/etc/xdg/autostart/"
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

Files: scripts/asus-zenbook-a14-ppd-bridge.py scripts/asus-zenbook-a14-profile-service.py gnome-shell/*/extension.js
Copyright: 2026 Sombre-Osmoze <sombre@osmoze.xyz>
           2026 Ömer Faruk Nehir <omerfaruknehir@gmail.com>
License: GPL-2.0-or-later

Files: userspace/gnome/icons/*.svg gnome-shell/asus-a14-modes@omerfaruknehir/icons/*.svg
Copyright: Yaru contributors
License: MPL-2.0
Comment: Meter artwork is derived from ubuntu/yaru.dart assets/icons/meter.
 The gauge geometry is unchanged; the gray fill is adapted to currentColor for
 symbolic GNOME theming.

License: MPL-2.0
 On Debian systems, the complete text of the Mozilla Public License 2.0 can be
 found in /usr/share/common-licenses/MPL-2.0.
COPYRIGHT

installed_size=$(du -sk "$root" | awk '{print $1}')
cat >"$root/DEBIAN/control" <<CONTROL
Package: $package
Version: $version
Section: kernel
Priority: optional
Architecture: all
Maintainer: Ömer Faruk Nehir <omerfaruknehir@gmail.com>
Depends: dkms, kmod, systemd, build-essential, binutils, python3, python3-dbus, python3-gi
Recommends: power-profiles-daemon, gnome-shell, initramfs-tools
Installed-Size: $installed_size
Homepage: https://github.com/omerfaruknehir/asus-zenbook-a14-ec
Description: ASUS Zenbook A14 EC, keyboard and desktop integration (DKMS)
 Dual-fan monitoring/control and ASUS native Quiet, Normal, Turbo and Full Speed
 firmware modes for UX3407RA/UX3407QA Snapdragon systems. Adds an acoustic-first
 Whisper mode that progressively limits CPU/GPU heat, attempts zero-RPM fans,
 and silently falls back to ASUS Quiet cooling when required. Fn+F cycles the
 five ordered modes and GNOME Quick Settings shows mode changes using OSD.
CONTROL

cat >"$root/DEBIAN/postinst" <<POSTINST
#!/bin/sh
set -e
version='$version'
module='asus-zenbook-a14-ec'
kernel="\$(uname -r)"
ext_uuid='asus-a14-modes@omerfaruknehir'

if [ ! -e "/lib/modules/\$kernel/build/Makefile" ]; then
  echo "Missing headers for \$kernel." >&2
  echo "Install the exact headers for the running kernel, then run: sudo dpkg --configure $package" >&2
  exit 1
fi

for old_dir in /var/lib/dkms/\$module/*; do
  [ -d "\$old_dir" ] || continue
  old_version=\${old_dir##*/}
  [ "\$old_version" = "\$version" ] && continue
  dkms remove -m "\$module" -v "\$old_version" --all >/dev/null 2>&1 || true
  if [ ! -e "/usr/src/\$module-\$old_version" ]; then
    rm -rf "\$old_dir"
  fi
done

dkms remove -m "\$module" -v "\$version" --all >/dev/null 2>&1 || true
dkms add -m "\$module" -v "\$version"
dkms build -m "\$module" -v "\$version" -k "\$kernel"
dkms install -m "\$module" -v "\$version" -k "\$kernel" --force
depmod -a "\$kernel"

if command -v update-initramfs >/dev/null 2>&1; then
  update-initramfs -u -k "\$kernel"
elif command -v dracut >/dev/null 2>&1; then
  dracut --force "/boot/initramfs-\$kernel.img" "\$kernel"
fi

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi

systemctl daemon-reload >/dev/null 2>&1 || true
if command -v busctl >/dev/null 2>&1; then
  busctl call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ReloadConfig >/dev/null 2>&1 || true
fi

systemctl enable asus-zenbook-a14-ec.service >/dev/null 2>&1 || true
systemctl enable asus-zenbook-a14-profile.service >/dev/null 2>&1 || true
if [ "\${1:-}" = configure ]; then
  systemctl restart asus-zenbook-a14-ec.service >/dev/null 2>&1 || \
    echo "Driver installed but could not be started; inspect: journalctl -u asus-zenbook-a14-ec" >&2
  systemctl restart asus-zenbook-a14-profile.service >/dev/null 2>&1 || \
    echo "A14 profile D-Bus service could not start; inspect: journalctl -u asus-zenbook-a14-profile" >&2
fi

/usr/libexec/asus-zenbook-a14-profile-integration || true

for bus in /run/user/[0-9]*/bus; do
  [ -S "\$bus" ] || continue
  uid=\$(printf '%s' "\$bus" | cut -d/ -f4)
  case "\$uid" in ''|*[!0-9]*|0) continue ;; esac
  user=\$(getent passwd "\$uid" 2>/dev/null | cut -d: -f1)
  [ -n "\$user" ] || continue
  runuser -u "\$user" -- env \
    DBUS_SESSION_BUS_ADDRESS="unix:path=\$bus" \
    XDG_RUNTIME_DIR="/run/user/\$uid" \
    /usr/libexec/asus-zenbook-a14-enable-gnome-extension >/dev/null 2>&1 || true
done

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
  systemctl disable --now asus-zenbook-a14-profile.service >/dev/null 2>&1 || true
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
kernel="$(uname -r)"
systemctl daemon-reload >/dev/null 2>&1 || true
if command -v busctl >/dev/null 2>&1; then
  busctl call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ReloadConfig >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi
depmod -a "$kernel" >/dev/null 2>&1 || true
if command -v update-initramfs >/dev/null 2>&1; then
  update-initramfs -u -k "$kernel" >/dev/null 2>&1 || true
elif command -v dracut >/dev/null 2>&1; then
  dracut --force "/boot/initramfs-$kernel.img" "$kernel" >/dev/null 2>&1 || true
fi
exit 0
POSTRM

chmod 0755 "$root/DEBIAN/postinst" "$root/DEBIAN/prerm" "$root/DEBIAN/postrm"
out="$repo/dist/${package}_${version}_all.deb"
dpkg-deb --root-owner-group --build "$root" "$out" >&2
printf '%s\n' "$out"
