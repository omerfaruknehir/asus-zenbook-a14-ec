#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Remove the two known ~90 second ACPI-only boot synchronization waits:
#   1) systemd TPM2 initial wait for /dev/tpm0 + /dev/tpmrm0
#   2) A14 SSC service boot dependency on /dev/fastrpc-adsp
#
# This does NOT lower DefaultTimeoutStartSec, disable TPM support, or disable
# FastRPC/SSC. TPM may still appear later. SSC is path-activated when FastRPC
# ADSP actually exists.
set -euo pipefail

ACTION="${1:-apply}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SERVICE="/etc/systemd/system/a14-ssc-hexagonrpcd.service"
SERVICE_BACKUP="/etc/systemd/system/a14-ssc-hexagonrpcd.service.pre-boot-wait-fix"
PATH_UNIT="/etc/systemd/system/a14-ssc-hexagonrpcd.path"
GRUB_HELPER="$ROOT/scripts/a14-full-acpi-unrestricted-entry.sh"
DEVICE_UNIT='dev-fastrpc\x2dadsp.device'

die(){ echo "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"; }

verify_service_fixed(){
    [[ -r "$SERVICE" ]] || die "missing $SERVICE"
    grep -q '^ConditionPathExists=/dev/fastrpc-adsp$' "$SERVICE" || die "FastRPC ConditionPathExists guard missing"
    ! grep -Fq "Wants=$DEVICE_UNIT" "$SERVICE" || die "FastRPC device Wants dependency still present"
    ! grep -Fq "$DEVICE_UNIT" < <(grep '^After=' "$SERVICE" || true) || die "FastRPC device After dependency still present"
}

write_path_unit(){
    cat > "$PATH_UNIT" <<'EOF'
[Unit]
Description=Start A14 SSC Hexagon RPC daemon when FastRPC ADSP appears

[Path]
PathExists=/dev/fastrpc-adsp
Unit=a14-ssc-hexagonrpcd.service

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$PATH_UNIT"
}

fix_fastrpc_wait(){
    [[ -r "$SERVICE" ]] || die "missing $SERVICE"
    [[ -e "$SERVICE_BACKUP" ]] || cp -a "$SERVICE" "$SERVICE_BACKUP"

    python3 - "$SERVICE" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()
dev = r"dev-fastrpc\x2dadsp.device"

if "ConditionPathExists=/dev/fastrpc-adsp" not in s:
    raise SystemExit("ERROR: refusing to modify unexpected SSC unit: ConditionPathExists is missing")

lines = s.splitlines()
out = []
seen_wants = False
seen_after = False
for line in lines:
    if line.startswith("Wants="):
        words = line[len("Wants="):].split()
        if dev in words:
            seen_wants = True
            words = [x for x in words if x != dev]
            if words:
                out.append("Wants=" + " ".join(words))
            continue
    if line.startswith("After="):
        words = line[len("After="):].split()
        if dev in words:
            seen_after = True
            words = [x for x in words if x != dev]
            out.append("After=" + " ".join(words))
            continue
    out.append(line)

new = "\n".join(out) + "\n"
# Idempotent success: either we removed the known dependency now, or the
# resulting semantic state was already present from an earlier run.
if dev in new:
    raise SystemExit("ERROR: FastRPC device dependency remains after transform")
if "ConditionPathExists=/dev/fastrpc-adsp" not in new:
    raise SystemExit("ERROR: FastRPC existence guard was lost")
p.write_text(new)
print("fastrpc_wants_removed=" + ("yes" if seen_wants else "already"))
print("fastrpc_after_removed=" + ("yes" if seen_after else "already"))
PY

    verify_service_fixed
    write_path_unit

    systemctl daemon-reload
    systemctl enable --now a14-ssc-hexagonrpcd.path >/dev/null

    say_path="$(systemctl is-enabled a14-ssc-hexagonrpcd.path 2>/dev/null || true)"
    [[ "$say_path" == "enabled" ]] || die "FastRPC path unit was not enabled"
}

apply_fix(){
    need_root
    for c in python3 systemctl grep cp chmod; do need "$c"; done
    [[ -x "$GRUB_HELPER" || -r "$GRUB_HELPER" ]] || die "missing $GRUB_HELPER"

    echo "A14_FULL_ACPI_BOOT_WAIT_FIX=START"
    echo "global_systemd_timeout_change=false"
    echo "tpm_support_disabled=false"
    echo "fastrpc_support_disabled=false"

    fix_fastrpc_wait

    # Regenerate only the dedicated ACPI-only GRUB entry. The helper adds the
    # upstream-supported systemd.tpm2_wait=0 parameter and verifies it occurs
    # exactly once. Normal kernel entries are untouched.
    bash "$GRUB_HELPER"

    verify_service_fixed
    grep -q '^PathExists=/dev/fastrpc-adsp$' "$PATH_UNIT" || die "FastRPC path trigger missing"
    grep -q '^Unit=a14-ssc-hexagonrpcd.service$' "$PATH_UNIT" || die "FastRPC path target missing"

    echo "A14_FULL_ACPI_BOOT_WAIT_FIX=COMPLETE"
    echo "tpm_boot_wait=disabled_on_acpi_entry"
    echo "tpm_runtime_support=unchanged"
    echo "fastrpc_boot_wait=removed"
    echo "fastrpc_late_activation=enabled"
    echo "global_systemd_timeout=unchanged"
    echo "kernel_image=unchanged"
    echo "modules=unchanged"
    echo "initramfs=unchanged"
}

status_fix(){
    echo "running_kernel=$(uname -r)"
    if [[ -r "$SERVICE" ]]; then
        echo "--- FastRPC service dependencies ---"
        grep -E '^(After|Wants|ConditionPathExists)=' "$SERVICE" || true
    else
        echo "fastrpc_service=missing"
    fi
    echo "fastrpc_path_enabled=$(systemctl is-enabled a14-ssc-hexagonrpcd.path 2>/dev/null || true)"
    echo "fastrpc_path_active=$(systemctl is-active a14-ssc-hexagonrpcd.path 2>/dev/null || true)"
    if [[ -r /etc/grub.d/41_a14_full_acpi_checkpoint ]]; then
        echo "--- ACPI-only linux line ---"
        awk '/^menuentry .*ACPI-ONLY UNRESTRICTED/{seen=1} seen && /^[[:space:]]*linux[[:space:]]/{print; exit}' /etc/grub.d/41_a14_full_acpi_checkpoint
    fi
}

case "$ACTION" in
    apply) apply_fix ;;
    status) status_fix ;;
    *) die "usage: $0 {apply|status}" ;;
esac
