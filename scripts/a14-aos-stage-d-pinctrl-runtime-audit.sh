#!/usr/bin/env bash
set -Eeuo pipefail

# Stage D runtime pinctrl ownership audit.
#
# This performs a temporary debugfs mount only when no usable debugfs pinctrl
# tree is already available. It reads pinctrl/gpio diagnostic files and then
# unmounts the temporary debugfs instance. It performs no GPIO/pinctrl writes,
# no camera operations, no clock/power operations, no CPAS access, and no SSC.

readonly OUT_DEFAULT="${HOME}/Downloads/a14-aos-stage-d-pinctrl-runtime-audit.txt"
OUT="${1:-${OUT_DEFAULT}}"
TMP_ROOT="$(mktemp -d -t a14-stage-d-pinctrl.XXXXXXXX)"
DBG_ROOT=""
MOUNTED_TEMP=0

cleanup() {
    local rc=$?
    if [[ "$MOUNTED_TEMP" -eq 1 && -n "$DBG_ROOT" ]]; then
        sudo umount "$DBG_ROOT" >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP_ROOT"
    exit "$rc"
}
trap cleanup EXIT INT TERM

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'missing required command: %s\n' "$1" >&2
        exit 1
    }
}

for cmd in awk cat date find grep id mktemp mkdir mount rm sed sort tee tr umount uname; do
    need_cmd "$cmd"
done
command -v sudo >/dev/null 2>&1 || { echo 'sudo is required for a temporary debugfs mount' >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
: >"$OUT"

log() {
    printf '%s\n' "$*" | tee -a "$OUT"
}

section() {
    printf '\n===== %s =====\n' "$*" | tee -a "$OUT"
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

section "SAFETY"
log "operation=read-only-runtime-pinctrl-audit"
log "hardware_write=false"
log "gpio_write=false"
log "pinctrl_write=false"
log "camera_state_change=false"
log "clock_state_change=false"
log "power_domain_state_change=false"
log "direct_cpas_mmio=false"
log "ssc_contacted=false"

section "DEBUGFS ACCESS"
if [[ -d /sys/kernel/debug/pinctrl ]] && find /sys/kernel/debug/pinctrl -mindepth 1 -maxdepth 2 -type f -print -quit 2>/dev/null | grep -q .; then
    DBG_ROOT=/sys/kernel/debug
    log "debugfs_source=existing:/sys/kernel/debug"
    log "temporary_debugfs_mount=false"
else
    DBG_ROOT="$TMP_ROOT/debugfs"
    mkdir -p "$DBG_ROOT"
    sudo mount -t debugfs debugfs "$DBG_ROOT"
    MOUNTED_TEMP=1
    log "debugfs_source=temporary:$DBG_ROOT"
    log "temporary_debugfs_mount=true"
fi

if [[ ! -d "$DBG_ROOT/pinctrl" ]]; then
    log "pinctrl_debugfs=unavailable"
    exit 1
fi
log "pinctrl_debugfs=available"

# Exact target pins. Match both common Qualcomm forms:
#   pin 96 (GPIO_96): ...
#   pin 96 (gpio96): ...
readonly PIN_RE='(^|[[:space:]])pin[[:space:]]+(96|97|98|99|100|101|102|103|104|105|106)([[:space:]]|$)|GPIO_(96|97|98|99|100|101|102|103|104|105|106)([^0-9]|$)|gpio(96|97|98|99|100|101|102|103|104|105|106)([^0-9]|$)'

section "PINCTRL PROVIDERS"
find "$DBG_ROOT/pinctrl" -mindepth 1 -maxdepth 1 -type d -print | sort | while IFS= read -r d; do
    log "provider=$d"
done

section "TARGET PIN MUX OWNERSHIP"
mux_hits=0
while IFS= read -r file; do
    [[ -r "$file" ]] || continue
    matches="$(grep -E "$PIN_RE" "$file" || true)"
    if [[ -n "$matches" ]]; then
        mux_hits=1
        log "source=$file"
        printf '%s\n' "$matches" | tee -a "$OUT"
    fi
done < <(find "$DBG_ROOT/pinctrl" -maxdepth 2 -type f -name pinmux-pins -print | sort)
[[ "$mux_hits" -eq 1 ]] || log "target_pinmux_lines=none"

section "TARGET PIN CONFIGURATION"
conf_hits=0
while IFS= read -r file; do
    [[ -r "$file" ]] || continue
    matches="$(grep -E "$PIN_RE" "$file" || true)"
    if [[ -n "$matches" ]]; then
        conf_hits=1
        log "source=$file"
        printf '%s\n' "$matches" | tee -a "$OUT"
    fi
done < <(find "$DBG_ROOT/pinctrl" -maxdepth 2 -type f \( -name pinconf-pins -o -name pins \) -print | sort)
[[ "$conf_hits" -eq 1 ]] || log "target_pinconf_lines=none"

section "GPIO DEBUG SNAPSHOT"
if [[ -r "$DBG_ROOT/gpio" ]]; then
    matches="$(grep -E '(^|[^0-9])(96|97|98|99|100|101|102|103|104|105|106)([^0-9]|$)' "$DBG_ROOT/gpio" || true)"
    if [[ -n "$matches" ]]; then
        printf '%s\n' "$matches" | tee -a "$OUT"
    else
        log "target_gpio_consumer_lines=none"
    fi
else
    log "debugfs_gpio=unavailable"
fi

section "RESULT"
log "result=read-only-runtime-pinctrl-audit-complete"
log "report=$OUT"
log "hardware_write=false"
log "gpio_write=false"
log "pinctrl_write=false"
log "direct_cpas_mmio=false"
log "ssc_contacted=false"
