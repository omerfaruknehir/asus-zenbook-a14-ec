#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# ACPI ROOT12: read-only audit for remaining module-load failures after ROOT11 built-in conversion.
#
# Safety invariants:
#   - no kernel build
#   - no module build/install
#   - no initramfs build
#   - no GRUB writes
#   - no service mutation
#   - no reboot
set -euo pipefail

ACTION="${1:-audit}"
OWNER="${SUDO_USER:-}"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
section(){ printf '\n===== %s =====\n' "$*"; }
run(){ printf '\n$ %s\n' "$*"; "$@" 2>&1 || printf 'COMMAND_FAILED exit=%s: %s\n' "$?" "$*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"
[[ -n "$OWNER" && "$OWNER" != root ]] || die "run with sudo from your normal login"
OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
[[ -d "$OWNER_HOME" ]] || die "cannot resolve owner home"

WORK="${A14_74C9_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="$WORK/linux-7.1.5"
OUT="$WORK/root0-build"
REPORT="$OWNER_HOME/Downloads/a14-acpi-root12-remaining-modules-audit.txt"
ROOT11_JOURNAL="$OWNER_HOME/Downloads/a14-acpi-root11-journal.txt"
ROOT11_CONFIG="/boot/config-7.1.5-a14-acpi-root11"
ROOT11_VMLINUZ="/boot/vmlinuz-7.1.5-a14-acpi-root11"

NAMES=(hid_asus_ec leds_qcom_flash hm1092 qcom_cci_sync autofs4 i2c_dev i2c_qcom_cci)
SYMS=(HID_ASUS_EC HID_ASUS_ZENBOOK_A14_EC LEDS_QCOM_FLASH VIDEO_HM1092 HM1092 QCOM_CCI_SYNC AUTOFS_FS I2C_CHARDEV I2C_QCOM_CCI)

for c in awk cat date find grep head journalctl ls modinfo sed sort strings tr uname wc; do need "$c"; done

cfg_val(){
    local cfg="$1" sym="$2"
    if [[ -r "$cfg" ]]; then
        grep -E "^(CONFIG_${sym}=|# CONFIG_${sym} is not set)" "$cfg" | tail -n1 || true
    else
        printf 'CONFIG_FILE_MISSING=%s\n' "$cfg"
    fi
}

scan_name(){
    local name="$1"
    section "module-name $name"
    say "module_name=$name"
    run modinfo "$name"
    run grep -RIn --exclude='*.bin' --exclude='*.mbn' --exclude='*.elf' --exclude='*.zst' --exclude='*.ko' -- "$name" \
        /etc/modules-load.d /usr/lib/modules-load.d /lib/modules-load.d /etc/modprobe.d /usr/lib/modprobe.d /lib/modprobe.d 2>/dev/null
    if [[ -d "$SRC" ]]; then
        run find "$SRC" -type f \( -iname "*${name}*" -o -iname "*${name//_/-}*" \) -printf '%p\n'
        run grep -RIn --exclude-dir=.git --exclude='*.o' --exclude='*.cmd' --exclude='*.a' --exclude='*.ko' --exclude='vmlinux*' -- "$name" "$SRC" 2>/dev/null
        run grep -RIn --exclude-dir=.git --exclude='*.o' --exclude='*.cmd' --exclude='*.a' --exclude='*.ko' --exclude='vmlinux*' -- "${name//_/-}" "$SRC" 2>/dev/null
    fi
    if [[ -r "$ROOT11_VMLINUZ" ]]; then
        say "vmlinuz_string_hits_$name=$(strings -a "$ROOT11_VMLINUZ" | grep -F "$name" | head -n 20 | wc -l)"
        strings -a "$ROOT11_VMLINUZ" | grep -F "$name" | head -n 20 || true
    fi
}

scan_sym(){
    local sym="$1"
    section "config-symbol $sym"
    say "root11_config_${sym}=$(cfg_val "$ROOT11_CONFIG" "$sym")"
    [[ -r "$OUT/.config" ]] && say "build_config_${sym}=$(cfg_val "$OUT/.config" "$sym")" || say "build_config_${sym}=MISSING"
    if [[ -d "$SRC" ]]; then
        run grep -RIn --include='Kconfig*' --include='Makefile' -- "CONFIG_${sym}\|${sym}" "$SRC" 2>/dev/null
    fi
}

audit(){
    {
        say "A14_ACPI_ROOT12_REMAINING_MODULES_AUDIT_ENTERED=1"
        say "timestamp=$(date -Is)"
        say "running_kernel=$(uname -r)"
        say "mutations=false"
        say "reboot_performed=false"
        say "src=$SRC"
        say "out=$OUT"
        say "root11_config=$ROOT11_CONFIG"
        say "root11_journal=$ROOT11_JOURNAL"

        section "ROOT11 journal remaining failure lines"
        if [[ -r "$ROOT11_JOURNAL" ]]; then
            grep -E 'Failed to find module|Module .* is built in|A14_ACPI_ROOT11|pd-mapper|qrtr|multi-user|login|getty|AE_SUPPORT' "$ROOT11_JOURNAL" || true
        else
            say "root11_journal_missing=$ROOT11_JOURNAL"
        fi

        section "modules-load request files"
        for d in /etc/modules-load.d /usr/lib/modules-load.d /lib/modules-load.d; do
            if [[ -d "$d" ]]; then
                say "modules_load_dir=$d"
                find "$d" -maxdepth 1 -type f -printf '%p\n' | sort | while read -r f; do
                    say "--- $f"
                    sed -n '1,200p' "$f" || true
                done
            else
                say "modules_load_dir_missing=$d"
            fi
        done

        section "config-symbol summary"
        for sym in "${SYMS[@]}"; do
            say "root11_config_${sym}=$(cfg_val "$ROOT11_CONFIG" "$sym")"
        done

        section "kernel source quick paths"
        if [[ -d "$SRC" ]]; then
            run find "$SRC/drivers" "$SRC/fs" -maxdepth 5 -type f \
                \( -iname '*asus*ec*' -o -iname '*zenbook*a14*' -o -iname '*hm1092*' -o -iname '*cci*sync*' -o -iname '*qcom*flash*' -o -iname '*i2c*qcom*cci*' -o -iname '*autofs*' \) -printf '%p\n'
        else
            say "source_tree_missing=$SRC"
        fi

        for sym in "${SYMS[@]}"; do scan_sym "$sym"; done
        for name in "${NAMES[@]}"; do scan_name "$name"; done

        section "classification hints"
        for name in hid_asus_ec leds_qcom_flash hm1092 qcom_cci_sync; do
            if [[ -r "$ROOT11_JOURNAL" ]] && grep -Fq "Failed to find module '$name'" "$ROOT11_JOURNAL"; then
                say "remaining_failure=$name"
            fi
        done
        say "A14_ACPI_ROOT12_REMAINING_MODULES_AUDIT=PASS"
    } >"$REPORT" 2>&1

    chown "$OWNER:$OWNER" "$REPORT" 2>/dev/null || true
    say "A14_ACPI_ROOT12_REMAINING_MODULES_AUDIT=PASS"
    say "report=$REPORT"
    say "mutations=false"
    say "reboot_performed=false"
}

case "$ACTION" in
    audit|prepare) audit ;;
    *) die "usage: $0 [audit]" ;;
esac
