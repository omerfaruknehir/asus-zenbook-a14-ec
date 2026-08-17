#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Maintain one ACPI-only GRUB entry that halts after device initcall ordinal N.
set -euo pipefail

SELECT="${1:-mid}"
KREL="7.1.5-a14-acpi-full0"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
WORK="${A14_FULL_ACPI_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
OUT="$WORK/build"
VMLINUX="$OUT/vmlinux"
CONFIG="$OUT/.config"
KERNEL="/boot/vmlinuz-$KREL"
INITRD="/boot/initrd.img-$KREL"
SNIPPET="/etc/grub.d/41_a14_full_acpi_checkpoint"
OLD_MOUNTROOT="/etc/grub.d/41_a14_full_acpi_mountroot_shell"

die(){ echo "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"
for c in python3 nm grub-probe grub-mkrelpath update-grub; do need "$c"; done
[[ -s "$VMLINUX" ]] || die "missing built vmlinux: $VMLINUX"
[[ -r "$CONFIG" ]] || die "missing build config: $CONFIG"
[[ -r "$KERNEL" && -r "$INITRD" ]] || die "experimental kernel/initrd missing"

total="$(python3 - "$VMLINUX" "$CONFIG" <<'PY'
import subprocess, sys
vmlinux, config = sys.argv[1:]
out = subprocess.check_output(["nm", "-n", vmlinux], text=True, errors="replace")
syms = {}
for line in out.splitlines():
    p = line.split()
    if len(p) >= 3 and p[2] in {"__initcall6_start", "__initcall7_start"}:
        syms[p[2]] = int(p[0], 16)
missing = {"__initcall6_start", "__initcall7_start"} - syms.keys()
if missing:
    raise SystemExit("missing initcall boundary symbols: " + ",".join(sorted(missing)))
conf = open(config, encoding="utf-8", errors="replace").read()
entry_size = 4 if "CONFIG_HAVE_ARCH_PREL32_RELOCATIONS=y" in conf else 8
span = syms["__initcall7_start"] - syms["__initcall6_start"]
if span <= 0 or span % entry_size:
    raise SystemExit(f"invalid device initcall span={span} entry_size={entry_size}")
print(span // entry_size)
PY
)"
[[ "$total" =~ ^[0-9]+$ && "$total" -gt 0 ]] || die "could not determine device initcall count"

case "$SELECT" in
    mid) N=$(( total / 2 )) ;;
    [0-9]*) N="$SELECT" ;;
    *) die "usage: $0 {mid|N}; N must be 0..$total" ;;
esac
(( N >= 0 && N <= total )) || die "N=$N outside 0..$total"

uuid="$(grub-probe --target=fs_uuid "$KERNEL")"
kp="$(grub-mkrelpath "$KERNEL")"
ip="$(grub-mkrelpath "$INITRD")"

args=()
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        BOOT_IMAGE=*|initrd=*|acpi=*|panic=*|oops=*|quiet|splash|break=*|debug|debug=*|loglevel=*|earlycon=*|console=*|ignore_loglevel|initcall_debug|keep_bootcon|a14_acpi_halt=*|a14_device_halt_after=*) ;;
        *) args+=("$arg") ;;
    esac
done
cmdline="${args[*]} acpi=force loglevel=8 ignore_loglevel printk.time=1 console=tty0 a14_acpi_halt=device-bisect a14_device_halt_after=$N"
entry="ASUS Zenbook A14 — ACPI DEVICE BISECT after $N/$total ($KREL)"

rm -f "$OLD_MOUNTROOT"
cat > "$SNIPPET" <<EOF
#!/bin/sh
exec tail -n +3 \$0
# Temporary ACPI-only device-initcall ordinal bisector. Intentionally no devicetree.
menuentry '$entry' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root $uuid
    linux $kp $cmdline
    initrd $ip
}
EOF
chmod 0755 "$SNIPPET"

! grep -qE '^[[:space:]]*devicetree[[:space:]]' "$SNIPPET" || die "unexpected devicetree command"
grep -q 'a14_acpi_halt=device-bisect' "$SNIPPET" || die "device-bisect halt parameter missing"
grep -q "a14_device_halt_after=$N" "$SNIPPET" || die "ordinal parameter missing"
update-grub

echo "A14_FULL_ACPI_DEVICE_BISECT_ENTRY=READY"
echo "device_initcall_total=$total"
echo "halt_after=$N"
echo "suspect_initial_range=1..$total"
echo "entry=$entry"
echo "hardware_dtb_loaded=false"
echo "custom_checkpoint_entries=1"
