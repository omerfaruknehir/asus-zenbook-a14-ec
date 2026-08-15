#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ext_uuid=asus-a14-modes@omerfaruknehir

check_icon() {
    profile=$1
    expected=$2
    source_name=$3
    userspace="$repo/userspace/gnome/icons/a14-power-profile-$profile-symbolic.svg"
    extension="$repo/gnome-shell/$ext_uuid/icons/a14-power-profile-$profile-symbolic.svg"

    [ -f "$userspace" ] || {
        echo "Missing GNOME meter icon: $userspace" >&2
        return 1
    }
    [ -f "$extension" ] || {
        echo "Missing extension meter icon: $extension" >&2
        return 1
    }

    actual=$(sha256sum "$userspace" | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
        echo "Wrong A14 $profile icon: expected exact supplied $source_name ($expected), got $actual" >&2
        return 1
    fi

    if ! cmp -s "$userspace" "$extension"; then
        echo "A14 $profile icon differs between userspace and extension copies" >&2
        return 1
    fi
}

# Exact SHA-256 values from the user's supplied meters.tar.xz. Do not redraw,
# normalize, recolor, or substitute these assets.
check_icon whisper    ad6d2c5e6f0a975c9f228744071b08156da0b1984684089c9666d724a79fcba7 meter-min.svg
check_icon quiet      d888dbbdf36ed98a8608e48d567a581fe04f0df8fdc256c0ee16f6ea78954889 meter-1-in-4.svg
check_icon normal     e69461b91f7431cef735060207d00cf99b9b02081c5a68e1119574767cca492e meter-1-in-2.svg
check_icon turbo      fdd8737b1c0b71eaad90e0454d66284f6e1762496ba5358fe8f68776495711ff meter-3-in-4.svg
check_icon full-speed 7d19e6215909da1251bead1959ffebb0418a6f87b90c7f323756adfda5162f3c meter-max.svg

echo "A14 meter icons verified: min / 1-in-4 / 1-in-2 / 3-in-4 / max"
