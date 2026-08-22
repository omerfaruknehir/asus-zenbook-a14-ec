#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Read-only collector for the ASUS Zenbook A14 factory-ACPI boot experiment.
set -u

section(){ printf '\n===== %s =====\n' "$1"; }
kv(){ printf '%s=%s\n' "$1" "$2"; }
read1(){ [[ -r "$1" ]] && tr '\0' ' ' <"$1" 2>/dev/null || true; }

section IDENTITY
uname -a
printf 'cmdline='; cat /proc/cmdline 2>/dev/null || true
for f in sys_vendor product_name product_version board_vendor board_name board_version bios_vendor bios_version bios_date; do
    [[ -r "/sys/class/dmi/id/$f" ]] && kv "$f" "$(cat "/sys/class/dmi/id/$f")"
done

section FIRMWARE_MODE
kv efi "$([[ -d /sys/firmware/efi ]] && echo present || echo absent)"
kv acpi_tables "$([[ -d /sys/firmware/acpi/tables ]] && echo present || echo absent)"
if [[ -r /proc/device-tree/model ]]; then
    kv device_tree_model "$(read1 /proc/device-tree/model)"
else
    kv device_tree_model none
fi
if [[ -d /sys/firmware/acpi/tables ]]; then
    find /sys/firmware/acpi/tables -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort
    section ACPI_TABLE_HASHES
    for t in /sys/firmware/acpi/tables/*; do
        [[ -f "$t" ]] || continue
        sha256sum "$t" 2>/dev/null || true
    done
fi

section BOOT_CLASSIFICATION
if [[ -d /sys/firmware/acpi/tables && ! -r /proc/device-tree/model ]]; then
    echo classification=ACPI_ONLY
elif [[ -r /proc/device-tree/model ]]; then
    echo classification=DT_PRESENT
else
    echo classification=UNKNOWN
fi
if grep -qw acpi=force /proc/cmdline 2>/dev/null; then echo acpi_force=true; else echo acpi_force=false; fi

section ROOT_FILESYSTEM
findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS,UUID / 2>&1 || true
findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS,UUID /boot /boot/efi 2>&1 || true
lsblk -o NAME,MAJ:MIN,SIZE,TYPE,FSTYPE,FSVER,LABEL,UUID,MOUNTPOINTS 2>&1 || true

section PCI
command -v lspci >/dev/null 2>&1 && lspci -nnk 2>&1 || echo 'lspci unavailable'

section ACPI_DEVICES
for d in /sys/bus/acpi/devices/*; do
    [[ -d "$d" ]] || continue
    echo "--- ${d##*/} ---"
    [[ -r "$d/path" ]] && kv path "$(cat "$d/path")"
    [[ -r "$d/hid" ]] && kv hid "$(cat "$d/hid")"
    [[ -r "$d/uid" ]] && kv uid "$(cat "$d/uid")"
    [[ -r "$d/adr" ]] && kv adr "$(cat "$d/adr")"
    [[ -r "$d/modalias" ]] && kv modalias "$(cat "$d/modalias")"
    [[ -r "$d/status" ]] && kv status "$(cat "$d/status")"
    [[ -L "$d/physical_node" ]] && kv physical_node "$(readlink -f "$d/physical_node")"
    [[ -L "$d/driver" ]] && kv driver "$(basename "$(readlink -f "$d/driver")")"
done

section PLATFORM_DEVICES
for d in /sys/bus/platform/devices/*; do
    [[ -d "$d" ]] || continue
    name=${d##*/}
    driver=''
    [[ -L "$d/driver" ]] && driver="$(basename "$(readlink -f "$d/driver")")"
    modalias=''
    [[ -r "$d/modalias" ]] && modalias="$(cat "$d/modalias")"
    printf '%s\tdriver=%s\tmodalias=%s\n' "$name" "${driver:-none}" "${modalias:-none}"
done | sort

section IOMMU_GROUPS
if [[ -d /sys/kernel/iommu_groups ]]; then
    for g in /sys/kernel/iommu_groups/*; do
        [[ -d "$g" ]] || continue
        printf 'group=%s' "${g##*/}"
        for dev in "$g"/devices/*; do [[ -e "$dev" ]] && printf ' %s' "${dev##*/}"; done
        echo
    done
else
    echo none
fi

section GRAPHICS
for f in /sys/class/graphics/fb*; do
    [[ -e "$f" ]] || continue
    echo "--- $f ---"
    [[ -r "$f/name" ]] && kv name "$(cat "$f/name")"
    [[ -r "$f/modes" ]] && cat "$f/modes"
done
if [[ -d /sys/class/drm ]]; then
    find -L /sys/class/drm -maxdepth 2 -type f \( -name status -o -name enabled -o -name modes \) -print -exec head -n 20 {} \; 2>/dev/null || true
fi

section NETWORK
ip -details link 2>&1 || true
command -v rfkill >/dev/null 2>&1 && rfkill list 2>&1 || true

section SYSTEMD
systemctl is-system-running 2>&1 || true
systemctl --failed --no-pager 2>&1 || true
systemctl status multi-user.target --no-pager 2>&1 | head -n 80 || true

section POWER_AND_CPU
command -v lscpu >/dev/null 2>&1 && lscpu 2>&1 || true
for p in /sys/devices/system/cpu/cpufreq/policy*; do
    [[ -d "$p" ]] || continue
    echo "--- $p ---"
    for f in scaling_driver scaling_governor scaling_cur_freq cpuinfo_cur_freq cpuinfo_min_freq cpuinfo_max_freq scaling_min_freq scaling_max_freq; do
        [[ -r "$p/$f" ]] && kv "$f" "$(cat "$p/$f")"
    done
done

section TARGETED_KERNEL_ERRORS
journalctl -k -b --no-pager 2>/dev/null | grep -Ei \
'ACPI|IORT|SMMU|arm-smmu|iommu|QCOM0C0D|x1e80100-tlmm|pinctrl|gpio|GIO0|GenericSerialBus|ROP1|PRTC|_GRT|PCIe|pci |nvme|SCM|PSCI|efi|firmware bug|probe.*failed|error -|failed with error' \
|| true

section FULL_KERNEL_LOG
journalctl -k -b --no-pager 2>/dev/null || dmesg 2>/dev/null || true

section RESULT
acpi=0; nodt=0; root=0; nvme=0; multi=0; tlmm=0; rop1=0
[[ -d /sys/firmware/acpi/tables ]] && acpi=1
[[ ! -r /proc/device-tree/model ]] && nodt=1
findmnt -n / >/dev/null 2>&1 && root=1
findmnt -n -o SOURCE / 2>/dev/null | grep -q 'nvme' && nvme=1
systemctl is-active --quiet multi-user.target 2>/dev/null && multi=1
journalctl -k -b --no-pager 2>/dev/null | grep -q 'x1e80100-tlmm QCOM0C0D:00: probe .*error -22' && tlmm=1
journalctl -k -b --no-pager 2>/dev/null | grep -q 'Region \[ROP1\].*GenericSerialBus' && rop1=1
kv acpi_tables_present "$acpi"
kv device_tree_absent "$nodt"
kv root_mounted "$root"
kv root_on_nvme "$nvme"
kv multi_user_active "$multi"
kv known_tlmm_error_seen "$tlmm"
kv known_rop1_error_seen "$rop1"
if (( acpi && nodt && root && nvme && multi )); then
    echo milestone_acpi_userspace=PASS
else
    echo milestone_acpi_userspace=FAIL
fi
