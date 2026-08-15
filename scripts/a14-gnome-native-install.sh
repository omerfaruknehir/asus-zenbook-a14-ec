#!/bin/sh

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ok=1

for cmd in sudo apt-get python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: missing required command: $cmd" >&2
        ok=0
    fi
done

if [ "$ok" -eq 1 ]; then
    sudo apt-get install -y devscripts dpkg-dev build-essential || ok=0
fi

if [ "$ok" -eq 1 ]; then
    python3 "$repo/scripts/a14-gnome-native-five-profile-clean-ui.py" || ok=0
fi

if [ "$ok" -eq 1 ]; then
    echo "A14_GNOME_NATIVE_INSTALL_WRAPPER=PASS"
    exit 0
fi

echo "A14_GNOME_NATIVE_INSTALL_WRAPPER=FAIL" >&2
exit 1
