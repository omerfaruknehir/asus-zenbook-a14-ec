#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# ACPI ROOT13: read-only provenance audit for remaining out-of-tree/stale module requests.
#
# Persistent safety invariants:
#   - no kernel build
#   - no module build/install
#   - no initramfs build/update
#   - no GRUB writes
#   - no service mutation
#   - no reboot
#
# The only writes are:
#   1. the requested report in ~/Downloads
#   2. an automatically removed /tmp scratch tree used for a Kconfig-only olddefconfig test
#      of CONFIG_LEDS_QCOM_FLASH=y. No kernel or module target is built.
set -euo pipefail

ACTION="${1:-audit}"
OWNER="${SUDO_USER:-}"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
section(){ printf '\n===== %s =====\n' "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }
run(){
    printf '\n$'
    printf ' %q' "$@"
    printf '\n'
    "$@" 2>&1 || printf 'COMMAND_FAILED exit=%s\n' "$?"
}
run_sh(){
    local desc="$1" cmd="$2"
    printf '\n$ %s\n' "$desc"
    bash -o pipefail -c "$cmd" 2>&1 || printf 'COMMAND_FAILED exit=%s: %s\n' "$?" "$desc"
}
show_file(){
    local f="$1"
    say "--- FILE: $f"
    if [[ -r "$f" ]]; then
        sed -n '1,400p' "$f"
        local lines
        lines="$(wc -l <"$f" 2>/dev/null || printf '0')"
        if [[ "$lines" =~ ^[0-9]+$ ]] && (( lines > 400 )); then
            say "--- TRUNCATED: $f has $lines lines (first 400 shown)"
        fi
    elif [[ -e "$f" ]]; then
        say "UNREADABLE"
    else
        say "MISSING"
    fi
}

[[ "$ACTION" == audit ]] || die "usage: $0 [audit]"
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"
[[ -n "$OWNER" && "$OWNER" != root ]] || die "run with sudo from your normal login"

OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
[[ -d "$OWNER_HOME" ]] || die "cannot resolve owner home"

WORK="${A14_74C9_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="${A14_KERNEL_SRC:-$WORK/linux-7.1.5}"
OUT="${A14_KERNEL_OUT:-$WORK/root0-build}"
REPORT="$OWNER_HOME/Downloads/a14-acpi-root13-outoftree-module-audit.txt"
ROOT11_CONFIG="${A14_ROOT11_CONFIG:-/boot/config-7.1.5-a14-acpi-root11}"
ROOT11_INITRD="${A14_ROOT11_INITRD:-/boot/initrd.img-7.1.5-a14-acpi-root11}"
NORMAL_KERNEL="${A14_NORMAL_KERNEL:-7.1.5-070105-generic}"
ARCH_NAME="${A14_ARCH:-arm64}"
TARGETS=(hid_asus_ec hm1092 qcom_cci_sync leds_qcom_flash)
OOT_TARGETS=(hid_asus_ec hm1092 qcom_cci_sync)
REQUEST_DIRS=(
    /etc/modules-load.d
    /usr/lib/modules-load.d
    /lib/modules-load.d
    /etc/modprobe.d
    /usr/lib/modprobe.d
    /lib/modprobe.d
    /etc/initramfs-tools
    /usr/share/initramfs-tools
    /etc/dracut.conf.d
    /usr/lib/dracut
)
REQUEST_FILES=(
    /etc/modules
    /etc/modules-load.d/asus-zenbook-a14-ec.conf
    /etc/modules-load.d/hm1092-cci-sync.conf
    /etc/modules-load.d/hm1092-ir-v6.conf
    /etc/modprobe.d/asus-zenbook-a14-ec.conf
    /etc/modprobe.d/blacklist-a14-kbd-led-legacy.conf
    /etc/initramfs-tools/modules
    /etc/dracut.conf
)

for c in awk bash cat cp date find getent grep head id ls make mktemp modinfo readlink rm sed sort stat tail tr uname wc; do
    have "$c" || die "missing command: $c"
done

SCRATCH=""
INITRD_LIST=""
INITRD_EXTRACT=""
INITRD_REQUEST_HITS=""
cleanup(){
    if [[ -n "${SCRATCH:-}" && -d "$SCRATCH" ]]; then
        rm -rf -- "$SCRATCH"
    fi
    if [[ -n "${INITRD_LIST:-}" && -f "$INITRD_LIST" ]]; then
        rm -f -- "$INITRD_LIST"
    fi
    if [[ -n "${INITRD_REQUEST_HITS:-}" && -f "$INITRD_REQUEST_HITS" ]]; then
        rm -f -- "$INITRD_REQUEST_HITS"
    fi
    if [[ -n "${INITRD_EXTRACT:-}" && -d "$INITRD_EXTRACT" ]]; then
        rm -rf -- "$INITRD_EXTRACT"
    fi
}
trap cleanup EXIT INT TERM

cfg_val(){
    local cfg="$1" sym="$2"
    if [[ -r "$cfg" ]]; then
        grep -E "^(CONFIG_${sym}=|# CONFIG_${sym} is not set)" "$cfg" | tail -n1 || true
    else
        printf 'CONFIG_FILE_MISSING=%s\n' "$cfg"
    fi
}

module_field(){
    local module="$1" field="$2"
    modinfo -k "$NORMAL_KERNEL" -F "$field" "$module" 2>&1 || true
}

module_metadata(){
    local module="$1" f
    section "normal-kernel modinfo: $module"
    say "normal_kernel=$NORMAL_KERNEL"
    for f in filename vermagic depends srcversion parm; do
        say "--- field=$f"
        module_field "$module" "$f"
    done
    say "--- full modinfo"
    modinfo -k "$NORMAL_KERNEL" "$module" 2>&1 || true

    local path
    path="$(module_field "$module" filename | tail -n1)"
    if [[ -n "$path" && "$path" == /* && -e "$path" ]]; then
        say "module_file=$path"
        stat "$path" 2>&1 || true
        if have sha256sum; then sha256sum "$path" 2>&1 || true; fi
        if have file; then file "$path" 2>&1 || true; fi
        if have dpkg-query; then
            say "--- dpkg owner of module file"
            dpkg-query -S "$path" 2>&1 || true
        fi
    else
        say "module_file_resolved=false"
    fi
}

scan_request_origins(){
    local name="$1"
    section "request-origin scan: $name"

    say "--- exact/common request files"
    local f
    for f in "${REQUEST_FILES[@]}"; do
        if [[ -r "$f" ]] && grep -nF -- "$name" "$f" >/dev/null 2>&1; then
            say "REQUEST_HIT=$f"
            grep -nF -- "$name" "$f" || true
        fi
    done

    say "--- request/config trees"
    local d
    for d in "${REQUEST_DIRS[@]}"; do
        [[ -d "$d" ]] || continue
        grep -RInI \
            --exclude='*.bin' --exclude='*.mbn' --exclude='*.elf' --exclude='*.ko' \
            --exclude='*.zst' --exclude='*.xz' --exclude='*.gz' \
            -- "$name" "$d" 2>/dev/null || true
    done

    if [[ -d /etc/systemd/system || -d /usr/lib/systemd/system ]]; then
        say "--- systemd unit references"
        grep -RInI -- "$name" /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system 2>/dev/null || true
    fi
}

scan_source_provenance(){
    local name="$1"
    section "source/package provenance: $name"

    say "--- filename hits under source/package locations"
    local roots=(/usr/src /var/lib/dkms /usr/local/src /opt "$OWNER_HOME/Downloads")
    local root
    for root in "${roots[@]}"; do
        [[ -e "$root" ]] || continue
        find "$root" -xdev \
            \( -type f -o -type l -o -type d \) \
            \( -iname "*${name}*" -o -iname "*${name//_/-}*" \) \
            -printf '%y %p -> %l\n' 2>/dev/null | head -n 500 || true
    done

    say "--- textual source/config hits under focused locations"
    local text_roots=()
    for root in /usr/src /var/lib/dkms /usr/local/src /opt "$OWNER_HOME/Downloads"; do
        [[ -d "$root" ]] && text_roots+=("$root")
    done
    if ((${#text_roots[@]})); then
        grep -RInI \
            --exclude-dir=.git --exclude-dir=.cache --exclude-dir=node_modules \
            --exclude='*.o' --exclude='*.a' --exclude='*.ko' --exclude='*.zst' \
            --exclude='*.bin' --exclude='*.mbn' --exclude='*.elf' --exclude='*.img' \
            -- "$name" "${text_roots[@]}" 2>/dev/null | head -n 1000 || true
    fi

    say "--- root-filesystem filename scan (-xdev; volatile/system mounts pruned)"
    if have timeout; then
        timeout 90s find / -xdev \
            \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /tmp -o -path /mnt -o -path /media -o -path /snap \) -prune -o \
            \( -type f -o -type l \) \
            \( -iname "*${name}*" -o -iname "*${name//_/-}*" \) \
            -printf '%y %p -> %l\n' 2>/dev/null | head -n 1000 || true
    else
        find / -xdev \
            \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /tmp -o -path /mnt -o -path /media -o -path /snap \) -prune -o \
            \( -type f -o -type l \) \
            \( -iname "*${name}*" -o -iname "*${name//_/-}*" \) \
            -printf '%y %p -> %l\n' 2>/dev/null | head -n 1000 || true
    fi
}

locate_root11_initrd(){
    if [[ -r "$ROOT11_INITRD" ]]; then
        printf '%s\n' "$ROOT11_INITRD"
        return 0
    fi
    local candidate
    candidate="$(find /boot -maxdepth 1 -type f \( -name 'initrd*root11*' -o -name 'initramfs*root11*' \) -print 2>/dev/null | sort | head -n1)"
    [[ -n "$candidate" ]] && printf '%s\n' "$candidate"
}

capture_initrd_listing(){
    section "ROOT11 initramfs listing"
    local initrd
    initrd="$(locate_root11_initrd || true)"
    if [[ -z "$initrd" ]]; then
        say "root11_initrd_found=false"
        say "requested_root11_initrd=$ROOT11_INITRD"
        return 0
    fi
    say "root11_initrd=$initrd"
    if ! have lsinitramfs; then
        say "lsinitramfs_available=false"
        return 0
    fi

    INITRD_LIST="$(mktemp /tmp/a14-root13-initramfs.XXXXXX.txt)"
    lsinitramfs "$initrd" >"$INITRD_LIST" 2>&1 || true
    say "lsinitramfs_lines=$(wc -l <"$INITRD_LIST" 2>/dev/null || printf '0')"
    say "--- lsinitramfs filename/payload hits"
    grep -Ei 'hid_asus_ec|hm1092|qcom_cci_sync|leds_qcom_flash|modules-load|initramfs-tools/modules|dracut' "$INITRD_LIST" || true

    if have unmkinitramfs; then
        INITRD_EXTRACT="$(mktemp -d /tmp/a14-root13-unmkinitramfs.XXXXXX)"
        INITRD_REQUEST_HITS="$(mktemp /tmp/a14-root13-initrd-request-hits.XXXXXX.txt)"
        say "--- temporary initramfs extraction for request-content audit"
        say "initramfs_extract_persistent_mutation=false"
        if unmkinitramfs "$initrd" "$INITRD_EXTRACT" >/dev/null 2>&1; then
            grep -RInI \
                --exclude='*.ko' --exclude='*.zst' --exclude='*.bin' --exclude='*.mbn' --exclude='*.elf' \
                -E 'hid_asus_ec|hm1092|qcom_cci_sync|leds_qcom_flash' \
                "$INITRD_EXTRACT" 2>/dev/null | sort >"$INITRD_REQUEST_HITS" || true
            if [[ -s "$INITRD_REQUEST_HITS" ]]; then
                cat "$INITRD_REQUEST_HITS"
            else
                say "initramfs_request_content_hits=none"
            fi
        else
            say "unmkinitramfs_failed=true"
        fi
    else
        say "unmkinitramfs_available=false"
    fi
}

request_classification(){
    local name="$1" host_hit=0 initrd_hit=0
    local f d

    for f in "${REQUEST_FILES[@]}"; do
        if [[ -r "$f" ]] && grep -Fq -- "$name" "$f" 2>/dev/null; then host_hit=1; fi
    done
    for d in /etc/modules-load.d /usr/lib/modules-load.d /lib/modules-load.d /etc/initramfs-tools /etc/dracut.conf.d; do
        if [[ -d "$d" ]] && grep -RIFq -- "$name" "$d" 2>/dev/null; then host_hit=1; fi
    done
    if [[ -n "$INITRD_REQUEST_HITS" && -r "$INITRD_REQUEST_HITS" ]] && grep -Fiq -- "$name" "$INITRD_REQUEST_HITS"; then initrd_hit=1; fi

    if (( host_hit && initrd_hit )); then
        say "${name}_request_class=HOST_AND_INITRAMFS"
    elif (( host_hit )); then
        say "${name}_request_class=HOST_CONFIG_ONLY_OR_NOT_EMBEDDED"
    elif (( initrd_hit )); then
        say "${name}_request_class=INITRAMFS_ONLY"
    else
        say "${name}_request_class=NOT_FOUND_IN_SCANNED_REQUEST_OR_INITRAMFS_PATHS"
    fi
}

kconfig_leds_test(){
    section "Kconfig-only test: CONFIG_LEDS_QCOM_FLASH=y"
    say "kconfig_test_persistent_mutation=false"
    say "kconfig_test_kernel_build=false"
    say "kconfig_test_module_build=false"

    if [[ ! -d "$SRC" || ! -f "$SRC/Makefile" ]]; then
        say "A14_ACPI_ROOT13_LEDS_QCOM_FLASH_Y_TEST=SKIP_SOURCE_MISSING"
        return 0
    fi
    if [[ ! -r "$ROOT11_CONFIG" ]]; then
        say "A14_ACPI_ROOT13_LEDS_QCOM_FLASH_Y_TEST=SKIP_ROOT11_CONFIG_MISSING"
        return 0
    fi
    if [[ ! -x "$SRC/scripts/config" ]]; then
        say "A14_ACPI_ROOT13_LEDS_QCOM_FLASH_Y_TEST=SKIP_SCRIPTS_CONFIG_MISSING"
        return 0
    fi

    SCRATCH="$(mktemp -d /tmp/a14-root13-kconfig.XXXXXX)"
    cp -- "$ROOT11_CONFIG" "$SCRATCH/.config"
    "$SRC/scripts/config" --file "$SCRATCH/.config" --enable LEDS_QCOM_FLASH
    say "requested_before_olddefconfig=$(cfg_val "$SCRATCH/.config" LEDS_QCOM_FLASH)"

    local make_log="$SCRATCH/olddefconfig.log"
    if make -s -C "$SRC" O="$SCRATCH" ARCH="$ARCH_NAME" olddefconfig >"$make_log" 2>&1; then
        say "olddefconfig_exit=0"
    else
        local rc=$?
        say "olddefconfig_exit=$rc"
        sed -n '1,240p' "$make_log" || true
        say "A14_ACPI_ROOT13_LEDS_QCOM_FLASH_Y_TEST=FAIL_OLDDEFCONFIG"
        return 0
    fi

    sed -n '1,120p' "$make_log" || true
    local result
    result="$(cfg_val "$SCRATCH/.config" LEDS_QCOM_FLASH)"
    say "result_after_olddefconfig=$result"

    say "--- direct LEDS_QCOM_FLASH Kconfig context"
    grep -RIn -A14 -B4 --include='Kconfig*' 'config LEDS_QCOM_FLASH' "$SRC/drivers" 2>/dev/null || true

    say "--- dependency symbol values referenced by common qcom flash LED stack"
    for sym in LEDS_CLASS_FLASH LEDS_CLASS MULTICOLOR LEDS_QCOM_FLASH REGMAP SPMI I2C OF ACPI; do
        say "$sym=$(cfg_val "$SCRATCH/.config" "$sym")"
    done

    if [[ "$result" == 'CONFIG_LEDS_QCOM_FLASH=y' ]]; then
        say "A14_ACPI_ROOT13_LEDS_QCOM_FLASH_Y_TEST=PASS"
    else
        say "A14_ACPI_ROOT13_LEDS_QCOM_FLASH_Y_TEST=FAIL_SYMBOL_NOT_Y"
    fi
}

audit(){
    {
        say "A14_ACPI_ROOT13_OUTOFTREE_MODULE_AUDIT_ENTERED=1"
        say "timestamp=$(date -Is)"
        say "running_kernel=$(uname -r)"
        say "owner=$OWNER"
        say "owner_home=$OWNER_HOME"
        say "normal_kernel=$NORMAL_KERNEL"
        say "src=$SRC"
        say "out=$OUT"
        say "root11_config=$ROOT11_CONFIG"
        say "root11_initrd_requested=$ROOT11_INITRD"
        say "persistent_mutations=report_only"
        say "temporary_kconfig_scratch=true"
        say "kernel_build=false"
        say "module_build=false"
        say "module_install=false"
        say "initramfs_update=false"
        say "grub_write=false"
        say "service_mutation=false"
        say "reboot_performed=false"

        section "DKMS status"
        if have dkms; then
            dkms status 2>&1 || true
        else
            say "dkms_available=false"
        fi

        section "/usr/src inventory"
        if [[ -d /usr/src ]]; then
            find /usr/src -maxdepth 3 -mindepth 1 -printf '%y %p -> %l\n' 2>/dev/null | sort
        else
            say "/usr/src missing"
        fi

        section "/var/lib/dkms inventory"
        if [[ -d /var/lib/dkms ]]; then
            find /var/lib/dkms -maxdepth 5 -mindepth 1 -printf '%y %p -> %l\n' 2>/dev/null | sort | head -n 3000 || true
        else
            say "/var/lib/dkms missing"
        fi

        section "DKMS config files"
        local dkms_root
        for dkms_root in /usr/src /var/lib/dkms; do
            [[ -d "$dkms_root" ]] || continue
            find "$dkms_root" -xdev -type f -name dkms.conf -print 2>/dev/null | sort | while read -r f; do
                show_file "$f"
            done
        done

        section "installed package names matching targets"
        if have dpkg-query; then
            dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' 2>/dev/null \
                | grep -Ei 'asus|zenbook|hm1092|cci|camera|qcom|dkms' \
                | sort || true
        else
            say "dpkg-query_available=false"
        fi

        section "required request/config file contents"
        local f
        for f in "${REQUEST_FILES[@]}"; do show_file "$f"; done

        section "dracut config discovery"
        if [[ -d /etc/dracut.conf.d ]]; then
            find /etc/dracut.conf.d -maxdepth 1 -type f -print 2>/dev/null | sort | while read -r f; do show_file "$f"; done
        else
            say "/etc/dracut.conf.d missing"
        fi

        section "normal-kernel module metadata"
        module_metadata hid_asus_ec
        module_metadata hm1092
        section "normal-kernel negative/control metadata"
        module_metadata qcom_cci_sync
        module_metadata leds_qcom_flash

        section "focused out-of-tree source provenance"
        local name
        for name in "${OOT_TARGETS[@]}"; do scan_source_provenance "$name"; done

        section "request origins"
        for name in "${TARGETS[@]}"; do scan_request_origins "$name"; done

        capture_initrd_listing

        section "request classification summary"
        for name in "${TARGETS[@]}"; do request_classification "$name"; done

        kconfig_leds_test

        section "ROOT13 summary markers"
        say "A14_ACPI_ROOT13_HID_ASUS_EC_AUDITED=1"
        say "A14_ACPI_ROOT13_HM1092_AUDITED=1"
        say "A14_ACPI_ROOT13_QCOM_CCI_SYNC_AUDITED=1"
        say "A14_ACPI_ROOT13_LEDS_QCOM_FLASH_AUDITED=1"
        say "A14_ACPI_ROOT13_OUTOFTREE_MODULE_AUDIT=PASS"
        say "persistent_mutations=report_only"
        say "kernel_build=false"
        say "module_build=false"
        say "initramfs_update=false"
        say "grub_write=false"
        say "service_mutation=false"
        say "reboot_performed=false"
    } >"$REPORT" 2>&1

    cleanup
    SCRATCH=""
    INITRD_LIST=""
    INITRD_EXTRACT=""
    INITRD_REQUEST_HITS=""

    chown "$OWNER:$OWNER" "$REPORT" 2>/dev/null || true
    say "A14_ACPI_ROOT13_OUTOFTREE_MODULE_AUDIT=PASS"
    say "report=$REPORT"
    say "persistent_mutations=report_only"
    say "reboot_performed=false"
}

audit
