#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Create an A/B control GRUB entry: same experimental kernel/initramfs, but
# explicitly load the exact DTB from the currently running known-good A14 boot.
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "ERROR: run with sudo/root" >&2
    exit 1
fi

KREL=7.1.5-a14-acpi-full0
KERNEL="/boot/vmlinuz-$KREL"
INITRD="/boot/initrd.img-$KREL"
DTDIR=/boot/a14-full-acpi-control
DTB="$DTDIR/known-good-live.dtb"
SNIPPET=/etc/grub.d/42_a14_full_acpi_dt_control
ENTRY="ASUS Zenbook A14 — SAME KERNEL + KNOWN-GOOD DT control ($KREL)"

for f in "$KERNEL" "$INITRD" /sys/firmware/fdt; do
    [[ -r "$f" ]] || { echo "ERROR: required file is not readable: $f" >&2; exit 1; }
done
for c in grub-probe grub-mkrelpath update-grub sha256sum; do
    command -v "$c" >/dev/null 2>&1 || { echo "ERROR: missing command: $c" >&2; exit 1; }
done

# This helper must be run from a boot that actually has a firmware DT.
[[ -d /proc/device-tree ]] || {
    echo "ERROR: current boot has no /proc/device-tree; boot the known-good DT kernel first" >&2
    exit 1
}

mkdir -p "$DTDIR"
cp --reflink=auto --sparse=always /sys/firmware/fdt "$DTB"
chmod 0644 "$DTB"
sync "$DTB"

DTB_SHA="$(sha256sum "$DTB" | awk '{print $1}')"
KERNEL_SHA="$(sha256sum "$KERNEL" | awk '{print $1}')"
INITRD_SHA="$(sha256sum "$INITRD" | awk '{print $1}')"

uuid="$(grub-probe --target=fs_uuid "$KERNEL")"
kp="$(grub-mkrelpath "$KERNEL")"
ip="$(grub-mkrelpath "$INITRD")"
dp="$(grub-mkrelpath "$DTB")"

args=()
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        BOOT_IMAGE=*|initrd=*|acpi=*|panic=*|oops=*|loglevel=*|earlycon=*|console=*|ignore_loglevel|initcall_debug|keep_bootcon) ;;
        *) args+=("$arg") ;;
    esac
done
cmdline="${args[*]} acpi=off loglevel=8 ignore_loglevel panic=0 oops=panic printk.time=1"

cat > "$SNIPPET" <<EOF
#!/bin/sh
exec tail -n +3 \$0
# A/B control for the full-ACPI experiment.
# SAME kernel + SAME initramfs as ACPI-only entry, but an explicit known-good
# live DTB is loaded and ACPI is forced off.
menuentry '$ENTRY' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root $uuid
    linux $kp $cmdline
    devicetree $dp
    initrd $ip
}
EOF
chmod 0755 "$SNIPPET"

grep -qE '^[[:space:]]*devicetree[[:space:]]' "$SNIPPET" || {
    echo "ERROR: control entry lacks devicetree command" >&2; exit 1;
}
grep -q 'acpi=off' "$SNIPPET" || { echo "ERROR: control entry lacks acpi=off" >&2; exit 1; }

update-grub

cat <<EOF
A14_FULL_ACPI_DT_CONTROL=READY
entry=$ENTRY
kernel=$KERNEL
kernel_sha256=$KERNEL_SHA
initrd=$INITRD
initrd_sha256=$INITRD_SHA
dtb=$DTB
dtb_sha256=$DTB_SHA
acpi=off
panic=0

Boot THIS control entry next, not the ACPI-only entry.
If this control boots, the experimental kernel itself is viable and the failure
is specifically in the DT-less/full-ACPI path.
If this control also fails, the problem is in the experimental kernel/config/initramfs,
not merely ACPI authority.
EOF
