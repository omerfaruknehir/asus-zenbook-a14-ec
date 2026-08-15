#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
model=$(tr -d '\000' </proc/device-tree/model 2>/dev/null || true)
case "$model" in
  *"ASUS Zenbook A14"*"UX3407RA"*|*"ASUS Zenbook A14"*"UX3407QA"*) ;;
  *) echo "Unsupported device: ${model:-no device-tree model}" >&2; exit 1;;
esac

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

sudo apt-get install -y "$deb"
echo
echo "Installed. Current status:"
sudo asus-a14-control status || true
echo
echo "After testing, perform one controlled warm reboot. If boot ever stalls, hold"
echo "power to cold-boot and disable the service from recovery with:"
echo "  systemctl disable asus-zenbook-a14-ec.service"
