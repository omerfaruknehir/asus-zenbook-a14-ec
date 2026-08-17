#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Maintain one ACPI-only GRUB entry that halts after device initcall ordinal N.
#
# Stateful mode:
#   first run:  sudo ... mid
#   after boot: sudo ... stuck
#               sudo ... rebooted
#
# The helper remembers the surviving suspect range and automatically chooses
# the next midpoint.  This is useful when the failing initcall hard-resets the
# machine and leaves no persistent log.
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
STATE_DIR="/var/lib/a14-full-acpi"
STATE="$STATE_DIR/device-bisect.state"

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

current_from_snippet(){
    [[ -r "$SNIPPET" ]] || return 1
    grep -Eo 'a14_device_halt_after=[0-9]+' "$SNIPPET" | head -n1 | cut -d= -f2
}

load_state(){
    [[ -r "$STATE" ]] || return 1
    # shellcheck disable=SC1090
    source "$STATE"
    [[ "${state_total:-}" == "$total" ]] || die "saved bisect total (${state_total:-?}) does not match current vmlinux ($total); run '$0 reset'"
    [[ "${state_low:-}" =~ ^[0-9]+$ && "${state_high:-}" =~ ^[0-9]+$ && "${state_current:-}" =~ ^[0-9]+$ ]] || die "invalid saved bisect state"
}

save_state(){
    local low="$1" high="$2" current="$3" outcome="$4"
    mkdir -p "$STATE_DIR"
    cat > "$STATE" <<EOF
state_total=$total
state_low=$low
state_high=$high
state_current=$current
state_last_outcome=$outcome
EOF
}

case "$SELECT" in
    reset)
        rm -f "$STATE"
        echo "A14_FULL_ACPI_DEVICE_BISECT_STATE=RESET"
        echo "next_command=sudo bash $0 mid"
        exit 0
        ;;
    mid)
        low=1
        high="$total"
        N=$(( (low + high) / 2 ))
        outcome="initial"
        ;;
    stuck|rebooted)
        if load_state; then
            low="$state_low"
            high="$state_high"
            current="$state_current"
        else
            # Backward-compatible recovery for a midpoint entry created by an
            # older stateless helper.  The original range was 1..total.
            current="$(current_from_snippet || true)"
            [[ "$current" =~ ^[0-9]+$ ]] || die "cannot recover previous bisect ordinal from $SNIPPET"
            low=1
            high="$total"
        fi

        (( current >= low && current <= high )) || die "previous threshold $current is outside saved suspect range $low..$high"

        if [[ "$SELECT" == stuck ]]; then
            # The checkpoint after `current` was reached, so 1..current are
            # proven good and the culprit must be later.
            low=$(( current + 1 ))
        else
            # We reset before reaching the checkpoint after `current`, so the
            # culprit is current or earlier within the still-live range.
            high="$current"
        fi
        outcome="$SELECT"

        (( low <= high )) || die "bisect range became empty after '$SELECT'; result is inconsistent/nondeterministic"
        if (( low == high )); then
            save_state "$low" "$high" "$low" "$outcome"
            echo "A14_FULL_ACPI_DEVICE_BISECT=CONVERGED"
            echo "device_initcall_total=$total"
            echo "culprit_ordinal=$low"
            echo "suspect_range=$low..$high"
            echo "No new GRUB threshold was created; the exact ordinal is isolated."
            exit 0
        fi
        N=$(( (low + high) / 2 ))
        ;;
    [0-9]*)
        N="$SELECT"
        (( N >= 1 && N <= total )) || die "N=$N outside 1..$total"
        low=1
        high="$total"
        outcome="manual"
        ;;
    *)
        die "usage: $0 {mid|stuck|rebooted|reset|N}; N must be 1..$total"
        ;;
esac

(( N >= low && N <= high )) || die "next threshold N=$N outside suspect range $low..$high"

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
# A14_DEVICE_BISECT_TOTAL=$total
# A14_DEVICE_BISECT_LOW=$low
# A14_DEVICE_BISECT_HIGH=$high
# A14_DEVICE_BISECT_CURRENT=$N
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

save_state "$low" "$high" "$N" "$outcome"
update-grub

echo "A14_FULL_ACPI_DEVICE_BISECT_ENTRY=READY"
echo "previous_outcome=$outcome"
echo "device_initcall_total=$total"
echo "suspect_range=$low..$high"
echo "halt_after=$N"
echo "entry=$entry"
echo "hardware_dtb_loaded=false"
echo "custom_checkpoint_entries=1"
