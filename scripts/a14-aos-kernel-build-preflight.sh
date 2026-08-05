#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Targeted, read-only preflight for building the A14 CAMSS AOS kernel patch.
set -eu

release=$(uname -r)
arch=$(uname -m)
headers="/lib/modules/$release/build"

printf '%s\n' 'ASUS Zenbook A14 AOS kernel-build preflight'
printf '%s\n' '============================================'
printf 'kernel_release=%s\n' "$release"
printf 'architecture=%s\n' "$arch"
printf 'headers=%s\n' "$(readlink -f "$headers" 2>/dev/null || printf '%s' missing)"

printf '\n%s\n' '===== INSTALLED KERNEL PACKAGES ====='
image_pkg=
for candidate in \
    "linux-image-$release" \
    "linux-image-unsigned-$release" \
    "linux-modules-$release" \
    "linux-headers-$release"; do
    if dpkg-query -W -f='${binary:Package}\t${Version}\t${source:Package}\t${source:Version}\n' \
            "$candidate" 2>/dev/null; then
        case "$candidate" in
            linux-image-*|linux-image-unsigned-*)
                [ -n "$image_pkg" ] || image_pkg=$candidate
                ;;
        esac
    fi
done

if [ -n "$image_pkg" ]; then
    source_pkg=$(dpkg-query -W -f='${source:Package}' "$image_pkg" 2>/dev/null || true)
    source_version=$(dpkg-query -W -f='${source:Version}' "$image_pkg" 2>/dev/null || true)
else
    source_pkg=
    source_version=
fi
printf 'image_package=%s\n' "${image_pkg:-unknown}"
printf 'source_package=%s\n' "${source_pkg:-unknown}"
printf 'source_version=%s\n' "${source_version:-unknown}"

printf '\n%s\n' '===== REQUIRED KERNEL CONFIG ====='
config=
for candidate in "/boot/config-$release" "$headers/.config"; do
    if [ -r "$candidate" ]; then
        config=$candidate
        break
    fi
done
printf 'config=%s\n' "${config:-missing}"
if [ -n "$config" ]; then
    grep -E '^(CONFIG_(VIDEO_QCOM_CAMSS|VIDEO_OV02C10|IIO|QCOM_QMI_HELPERS|QRTR|RPMSG|REMOTEPROC|OF|ARM64))=' \
        "$config" || true
fi

printf '\n%s\n' '===== CAMSS MODULE ====='
camss_module=
for name in qcom_camss qcom-camss; do
    path=$(modinfo -n "$name" 2>/dev/null || true)
    if [ -n "$path" ]; then
        camss_module=$name
        printf 'module_name=%s\n' "$name"
        printf 'module_path=%s\n' "$path"
        modinfo -F vermagic "$name" 2>/dev/null | sed 's/^/module_vermagic=/' || true
        modinfo -F depends "$name" 2>/dev/null | sed 's/^/module_depends=/' || true
        break
    fi
done
[ -n "$camss_module" ] || printf '%s\n' 'module_path=built-in-or-unavailable'
printf 'loaded=%s\n' "$(lsmod 2>/dev/null | awk '$1 == "qcom_camss" { print "yes"; found=1 } END { if (!found) print "no" }')"

printf '\n%s\n' '===== A14 DEVICE TREES ====='
find /boot "/usr/lib/linux-image-$release" "/lib/firmware/$release" \
    -type f \( -iname '*zenbook*a14*.dtb' -o -iname '*x1e80100*asus*.dtb' \) \
    -print 2>/dev/null | sort -u || true
for link in /boot/dtb /boot/dtb-* /boot/dtbs/*; do
    [ -e "$link" ] || continue
    printf 'boot_dtb_entry=%s -> %s\n' "$link" "$(readlink -f "$link" 2>/dev/null || true)"
done

printf '\n%s\n' '===== BOOT PACKAGING ====='
for path in \
    "/boot/vmlinuz-$release" \
    "/boot/initrd.img-$release" \
    "/boot/System.map-$release" \
    "/boot/config-$release"; do
    if [ -e "$path" ]; then
        printf 'present=%s\n' "$path"
    else
        printf 'missing=%s\n' "$path"
    fi
done
if command -v bootctl >/dev/null 2>&1; then
    bootctl is-installed >/dev/null 2>&1 && printf '%s\n' 'systemd_boot=yes' || printf '%s\n' 'systemd_boot=no'
fi
if [ -d /boot/grub ]; then
    printf '%s\n' 'grub=yes'
else
    printf '%s\n' 'grub=no'
fi

printf '\n%s\n' '===== BUILD CAPACITY ====='
df -h "$HOME" /boot 2>/dev/null || true
for tool in gcc make bc bison flex pahole dtc fakeroot dpkg-buildpackage; do
    if command -v "$tool" >/dev/null 2>&1; then
        printf 'tool_%s=%s\n' "$tool" "$(command -v "$tool")"
    else
        printf 'tool_%s=missing\n' "$tool"
    fi
done

printf '\n%s\n' '===== SOURCE COMMAND ====='
if [ -n "$source_pkg" ] && [ -n "$source_version" ]; then
    printf 'apt_source_command=apt source %s=%s\n' "$source_pkg" "$source_version"
else
    printf '%s\n' 'apt_source_command=unresolved'
fi

printf '\n%s\n' 'read_only=true'
