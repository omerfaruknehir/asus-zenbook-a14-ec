#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
model=$(tr -d '\000' </proc/device-tree/model 2>/dev/null || true)
case "$model" in
  *"ASUS Zenbook A14"*"UX3407RA"*|*"ASUS Zenbook A14"*"UX3407QA"*) ;;
  *) echo "Unsupported device: ${model:-no device-tree model}" >&2; exit 1;;
esac

# Older development builds composed the DSDT DEVS(0x00100023) EC experiment
# directly into the working-tree EC source. The real-machine A/B proved that
# stage does not switch the row, so remove that known generated probe before
# both the preflight compile and package composition. This preserves all other
# generated EC/profile work in the user's tree.
if grep -q 'A14_FNLOCK_EC_STAGE_DSDT' "$repo/asus_zenbook_a14_ec.c" 2>/dev/null; then
  python3 "$repo/scripts/remove-a14-fnlock-ec-stage.py"
fi

# These are exact assets supplied for the five A14 modes. Guard the semantic
# mapping before packaging so Turbo can never silently become meter-max again.
sh "$repo/scripts/a14-verify-meter-icons.sh"

kernel=$(uname -r)
headers="/lib/modules/$kernel/build/Makefile"
need_bootstrap=false
for command in dkms dpkg-deb make gcc python3 readelf; do
  command -v "$command" >/dev/null 2>&1 || need_bootstrap=true
done
[ -e "$headers" ] || need_bootstrap=true

# Avoid invoking apt unnecessarily: if an older A14 package is half-configured,
# apt may try to configure it before we have had a chance to build the repaired
# replacement. Fresh machines still get the required build dependencies here.
if [ "$need_bootstrap" = true ]; then
  echo "Installing build requirements and running-kernel headers..."
  sudo apt-get update
  sudo apt-get install -y dkms build-essential binutils dpkg-dev "linux-headers-$kernel"
fi

if [ ! -e "$headers" ]; then
  echo "Missing headers for running kernel $kernel: $headers" >&2
  exit 1
fi

# Compile the exact generated sources against the running kernel *before*
# unpacking/upgrading the DEB. The compatibility wrapper also detects Ubuntu
# mainline ARM64 header packages containing a foreign-architecture
# gendwarfksyms host tool and substitutes an exact-source native helper from an
# installed ARM64 header tree when available.
echo "Preflight building A14 modules against $kernel..."
make clean >/dev/null 2>&1 || true
if ! A14_MODULE_DIR="$repo" \
     A14_BUILD_JOBS="${A14_BUILD_JOBS:-$(nproc)}" \
     KDIR="/lib/modules/$kernel/build" \
     sh "$repo/scripts/a14-kbuild-compat.sh" "$kernel"; then
  echo >&2
  echo "A14 module preflight failed; package was not installed." >&2
  echo "The compiler/Kbuild output above is the authoritative failure, not DKMS/Apport's generic 'kernel package not supported' line." >&2
  exit 1
fi
make clean >/dev/null 2>&1 || true

deb=$("$repo/scripts/build-deb.sh")
if [ -z "$deb" ] || [ ! -f "$deb" ]; then
  echo "build-deb.sh did not return a valid .deb path: ${deb:-<empty>}" >&2
  exit 1
fi
case "$deb" in
  *.deb) ;;
  *) echo "build-deb.sh returned a non-DEB path: $deb" >&2; exit 1;;
esac

# Explicitly reinstall even when the local package version matches. This is a
# development-tree installer, so also allow an intentional downgrade when the
# checked-out branch carries an older package version than another experiment
# already installed on the machine. apt still resolves the exact local DEB;
# --allow-downgrades only removes the otherwise-fatal version-direction guard.
sudo apt-get install -y --reinstall --allow-downgrades "$deb"

icon_dest=/usr/share/icons/hicolor/scalable/status
ext_dest=/usr/share/gnome-shell/extensions/asus-a14-modes@omerfaruknehir/icons
for profile in whisper quiet normal turbo full-speed; do
  icon="a14-power-profile-$profile-symbolic.svg"
  src="$repo/userspace/gnome/icons/$icon"
  if ! cmp -s "$src" "$icon_dest/$icon"; then
    echo "Installed GNOME icon does not match repository asset: $icon_dest/$icon" >&2
    exit 1
  fi
  if ! cmp -s "$src" "$ext_dest/$icon"; then
    echo "Installed extension icon does not match repository asset: $ext_dest/$icon" >&2
    exit 1
  fi
done

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  sudo gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi

echo
echo "Installed. Current status:"
sudo asus-a14-control status || true
echo
echo "GNOME Shell caches themed icons in-process. Log out and back in once after"
echo "changing these meter assets; the files on disk have already been verified."
echo
echo "After testing, perform one controlled warm reboot. If boot ever stalls, hold"
echo "power to cold-boot and disable the service from recovery with:"
echo "  systemctl disable asus-zenbook-a14-ec.service"
