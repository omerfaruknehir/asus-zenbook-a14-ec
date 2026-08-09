#!/usr/bin/env bash
set -euo pipefail

# Read-only evidence collector for the remaining Windows CAMP F0 GPIO dependency.
#
# Safety boundary:
#   - no GPIO direction/value/config writes
#   - no sysfs/debugfs writes
#   - no driver bind/unbind or module load/unload
#   - no CPAS MMIO, /dev/mem, ioremap/readl/writel
#   - no SSC/AOS activation
#   - no debugfs mount; if debugfs is unavailable, report that fact
#
# Windows CAMP_RES_QRD.bin contains TLMM GPIO resources 96..106 in F0.
# GPIOs 101..106 are explicitly unwound in the F1 resource block; 96..100 are
# configured in F0 but are not present in that F1 unwind block. This script only
# identifies the corresponding live Linux pin ownership/configuration.

readonly TARGET_PINS_RE='(^|[^0-9])(96|97|98|99|100|101|102|103|104|105|106)([^0-9]|$)'
readonly TARGET_GPIO_NAMES_RE='gpio(96|97|98|99|100|101|102|103|104|105|106)([^0-9]|$)'
readonly OUT_DEFAULT="${HOME}/Downloads/a14-aos-stage-d-gpio-audit.txt"
OUT="${1:-${OUT_DEFAULT}}"
TMPDIR_AUDIT="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_AUDIT}"' EXIT

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'missing required command: %s\n' "$1" >&2
        exit 1
    }
}

for cmd in awk cat date find grep id mktemp od sed sort tr uname; do
    need_cmd "$cmd"
done

mkdir -p "$(dirname "$OUT")"
: >"$OUT"

log() {
    printf '%s\n' "$*" | tee -a "$OUT"
}

section() {
    printf '\n===== %s =====\n' "$*" | tee -a "$OUT"
}

snapshot_privileged() {
    local src="$1"
    local dst="$2"

    if [[ -r "$src" ]]; then
        cat "$src" >"$dst"
        return 0
    fi

    if command -v sudo >/dev/null 2>&1 && sudo cat "$src" >"$dst"; then
        return 0
    fi

    return 1
}

filter_target_pin_lines() {
    local src="$1"
    awk -v re="$TARGET_PINS_RE" '$0 ~ re { print }' "$src"
}

filter_target_gpio_name_lines() {
    local src="$1"
    awk -v re="$TARGET_GPIO_NAMES_RE" '$0 ~ re { print }' "$src"
}

section "IDENTITY"
log "collected_at=$(date --iso-8601=ns)"
log "uid=$(id -u)"
log "kernel=$(uname -r)"
log "boot_id=$(cat /proc/sys/kernel/random/boot_id)"
log "cmdline=$(cat /proc/cmdline)"

boot_markers="$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^a14_aos_.*_test=/) print $i }' /proc/cmdline | sort -u)"
if [[ -n "$boot_markers" ]]; then
    log "boot_scope=custom-diagnostic"
    while IFS= read -r marker; do
        [[ -n "$marker" ]] && log "boot_marker=$marker"
    done <<<"$boot_markers"
else
    log "boot_scope=normal-no-a14-test-marker"
fi

section "WINDOWS CAMP F0 TARGET"
log "windows_source=CAMP_RES_QRD.bin"
log "windows_f0_tlmm_gpio_set=96,97,98,99,100,101,102,103,104,105,106"
log "windows_f1_explicit_gpio_unwind=101,102,103,104,105,106"
log "windows_f0_gpio_not_in_f1_unwind=96,97,98,99,100"
log "hardware_write=false"
log "direct_cpas_mmio=false"
log "ssc_contacted=false"

section "DEBUGFS AVAILABILITY"
if [[ -d /sys/kernel/debug/pinctrl ]]; then
    log "debugfs_pinctrl=present"
else
    log "debugfs_pinctrl=absent"
fi

if [[ -e /sys/kernel/debug/gpio ]]; then
    log "debugfs_gpio=present"
else
    log "debugfs_gpio=absent"
fi

section "PINCTRL PIN OWNERSHIP"
found_pinctrl=0
if [[ -d /sys/kernel/debug/pinctrl ]]; then
    while IFS= read -r file; do
        snap="${TMPDIR_AUDIT}/$(printf '%s' "$file" | tr '/ ' '__')"
        if snapshot_privileged "$file" "$snap"; then
            matches="$(filter_target_pin_lines "$snap" || true)"
            if [[ -n "$matches" ]]; then
                found_pinctrl=1
                log "source=$file"
                printf '%s\n' "$matches" | tee -a "$OUT"
            fi
        else
            log "unreadable=$file"
        fi
    done < <(find /sys/kernel/debug/pinctrl -maxdepth 2 -type f \( -name pins -o -name pinmux-pins -o -name pinconf-pins -o -name gpio-ranges \) -print | sort)
fi
[[ "$found_pinctrl" -eq 1 ]] || log "target_pin_lines=none-or-unavailable"

section "GPIO CONSUMER SNAPSHOT"
if [[ -e /sys/kernel/debug/gpio ]]; then
    gpio_snap="${TMPDIR_AUDIT}/debugfs-gpio.txt"
    if snapshot_privileged /sys/kernel/debug/gpio "$gpio_snap"; then
        matches="$(filter_target_pin_lines "$gpio_snap" || true)"
        if [[ -n "$matches" ]]; then
            printf '%s\n' "$matches" | tee -a "$OUT"
        else
            log "numeric_target_gpio_lines=none"
        fi
    else
        log "debugfs_gpio=unreadable"
    fi
fi

if command -v gpioinfo >/dev/null 2>&1; then
    section "GPIOINFO"
    gpioinfo_snap="${TMPDIR_AUDIT}/gpioinfo.txt"
    if gpioinfo >"$gpioinfo_snap" 2>&1; then
        matches="$(filter_target_pin_lines "$gpioinfo_snap" || true)"
        if [[ -n "$matches" ]]; then
            printf '%s\n' "$matches" | tee -a "$OUT"
        else
            log "numeric_target_gpio_lines=none"
        fi
    else
        log "gpioinfo_status=failed"
        cat "$gpioinfo_snap" | tee -a "$OUT"
    fi
else
    section "GPIOINFO"
    log "gpioinfo=not-installed"
fi

section "LIVE DEVICE TREE REFERENCES"
if command -v dtc >/dev/null 2>&1 && [[ -d /sys/firmware/devicetree/base ]]; then
    live_dts="${TMPDIR_AUDIT}/live.dts"
    dtc_err="${TMPDIR_AUDIT}/dtc.err"
    if dtc -I fs -O dts -o "$live_dts" /sys/firmware/devicetree/base 2>"$dtc_err"; then
        log "dtc_status=ok"
        matches="$(filter_target_gpio_name_lines "$live_dts" || true)"
        if [[ -n "$matches" ]]; then
            printf '%s\n' "$matches" | tee -a "$OUT"
        else
            log "named_gpio96_to_gpio106_references=none"
        fi

        # Include camera reset GPIO properties verbatim from the decompiled tree.
        awk '
            /camera@24[[:space:]]*\{/ { in_cam=1; depth=0; label="camera@24" }
            /camera@36[[:space:]]*\{/ { in_cam=1; depth=0; label="camera@36" }
            in_cam {
                opens=gsub(/\{/, "{")
                closes=gsub(/\}/, "}")
                depth += opens - closes
                if ($0 ~ /reset-gpios|enable-gpios|pwdn-gpios|powerdown-gpios|pinctrl-/) print label ": " $0
                if (depth <= 0) in_cam=0
            }
        ' "$live_dts" | tee -a "$OUT"
    else
        log "dtc_status=failed"
        cat "$dtc_err" | tee -a "$OUT"
    fi
else
    log "dtc_status=unavailable"
fi

section "CAMERA NODE RAW GPIO PROPERTIES"
for node in \
    /sys/firmware/devicetree/base/soc@0/cci@ac15000/i2c-bus@0/camera@24 \
    /sys/firmware/devicetree/base/soc@0/cci@ac16000/i2c-bus@1/camera@36; do
    if [[ ! -d "$node" ]]; then
        log "camera_node_missing=$node"
        continue
    fi
    log "camera_node=$node"
    for prop in reset-gpios enable-gpios pwdn-gpios powerdown-gpios; do
        if [[ -f "$node/$prop" ]]; then
            printf '%s=' "$prop" | tee -a "$OUT"
            od -An -tx4 -v "$node/$prop" | tr -s ' ' | sed 's/^ //' | tee -a "$OUT"
        fi
    done
done

section "RESULT"
log "result=read-only-gpio-ownership-audit-complete"
log "report=$OUT"
log "hardware_write=false"
log "direct_cpas_mmio=false"
log "ssc_contacted=false"
