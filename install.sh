#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
model=$(tr -d '\000' </proc/device-tree/model 2>/dev/null || true)
case "$model" in
  *"ASUS Zenbook A14"*"UX3407RA"*|*"ASUS Zenbook A14"*"UX3407QA"*) ;;
  *) echo "Unsupported device: ${model:-no device-tree model}" >&2; exit 1;;
esac

if [ ! -e "/lib/modules/$(uname -r)/build/Makefile" ]; then
  echo "Installing build requirements and running-kernel headers..."
  sudo apt-get update
  sudo apt-get install -y dkms build-essential dpkg-dev "linux-headers-$(uname -r)"
else
  sudo apt-get install -y dkms build-essential dpkg-dev
fi

deb=$($repo/scripts/build-deb.sh)
sudo apt-get install -y "$deb"
echo
echo "Installed. Current status:"
sudo asus-a14-control status || true
echo
echo "After testing, perform one controlled warm reboot. If boot ever stalls, hold"
echo "power to cold-boot and disable the service from recovery with:"
echo "  systemctl disable asus-zenbook-a14-ec.service"
