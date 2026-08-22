#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Finalize an already-built ROOT1 kernel after the prepare helper-generation
# failure. This script NEVER builds the kernel and NEVER reboots automatically.
set -euo pipefail

ACTION="${1:-finalize}"
KREL="7.1.5-a14-acpi-root1"
ENTRY="ASUS Zenbook A14 — ACPI ROOT1 TLMM+keyboard ($KREL)"
SNIPPET="/etc/grub.d/43_a14_acpi_root1"
INIT_HELPER="/usr/local/sbin/a14-acpi-root1-init"
KERNEL="/boot/vmlinuz-$KREL"
BOOT_CONFIG="/boot/config-$KREL"
OWNER="${SUDO_USER:-}"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"
[[ -n "$OWNER" && "$OWNER" != root ]] || die "run with sudo from your normal login"
OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
ROOTLOG="$OWNER_HOME/Downloads/a14-acpi-root1.txt"
ESPLOG_NAME="a14-acpi-root1.txt"

for c in sha256sum grep findmnt blkid lsblk grub-probe grub-mkrelpath update-grub grub-editenv grub-script-check sync; do need "$c"; done

unarm(){
    grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true
    say "A14_ACPI_ROOT1_UNARMED=1"
    say "reboot_performed=false"
}

status(){
    say "running_kernel=$(uname -r)"
    say "kernel=$KERNEL"
    [[ -s "$KERNEL" ]] && say "kernel_sha256=$(sha256sum "$KERNEL" | awk '{print $1}')"
    [[ -r "$BOOT_CONFIG" ]] && grep '^CONFIG_LOCALVERSION=' "$BOOT_CONFIG" || true
    [[ -r "$INIT_HELPER" ]] && say "init_helper=present" || say "init_helper=absent"
    [[ -r "$SNIPPET" ]] && say "grub_entry=present" || say "grub_entry=absent"
    say "next_entry=$(grub-editenv /boot/grub/grubenv list 2>/dev/null | sed -n 's/^next_entry=//p' | head -n1)"
    [[ -r "$ROOTLOG" ]] && say "report=$ROOTLOG" || true
    say "reboot_performed=false"
}

arm(){
    need grub-reboot
    [[ -s "$KERNEL" ]] || die "ROOT1 kernel missing: $KERNEL"
    [[ -x "$INIT_HELPER" ]] || die "ROOT1 PID1 helper missing/not executable: $INIT_HELPER"
    [[ -r "$SNIPPET" ]] || die "ROOT1 GRUB snippet missing: $SNIPPET"
    grub-script-check /boot/grub/grub.cfg >/dev/null
    grub-reboot "$ENTRY"
    next="$(grub-editenv /boot/grub/grubenv list | sed -n 's/^next_entry=//p' | head -n1)"
    [[ "$next" == "$ENTRY" ]] || die "failed to arm ROOT1 entry: ${next:-missing}"
    say "A14_ACPI_ROOT1_ARMED=1"
    say "next_entry=$next"
    say "reboot_performed=false"
    say "Reboot manually only when YOU choose: sudo reboot"
}

finalize(){
    [[ "$(uname -r)" != "$KREL" ]] || die "finalize from the normal DT/rescue kernel, not ROOT1"
    [[ -s "$KERNEL" ]] || die "already-built ROOT1 kernel is missing: $KERNEL"
    [[ -r "$BOOT_CONFIG" ]] || die "ROOT1 installed config is missing: $BOOT_CONFIG"
    grep -Fxq 'CONFIG_LOCALVERSION="-a14-acpi-root1"' "$BOOT_CONFIG" || die "installed ROOT1 config has wrong LOCALVERSION"
    grep -q '^# CONFIG_LOCALVERSION_AUTO is not set$' "$BOOT_CONFIG" || die "ROOT1 LOCALVERSION_AUTO unexpectedly enabled"
    for sym in ACPI PCI BLK_DEV_NVME EXT4_FS PINCTRL_X1E80100 I2C_QCOM_GENI HID I2C_HID_ACPI INPUT; do
        grep -q "^CONFIG_${sym}=y$" "$BOOT_CONFIG" || die "installed ROOT1 config lacks built-in CONFIG_${sym}=y"
    done

    root_src="$(findmnt -n -o SOURCE /)"
    root_fs="$(findmnt -n -o FSTYPE /)"
    [[ "$root_src" == /dev/nvme*n*p* ]] || die "root is not a direct NVMe partition: $root_src"
    [[ "$root_fs" == ext4 ]] || die "root is not ext4: $root_fs"
    root_partuuid="$(blkid -s PARTUUID -o value "$root_src")"
    [[ -n "$root_partuuid" ]] || die "cannot resolve root PARTUUID"
    root_parent="/dev/$(lsblk -no PKNAME "$root_src" | head -n1)"
    [[ -b "$root_parent" ]] || die "cannot resolve root NVMe parent"

    ESP_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
    esp_candidates=()
    while read -r dev parttype; do
        [[ -n "$dev" ]] || continue
        [[ "${parttype,,}" == "$ESP_GUID" ]] || continue
        esp_candidates+=("$dev")
    done < <(lsblk -rpn -o NAME,PARTTYPE "$root_parent" 2>/dev/null || true)
    esp_candidates_string="${esp_candidates[*]:-}"

    # Preparation must never inherit/leave an experimental one-shot selection.
    grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true

    # Write only the values that must be injected now, then append the runtime
    # body through a QUOTED heredoc. Therefore every $d/$p/$ROOTLOG/etc below
    # is preserved literally for ROOT1 runtime and cannot trigger set -u here.
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -u'
        printf 'ROOTLOG=%q\n' "$ROOTLOG"
        printf 'ESP_CANDIDATES=%q\n' "$esp_candidates_string"
        printf 'ESPLOGNAME=%q\n' "$ESPLOG_NAME"
        printf 'OWNER_NAME=%q\n' "$OWNER"
    } >"$INIT_HELPER"

    cat >>"$INIT_HELPER" <<'ROOT1_RUNTIME'
PATH=/usr/sbin:/usr/bin:/sbin:/bin
ESPMNT=/run/a14-esp

printf '%s\n' 'A14_ACPI_ROOT1_INIT_ENTERED=1' >"$ROOTLOG"
sync -f "$ROOTLOG" 2>/dev/null || sync

mkdir -p /proc /sys /dev /run
mountpoint -q /proc 2>/dev/null || mount -t proc proc /proc 2>/dev/null || true
mountpoint -q /sys 2>/dev/null || mount -t sysfs sysfs /sys 2>/dev/null || true
mountpoint -q /dev 2>/dev/null || mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mountpoint -q /run 2>/dev/null || mount -t tmpfs tmpfs /run 2>/dev/null || true
mkdir -p "$ESPMNT"

ESPLOG=''
for d in $ESP_CANDIDATES; do
    if mount -t vfat -o rw,sync "$d" "$ESPMNT" 2>/dev/null; then
        ESPLOG="$ESPMNT/$ESPLOGNAME"
        : >"$ESPLOG"
        printf 'A14_ACPI_ROOT1_EFI_MOUNT=PASS device=%s\n' "$d" >>"$ESPLOG"
        sync -f "$ESPLOG" 2>/dev/null || sync
        break
    fi
done

emit(){
    local line="$*"
    printf '%s\n' "$line" >>"$ROOTLOG"
    sync -f "$ROOTLOG" 2>/dev/null || sync
    if [[ -n "$ESPLOG" ]]; then
        printf '%s\n' "$line" >>"$ESPLOG"
        sync -f "$ESPLOG" 2>/dev/null || sync
    fi
}
append_file(){
    local src="$1"
    [[ -r "$src" ]] || return 0
    cat "$src" >>"$ROOTLOG" 2>/dev/null || true
    sync -f "$ROOTLOG" 2>/dev/null || sync
    if [[ -n "$ESPLOG" ]]; then
        cat "$src" >>"$ESPLOG" 2>/dev/null || true
        sync -f "$ESPLOG" 2>/dev/null || sync
    fi
}
append_cmd(){
    local tmp=/run/a14-cap.tmp
    "$@" >"$tmp" 2>&1 || true
    append_file "$tmp"
    rm -f "$tmp"
}

emit 'A14_ACPI_ROOT1_DIRECT_ROOT_MOUNT=PASS'
if [[ -n "$ESPLOG" ]]; then emit 'A14_ACPI_ROOT1_EFI_MIRROR=PASS'; else emit 'A14_ACPI_ROOT1_EFI_MIRROR=FAIL'; fi
emit "kernel=$(uname -a)"
emit "cmdline=$(cat /proc/cmdline 2>/dev/null || true)"
emit "root_mount=$(grep ' / ' /proc/mounts 2>/dev/null || true)"
sleep 3

emit '===== GIO0 TLMM DRIVER ====='
append_cmd sh -c 'for d in /sys/bus/platform/devices/QCOM0C0C:*; do [ -e "$d" ] || continue; echo "$d"; ls -l "$d/driver" "$d/driver_override" 2>&1; done'
emit '===== GPIO BUS ====='
append_cmd sh -c 'ls -l /sys/bus/gpio/devices /sys/class/gpio 2>&1; for d in /sys/bus/gpio/devices/*; do [ -e "$d" ] || continue; echo "-- $d"; readlink -f "$d/device" 2>/dev/null; done'
emit '===== KEY ACPI DEVICES ====='
append_cmd sh -c 'for p in QCOM0C0C QCOM0C10 QTEC0001 PNP0C50; do for d in /sys/bus/acpi/devices/$p*; do [ -e "$d" ] || continue; echo "-- $d"; cat "$d/path" 2>/dev/null; ls -l "$d/physical_node" "$d/driver" 2>&1; done; done'
emit '===== I2C DEVICES ====='
append_cmd sh -c 'ls -l /sys/bus/i2c/devices 2>&1; for d in /sys/bus/i2c/devices/*; do [ -e "$d" ] || continue; echo "-- $d"; cat "$d/name" 2>/dev/null; ls -l "$d/driver" 2>&1; done'
emit '===== INPUT DEVICES ====='
append_file /proc/bus/input/devices
emit '===== INTERRUPTS ====='
append_file /proc/interrupts
emit '===== ROOT/NVME ====='
append_file /proc/partitions
emit '===== HIGH SIGNAL DMESG ====='
append_cmd sh -c "dmesg | grep -Ei 'A14GIO0|QCOM WoA GPIO|QCOM0C0C|QCOM0C10|QTEC0001|PNP0C50|tlmm|pinctrl|gpio|geni|i2c|hid|keyboard|irq|acpi|fail|error|timeout'"
emit '===== FULL DMESG ====='
append_cmd dmesg

if grep -qE 'QTEC0001|0B05|ASUS.*Keyboard|Keyboard' /proc/bus/input/devices 2>/dev/null; then
    emit 'A14_ACPI_ROOT1_KEYBOARD_PATH=PASS'
else
    emit 'A14_ACPI_ROOT1_KEYBOARD_PATH=INCOMPLETE'
fi
emit 'A14_ACPI_ROOT1_CAPTURE_COMPLETE=1'
chown "$OWNER_NAME:$OWNER_NAME" "$ROOTLOG" 2>/dev/null || true
sync
if [[ -n "$ESPLOG" ]]; then umount "$ESPMNT" 2>/dev/null || true; sync; fi
printf '%s\n' 'ROOT1 capture complete. Automatic reboot is disabled.' >/dev/console 2>/dev/null || true

# Do not auto-reboot. If input works, provide a shell. If input still does not
# work, the machine simply remains here until the user power-cycles/reboots.
if [[ -c /dev/tty0 && -x /bin/bash ]]; then
    exec /bin/bash -i </dev/tty0 >/dev/tty0 2>&1
fi
while :; do sleep 60; done
ROOT1_RUNTIME
    chmod 0755 "$INIT_HELPER"
    bash -n "$INIT_HELPER" || die "generated ROOT1 PID1 helper failed bash -n"

    # Replace only our experiment's GRUB snippets; leave distro DT entries.
    rm -f /etc/grub.d/41_a14_acpi_v2 /etc/grub.d/42_a14_acpi_v2_root_debug \
          /etc/grub.d/41_a14_full_acpi_checkpoint /etc/grub.d/43_a14_acpi_root0 "$SNIPPET"
    rm -f "$ROOTLOG"

    boot_uuid="$(grub-probe --target=fs_uuid "$KERNEL")"
    kp="$(grub-mkrelpath "$KERNEL")"
    cmdline="root=PARTUUID=$root_partuuid rw rootfstype=ext4 rootwait init=$INIT_HELPER acpi=force earlycon=efifb,ram console=tty0 loglevel=8 ignore_loglevel printk.time=1 panic=30 clk_ignore_unused pd_ignore_unused cma=128M efi=noruntime stubble.dtb_override=false"

    cat >"$SNIPPET" <<EOF
#!/bin/sh
exec tail -n +3 \$0
# ACPI v2.1 ROOT1. NO DTB. NO initramfs. Does NOT auto-reboot.
menuentry '$ENTRY' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root $boot_uuid
    set gfxpayload=keep
    linux $kp $cmdline
}
EOF
    chmod 0755 "$SNIPPET"
    update-grub
    grub-script-check /boot/grub/grub.cfg >/dev/null
    ! grep -Eq '^[[:space:]]*initrd[[:space:]]' "$SNIPPET" || die "ROOT1 unexpectedly uses initramfs"
    ! grep -Eq '^[[:space:]]*devicetree[[:space:]]' "$SNIPPET" || die "ROOT1 unexpectedly loads a DTB"

    # Finalize deliberately leaves the one-shot selection empty.
    grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true
    image_sha="$(sha256sum "$KERNEL" | awk '{print $1}')"

    say "A14_ACPI_ROOT1_FINALIZE=PASS"
    say "kernelrelease=$KREL"
    say "kernel_sha256=$image_sha"
    say "kernel_rebuilt=false"
    say "modules_built=false"
    say "initramfs_used=false"
    say "init_helper=$INIT_HELPER"
    say "root_report=$ROOTLOG"
    say "esp_candidates=${esp_candidates_string:-none}"
    say "efi_report_name=/$ESPLOG_NAME"
    say "grub_entry=$ENTRY"
    say "next_entry=UNARMED"
    say "reboot_performed=false"
    say "To arm later: sudo bash scripts/a14-acpi-root1-finalize.sh arm"
    say "Then reboot manually only when YOU choose: sudo reboot"
}

case "$ACTION" in
    finalize) finalize ;;
    arm) arm ;;
    unarm) unarm ;;
    status) status ;;
    *) die "usage: $0 {finalize|arm|unarm|status}" ;;
esac
