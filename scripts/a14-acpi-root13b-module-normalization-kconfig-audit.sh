#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# ACPI ROOT13B: corrected read-only module-request normalization and
# Kconfig dependency audit for LEDS_QCOM_FLASH=y.
#
# Safety invariants:
#   - no kernel/Image build
#   - no module build/install
#   - no initramfs build/update
#   - no GRUB writes
#   - no service mutation
#   - no reboot
#
# Persistent write: only ~/Downloads/a14-acpi-root13b-module-kconfig-audit.txt
# Temporary writes are confined to /tmp and removed automatically.
set -euo pipefail

ACTION="${1:-audit}"
OWNER="${SUDO_USER:-}"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
section(){ printf '\n===== %s =====\n' "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }

[[ "$ACTION" == audit ]] || die "usage: $0 [audit]"
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"
[[ -n "$OWNER" && "$OWNER" != root ]] || die "run with sudo from your normal login"

OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
[[ -d "$OWNER_HOME" ]] || die "cannot resolve owner home"

WORK="${A14_74C9_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="${A14_KERNEL_SRC:-$WORK/linux-7.1.5}"
ROOT11_CONFIG="${A14_ROOT11_CONFIG:-/boot/config-7.1.5-a14-acpi-root11}"
ROOT11_INITRD="${A14_ROOT11_INITRD:-/boot/initrd.img-7.1.5-a14-acpi-root11}"
NORMAL_KERNEL="${A14_NORMAL_KERNEL:-7.1.5-070105-generic}"
ARCH_NAME="${A14_ARCH:-arm64}"
REPORT="$OWNER_HOME/Downloads/a14-acpi-root13b-module-kconfig-audit.txt"
TARGETS=(hid_asus_ec hm1092 qcom_cci_sync leds_qcom_flash)
REQUEST_FILES=(
    /etc/modules
    /etc/modules-load.d/asus-zenbook-a14-ec.conf
    /etc/modules-load.d/hm1092-cci-sync.conf
    /etc/modules-load.d/hm1092-ir-v6.conf
    /etc/initramfs-tools/modules
)
REQUEST_DIRS=(
    /etc/modules-load.d
    /usr/lib/modules-load.d
    /lib/modules-load.d
    /etc/initramfs-tools
    /etc/dracut.conf.d
)

for c in bash cat cp date find getent grep head id make mkdir mktemp modinfo rm sed sort tail uname wc; do
    have "$c" || die "missing command: $c"
done

SCRATCH=""
INITRD_EXTRACT=""
INITRD_HITS=""
cleanup(){
    [[ -n "${SCRATCH:-}" && -d "$SCRATCH" ]] && rm -rf -- "$SCRATCH"
    [[ -n "${INITRD_EXTRACT:-}" && -d "$INITRD_EXTRACT" ]] && rm -rf -- "$INITRD_EXTRACT"
    [[ -n "${INITRD_HITS:-}" && -f "$INITRD_HITS" ]] && rm -f -- "$INITRD_HITS"
}
finalize(){
    cleanup
    [[ -f "$REPORT" ]] && chown "$OWNER:$OWNER" "$REPORT" 2>/dev/null || true
}
trap finalize EXIT INT TERM

module_pattern(){
    case "$1" in
        hid_asus_ec)     printf '%s\n' 'hid[-_]asus[-_]ec' ;;
        hm1092)          printf '%s\n' 'hm1092' ;;
        qcom_cci_sync)   printf '%s\n' 'qcom[-_]cci[-_]sync' ;;
        leds_qcom_flash) printf '%s\n' 'leds[-_]qcom[-_]flash' ;;
        *) die "unknown module target: $1" ;;
    esac
}

cfg_val(){
    local cfg="$1" sym="$2"
    if [[ -r "$cfg" ]]; then
        grep -E "^(CONFIG_${sym}=|# CONFIG_${sym} is not set)" "$cfg" | tail -n1 || true
    else
        printf 'CONFIG_FILE_MISSING=%s\n' "$cfg"
    fi
}

scan_host_request(){
    local name="$1" re f d
    re="$(module_pattern "$name")"
    for f in "${REQUEST_FILES[@]}"; do
        if [[ -r "$f" ]] && grep -Eiq -- "$re" "$f"; then
            say "HOST_REQUEST_HIT=$f"
            grep -Ein -- "$re" "$f" || true
        fi
    done
    for d in "${REQUEST_DIRS[@]}"; do
        [[ -d "$d" ]] || continue
        grep -RInIE --exclude='*.ko' --exclude='*.zst' -- "$re" "$d" 2>/dev/null || true
    done
}

extract_initrd_requests(){
    section "ROOT11 initramfs normalized-name request audit"
    if [[ ! -r "$ROOT11_INITRD" ]]; then
        say "root11_initrd_missing=$ROOT11_INITRD"
        return 0
    fi
    if ! have unmkinitramfs; then
        say "unmkinitramfs_available=false"
        return 0
    fi

    INITRD_EXTRACT="$(mktemp -d /tmp/a14-root13b-initrd.XXXXXX)"
    INITRD_HITS="$(mktemp /tmp/a14-root13b-initrd-hits.XXXXXX.txt)"
    say "root11_initrd=$ROOT11_INITRD"
    say "initramfs_extract_persistent_mutation=false"

    if ! unmkinitramfs "$ROOT11_INITRD" "$INITRD_EXTRACT" >/dev/null 2>&1; then
        say "unmkinitramfs_failed=true"
        return 0
    fi

    grep -RInI \
        --exclude='*.ko' --exclude='*.zst' --exclude='*.bin' --exclude='*.mbn' --exclude='*.elf' \
        -E 'hid[-_]asus[-_]ec|hm1092|qcom[-_]cci[-_]sync|leds[-_]qcom[-_]flash' \
        "$INITRD_EXTRACT" 2>/dev/null | sort >"$INITRD_HITS" || true

    if [[ -s "$INITRD_HITS" ]]; then
        cat "$INITRD_HITS"
    else
        say "initramfs_request_content_hits=none"
    fi
}

classify_request(){
    local name="$1" re host=0 initrd=0 f d
    re="$(module_pattern "$name")"
    for f in "${REQUEST_FILES[@]}"; do
        [[ -r "$f" ]] && grep -Eiq -- "$re" "$f" && host=1 || true
    done
    for d in "${REQUEST_DIRS[@]}"; do
        [[ -d "$d" ]] && grep -RIIEq --exclude='*.ko' --exclude='*.zst' -- "$re" "$d" 2>/dev/null && host=1 || true
    done
    if [[ -n "$INITRD_HITS" && -s "$INITRD_HITS" ]] && grep -Eiq -- "$re" "$INITRD_HITS"; then
        initrd=1
    fi

    if (( host && initrd )); then
        say "${name}_normalized_request_class=HOST_AND_INITRAMFS"
    elif (( host )); then
        say "${name}_normalized_request_class=HOST_CONFIG_ONLY_OR_NOT_EMBEDDED"
    elif (( initrd )); then
        say "${name}_normalized_request_class=INITRAMFS_ONLY"
    else
        say "${name}_normalized_request_class=NOT_FOUND"
    fi
}

show_key_config(){
    local cfg="$1" sym
    for sym in \
        SPMI SPMI_MSM_PMIC_ARB MFD_SPMI_PMIC \
        LEDS_CLASS LEDS_CLASS_FLASH LEDS_QCOM_FLASH \
        MEDIA_SUPPORT MEDIA_CONTROLLER VIDEO_DEV VIDEO_V4L2 \
        V4L2_FLASH_LED_CLASS REGMAP OF ACPI; do
        say "$sym=$(cfg_val "$cfg" "$sym")"
    done
}

apply_config_op(){
    local cfg="$1" spec="$2" sym state
    sym="${spec%%=*}"
    state="${spec#*=}"
    case "$state" in
        y) "$SRC/scripts/config" --file "$cfg" --enable "$sym" ;;
        m) "$SRC/scripts/config" --file "$cfg" --module "$sym" ;;
        n) "$SRC/scripts/config" --file "$cfg" --disable "$sym" ;;
        *) die "bad config state in $spec" ;;
    esac
}

kconfig_case(){
    local label="$1"; shift
    local dir="$SCRATCH/$label" cfg log spec flash
    mkdir -p "$dir"
    cfg="$dir/.config"
    log="$dir/olddefconfig.log"
    cp -- "$ROOT11_CONFIG" "$cfg"

    section "Kconfig matrix case: $label"
    say "requested_ops=$*"
    for spec in "$@"; do apply_config_op "$cfg" "$spec"; done

    if make -s -C "$SRC" O="$dir" ARCH="$ARCH_NAME" olddefconfig >"$log" 2>&1; then
        say "olddefconfig_exit=0"
    else
        local rc=$?
        say "olddefconfig_exit=$rc"
        sed -n '1,160p' "$log" || true
        say "${label}_result=FAIL_OLDDEFCONFIG"
        return 0
    fi

    show_key_config "$cfg"
    flash="$(cfg_val "$cfg" LEDS_QCOM_FLASH)"
    if [[ "$flash" == 'CONFIG_LEDS_QCOM_FLASH=y' ]]; then
        say "${label}_result=FLASH_Y"
    else
        say "${label}_result=FLASH_NOT_Y"
    fi
}

source_provenance_focus(){
    section "focused source provenance"
    say "--- hid_asus_ec DKMS/source"
    local p root hm
    for p in /usr/src/asus-zenbook-a14-ec-* /var/lib/dkms/asus-zenbook-a14-ec; do
        [[ -e "$p" ]] || continue
        find "$p" -xdev -maxdepth 6 -type f \
            \( -name 'hid_asus_ec.c' -o -name 'asus_zenbook_a14_ec.c' -o -name 'dkms.conf' -o -name 'Kbuild' \) \
            -print 2>/dev/null | sort || true
    done

    say "--- HM1092 / qcom-cci-sync source candidates under home"
    for root in \
        "$OWNER_HOME/hm1092-bringup" \
        "$OWNER_HOME/hm1092-v6.3-source-bundle" \
        "$OWNER_HOME/Downloads/hm1092-ir-v6.4-repair"; do
        [[ -d "$root" ]] || continue
        find "$root" -xdev -type f \
            \( -iname 'hm1092.c' -o -iname 'qcom-cci-sync.c' -o -iname 'qcom_cci_sync.c' -o -name 'Makefile' -o -name 'Kbuild' \) \
            -print 2>/dev/null | sort | head -n 500 || true
    done

    say "--- installed hm1092 debug compilation-directory hints"
    hm="$(modinfo -k "$NORMAL_KERNEL" -F filename hm1092 2>/dev/null | tail -n1 || true)"
    say "hm1092_module=$hm"
    if [[ "$hm" == /* && -r "$hm" ]] && have readelf; then
        readelf --debug-dump=info "$hm" 2>/dev/null \
            | grep -E 'DW_AT_(comp_dir|name)' \
            | grep -Ei 'hm1092|bringup|linux|/home/|drivers/media' \
            | head -n 120 || true
    fi
}

audit(){
    {
        say "A14_ACPI_ROOT13B_ENTERED=1"
        say "timestamp=$(date -Is)"
        say "running_kernel=$(uname -r)"
        say "normal_kernel=$NORMAL_KERNEL"
        say "src=$SRC"
        say "root11_config=$ROOT11_CONFIG"
        say "root11_initrd=$ROOT11_INITRD"
        say "persistent_mutations=report_only"
        say "kernel_build=false"
        say "module_build=false"
        say "module_install=false"
        say "initramfs_update=false"
        say "grub_write=false"
        say "service_mutation=false"
        say "reboot_performed=false"

        section "normalized host request hits"
        local name
        for name in "${TARGETS[@]}"; do
            say "--- module=$name pattern=$(module_pattern "$name")"
            scan_host_request "$name"
        done

        extract_initrd_requests

        section "corrected normalized request classification"
        for name in "${TARGETS[@]}"; do classify_request "$name"; done

        source_provenance_focus

        section "ROOT11 key Kconfig baseline"
        if [[ -r "$ROOT11_CONFIG" ]]; then
            show_key_config "$ROOT11_CONFIG"
        else
            say "root11_config_missing=true"
        fi

        section "LEDS_QCOM_FLASH dependency Kconfig context"
        if [[ -d "$SRC" ]]; then
            grep -RIn -A14 -B4 --include='Kconfig*' 'config LEDS_QCOM_FLASH' "$SRC/drivers" 2>/dev/null || true
            say "--- MFD_SPMI_PMIC Kconfig"
            grep -RIn -A16 -B4 --include='Kconfig*' 'config MFD_SPMI_PMIC' "$SRC/drivers" 2>/dev/null || true
            say "--- V4L2_FLASH_LED_CLASS Kconfig"
            grep -RIn -A18 -B4 --include='Kconfig*' 'config V4L2_FLASH_LED_CLASS' "$SRC/drivers" 2>/dev/null || true
        fi

        if [[ -d "$SRC" && -f "$SRC/Makefile" && -x "$SRC/scripts/config" && -r "$ROOT11_CONFIG" ]]; then
            SCRATCH="$(mktemp -d /tmp/a14-root13b-kconfig.XXXXXX)"
            say "kconfig_scratch=$SCRATCH"
            say "kconfig_scratch_persistent=false"

            kconfig_case flash_only \
                LEDS_QCOM_FLASH=y

            kconfig_case pmic_chain \
                SPMI=y MFD_SPMI_PMIC=y LEDS_QCOM_FLASH=y

            kconfig_case pmic_plus_v4l2_builtin \
                SPMI=y MFD_SPMI_PMIC=y LEDS_CLASS_FLASH=y V4L2_FLASH_LED_CLASS=y LEDS_QCOM_FLASH=y

            kconfig_case pmic_plus_v4l2_disabled \
                SPMI=y MFD_SPMI_PMIC=y V4L2_FLASH_LED_CLASS=n LEDS_QCOM_FLASH=y
        else
            say "KCONFIG_MATRIX=SKIPPED_MISSING_SOURCE_OR_CONFIG"
        fi

        section "ROOT13B summary markers"
        say "A14_ACPI_ROOT13B_NORMALIZATION_AUDIT=PASS"
        say "A14_ACPI_ROOT13B_KCONFIG_MATRIX=COMPLETE"
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
    INITRD_EXTRACT=""
    INITRD_HITS=""
    chown "$OWNER:$OWNER" "$REPORT" 2>/dev/null || true

    say "A14_ACPI_ROOT13B_NORMALIZATION_AUDIT=PASS"
    say "report=$REPORT"
    say "persistent_mutations=report_only"
    say "reboot_performed=false"
}

audit
