#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# ACPI ROOT9: audit pd-mapper / QRTR map discovery after ROOT8 fixed AF_QIPCRTR.
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

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"
[[ -n "$OWNER" && "$OWNER" != root ]] || die "run with sudo from your normal login"
OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
[[ -d "$OWNER_HOME" ]] || die "cannot resolve owner home"

REPORT="$OWNER_HOME/Downloads/a14-acpi-root9-pdmap-audit.txt"
ROOT8_JOURNAL="$OWNER_HOME/Downloads/a14-acpi-root8-journal.txt"

for c in awk cat date find grep head journalctl ls sed sort strings systemctl tr uname wc; do need "$c"; done

section(){ printf '\n===== %s =====\n' "$*"; }
run(){
    printf '\n$ %s\n' "$*"
    "$@" 2>&1 || printf 'COMMAND_FAILED exit=%s: %s\n' "$?" "$*"
}

read_file(){
    local p="$1"
    if [[ -r "$p" ]]; then
        printf '%s=' "$p"
        tr '\0' '\n' <"$p" | sed '/^$/d' | head -n 20
    else
        printf '%s=UNREADABLE_OR_MISSING\n' "$p"
    fi
}

list_tree_limited(){
    local p="$1"
    local depth="${2:-3}"
    local limit="${3:-200}"
    if [[ -e "$p" ]]; then
        find "$p" -maxdepth "$depth" -printf '%y %p -> %l\n' 2>/dev/null | sort | head -n "$limit"
    else
        printf '%s=MISSING\n' "$p"
    fi
}

scan_pd_binary(){
    local bin
    bin="$(command -v pd-mapper 2>/dev/null || true)"
    if [[ -z "$bin" ]]; then
        say "pd_mapper_binary=MISSING"
        return 0
    fi
    say "pd_mapper_binary=$bin"
    run ls -l "$bin"
    if command -v file >/dev/null 2>&1; then run file "$bin"; fi
    if command -v sha256sum >/dev/null 2>&1; then run sha256sum "$bin"; fi
    section "pd-mapper strings: map/path/error hints"
    strings -a "$bin" | grep -Ei 'pd|map|json|jsn|firmware|remoteproc|compatible|qcom|servreg|no pd maps|failed to open|/lib|/usr|/etc' | sort -u | head -n 300 || true
}

scan_packages(){
    section "package ownership/listing hints"
    if command -v dpkg >/dev/null 2>&1; then
        if command -v pd-mapper >/dev/null 2>&1; then run dpkg -S "$(command -v pd-mapper)"; fi
        for pkg in protection-domain-mapper pd-mapper qrtr qrtr-ns qcom-firmware-extract firmware-qcom-soc qcom-firmware; do
            if dpkg -s "$pkg" >/dev/null 2>&1; then
                say "package_installed=$pkg"
                run dpkg -L "$pkg"
            else
                say "package_absent=$pkg"
            fi
        done
    else
        say "dpkg=missing"
    fi
}

scan_maps(){
    section "candidate PD map / JSON files"
    for base in /lib/firmware /lib/firmware/updates /usr/lib/firmware /usr/share /usr/local/share /etc; do
        if [[ -d "$base" ]]; then
            say "scan_base=$base"
            find "$base" \
                \( -path '*/qcom/*' -o -path '*/pd-mapper/*' -o -path '*/protection-domain*' -o -path '*/qrtr*' \) \
                \( -type f -o -type l \) \
                \( -iname '*.jsn' -o -iname '*.json' -o -iname '*pd*map*' -o -iname '*adsp*' -o -iname '*slpi*' -o -iname '*cdsp*' -o -iname '*modem*' \) \
                -printf '%p -> %l\n' 2>/dev/null | sort | head -n 400 || true
        else
            say "scan_base_missing=$base"
        fi
    done
}

scan_map_contents(){
    section "candidate .jsn/.json content previews"
    for base in /lib/firmware /lib/firmware/updates /usr/lib/firmware /usr/share /usr/local/share /etc; do
        [[ -d "$base" ]] || continue
        while IFS= read -r f; do
            say "--- $f"
            sed -n '1,120p' "$f" 2>/dev/null || true
        done < <(find "$base" \
            \( -path '*/qcom/*' -o -path '*/pd-mapper/*' -o -path '*/protection-domain*' -o -path '*/qrtr*' \) \
            -type f \( -iname '*.jsn' -o -iname '*.json' \) 2>/dev/null | sort | head -n 20)
    done
}

scan_firmware_identity(){
    section "firmware identity: DT and ACPI"
    read_file /sys/firmware/devicetree/base/compatible
    read_file /sys/firmware/devicetree/base/model
    run ls -l /sys/firmware || true
    run ls -l /sys/firmware/acpi || true
    run ls -l /sys/firmware/acpi/tables || true
    if [[ -r /sys/firmware/acpi/tables/DSDT ]]; then
        say "DSDT_strings_qcom_asus_excerpt_BEGIN"
        strings -a /sys/firmware/acpi/tables/DSDT | grep -Ei 'QCOM|ASUS|UX3407|ABD|SOSI|SCP|HAMOA|remote|adsp|slpi|cdsp|modem|servreg|qrtr' | sort -u | head -n 300 || true
        say "DSDT_strings_qcom_asus_excerpt_END"
    fi
}

scan_remoteproc_qrtr(){
    section "remoteproc / rpmsg / QRTR kernel state"
    list_tree_limited /sys/class/remoteproc 4 300
    for rp in /sys/class/remoteproc/remoteproc*; do
        [[ -e "$rp" ]] || continue
        say "--- remoteproc=$rp"
        for n in name state firmware coredump recovery; do read_file "$rp/$n"; done
        list_tree_limited "$rp" 2 120
    done
    list_tree_limited /sys/bus/rpmsg 4 300
    list_tree_limited /sys/kernel/debug/qrtr 4 300
    list_tree_limited /sys/kernel/debug/remoteproc 4 300
    if command -v lsmod >/dev/null 2>&1; then run lsmod; fi
    if command -v modinfo >/dev/null 2>&1; then
        for m in qrtr qrtr_smd qrtr_mhi qrtr_tun qcom_common qcom_q6v5_pas qcom_q6v5_mss qcom_sysmon qcom_glink_smem rpmsg_core rpmsg_ctrl rpmsg_char; do
            say "--- modinfo $m"
            modinfo "$m" 2>&1 || true
        done
    fi
}

scan_services(){
    section "systemd service state"
    for svc in qrtr-ns.service pd-mapper.service rmtfs.service tqftpserv.service a14-ssc-hexagonrpcd.service; do
        say "--- $svc"
        systemctl is-enabled "$svc" 2>&1 || true
        systemctl is-active "$svc" 2>&1 || true
        systemctl cat "$svc" 2>&1 || true
        systemctl status "$svc" --no-pager -l 2>&1 || true
    done
    section "current boot service journal"
    journalctl -b --no-pager -u qrtr-ns.service -u pd-mapper.service -u rmtfs.service -u tqftpserv.service -u a14-ssc-hexagonrpcd.service 2>&1 || true
}

scan_root8_journal(){
    section "ROOT8 journal high-signal excerpt"
    if [[ -r "$ROOT8_JOURNAL" ]]; then
        grep -E 'A14 ABD|A14 SOSI|GenericSerialBus|AE_SUPPORT|AF_QIPCRTR|qrtr|pd-mapper|remoteproc|rpmsg|servreg|module|modprobe|autofs4|i2c_dev|hid_asus_ec|leds_qcom_flash|i2c_qcom_cci|qcom_cci_sync|hm1092|Reached target|multi-user|login|getty|Failed|failed|qcom_scm|arm-smmu|QTEC0001|Keyboard' "$ROOT8_JOURNAL" | tail -400 || true
    else
        say "root8_journal_missing=$ROOT8_JOURNAL"
    fi
}

audit(){
    tmp="$(mktemp)"
    {
        say "A14_ACPI_ROOT9_PDMAP_AUDIT_ENTERED=1"
        say "timestamp=$(date --iso-8601=seconds 2>/dev/null || date)"
        say "running_kernel=$(uname -r)"
        say "cmdline=$(cat /proc/cmdline)"
        say "report=$REPORT"
        say "mutations=false"
        say "reboot_performed=false"
        section "basic system"
        run uname -a
        run cat /etc/os-release
        run cat /proc/cmdline
        scan_services
        scan_pd_binary
        scan_packages
        scan_maps
        scan_map_contents
        scan_firmware_identity
        scan_remoteproc_qrtr
        scan_root8_journal
        section "summary markers"
        if command -v pd-mapper >/dev/null 2>&1; then say "A14_ACPI_ROOT9_PDMAP_BINARY=PASS"; else say "A14_ACPI_ROOT9_PDMAP_BINARY=MISSING"; fi
        if [[ -d /sys/class/remoteproc ]] && find /sys/class/remoteproc -maxdepth 1 -name 'remoteproc*' | grep -q .; then say "A14_ACPI_ROOT9_REMOTEPROC_CLASS=PASS"; else say "A14_ACPI_ROOT9_REMOTEPROC_CLASS=MISSING_OR_EMPTY"; fi
        if grep -RIl .jsn /lib/firmware /lib/firmware/updates /usr/lib/firmware /usr/share /usr/local/share /etc 2>/dev/null | grep -Ei 'qcom|pd|qrtr|firmware' | head -n1 | grep -q .; then say "A14_ACPI_ROOT9_PDMAP_CANDIDATES=PASS"; else say "A14_ACPI_ROOT9_PDMAP_CANDIDATES=NONE_FOUND"; fi
        if [[ -r /sys/firmware/devicetree/base/compatible ]]; then say "A14_ACPI_ROOT9_DT_COMPATIBLE=PASS"; else say "A14_ACPI_ROOT9_DT_COMPATIBLE=MISSING"; fi
        if [[ -r /sys/firmware/acpi/tables/DSDT ]]; then say "A14_ACPI_ROOT9_ACPI_DSDT=PASS"; else say "A14_ACPI_ROOT9_ACPI_DSDT=MISSING"; fi
        say "A14_ACPI_ROOT9_MUTATIONS=0"
        say "A14_ACPI_ROOT9_REBOOT_PERFORMED=false"
        say "A14_ACPI_ROOT9_PDMAP_AUDIT_COMPLETE=1"
    } >"$tmp"
    install -m0644 "$tmp" "$REPORT"
    rm -f "$tmp"
    chown "$OWNER:$OWNER" "$REPORT" 2>/dev/null || true
    say "A14_ACPI_ROOT9_PDMAP_AUDIT=PASS"
    say "report=$REPORT"
    say "mutations=false"
    say "reboot_performed=false"
}

case "$ACTION" in
    audit) audit ;;
    *) die "usage: $0 [audit]" ;;
esac
