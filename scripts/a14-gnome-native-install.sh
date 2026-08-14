#!/bin/sh

ok=1

for cmd in sudo apt-get python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: missing required command: $cmd" >&2
        ok=0
    fi
done

if [ "$ok" -eq 1 ]; then
    sudo apt-get install -y devscripts dpkg-dev build-essential patch || ok=0
fi

if [ "$ok" -eq 1 ]; then
    python3 ./scripts/a14-gnome-native-five-profile.py || ok=0
fi

if [ "$ok" -eq 1 ]; then
    echo "A14_GNOME_NATIVE_INSTALL_WRAPPER=PASS"
else
    echo "A14_GNOME_NATIVE_INSTALL_WRAPPER=FAIL" >&2
fi

true
