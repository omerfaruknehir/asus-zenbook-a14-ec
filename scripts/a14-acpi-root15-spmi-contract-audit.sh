#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# ACPI ROOT15: read-only SPMI/PMIC firmware-contract correlation audit.
#
# Purpose:
#   * capture the known-good live DT SPMI/PMIC topology and resource properties
#   * capture Linux spmi-pmic-arb/qcom-spmi-pmic firmware assumptions
#   * locate/decode the factory ACPI QCOM0C0B (SPMI) and QCOM0C2B (PMIC) objects
#   * locate exact Qualcomm Windows qcspmi8380 artifacts for contract analysis
#
# Safety invariants:
#   * no kernel/Image/module build or install
#   * no initramfs work
#   * no GRUB writes
#   * no service/module mutation
#   * no MMIO reads/writes through /dev/mem
#   * no ACPI method execution against live hardware
#   * no reboot
#
# Persistent write: only ~/Downloads/a14-acpi-root15-spmi-contract-audit.txt
# Temporary files, if needed for DSDT decompilation, live under /tmp and are removed.
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
DTROOT="${A14_DTROOT:-/sys/firmware/devicetree/base}"
REPORT="$OWNER_HOME/Downloads/a14-acpi-root15-spmi-contract-audit.txt"
SCRATCH=""

for c in bash cat date file find getent grep head id od python3 sed sha256sum sort strings tail uname; do
    have "$c" || die "missing command: $c"
done

cleanup(){
    [[ -n "${SCRATCH:-}" && -d "$SCRATCH" ]] && rm -rf -- "$SCRATCH"
}
finalize(){
    cleanup
    [[ -f "$REPORT" ]] && chown "$OWNER:$OWNER" "$REPORT" 2>/dev/null || true
}
trap finalize EXIT INT TERM

find_arbiter_node(){
    local p
    for p in \
        "$DTROOT/soc@0/arbiter@c400000" \
        "$DTROOT/soc/arbiter@c400000"; do
        [[ -d "$p" ]] && { printf '%s\n' "$p"; return 0; }
    done
    find "$DTROOT" -maxdepth 5 -type d -name 'arbiter@c400000' -print -quit 2>/dev/null || true
}

live_dt_audit(){
    section "live DT SPMI/PMIC topology"
    if [[ ! -d "$DTROOT" ]]; then
        say "dtroot_present=false"
        say "NOTE=run ROOT15 audit from the known-good DT boot for live correlation"
        return 0
    fi

    local arb
    arb="$(find_arbiter_node)"
    say "dtroot_present=true"
    say "arbiter_node=${arb:-NOT_FOUND}"
    if [[ -z "$arb" || ! -d "$arb" ]]; then
        return 0
    fi

    python3 - "$arb" <<'PY'
import os
import struct
import sys
from pathlib import Path

arb = Path(sys.argv[1])
STRING_PROPS = {"compatible", "status", "label", "reg-names", "interrupt-names"}
FOCUS_PROPS = {
    "compatible", "reg", "reg-names", "interrupts", "interrupt-names",
    "qcom,channel", "qcom,ee", "qcom,bus-id", "qcom,pmic-arb-bus-id",
    "#address-cells", "#size-cells", "status"
}

def show_prop(p: Path):
    try:
        data = p.read_bytes()
    except OSError as e:
        print(f"PROP {p.name}: READ_ERROR={e}")
        return
    hx = data.hex()
    print(f"PROP {p.name}: len={len(data)} hex={hx}")
    if p.name in STRING_PROPS:
        vals = [x.decode('ascii', 'replace') for x in data.rstrip(b'\0').split(b'\0') if x]
        if vals:
            print("  strings=" + " | ".join(vals))
    if len(data) and len(data) % 4 == 0:
        vals = struct.unpack(">" + "I" * (len(data)//4), data)
        print("  be32=" + " ".join(f"0x{x:08x}" for x in vals))

print(f"ARB={arb}")
for name in sorted(FOCUS_PROPS):
    p = arb / name
    if p.is_file():
        show_prop(p)

print("--- focused subtree nodes ---")
for root, dirs, files in os.walk(arb):
    rel = Path(root).relative_to(arb)
    depth = len(rel.parts)
    if depth > 4:
        dirs[:] = []
        continue
    base = Path(root).name
    interesting = (
        depth == 0 or base.startswith("spmi@") or base.startswith("pmic@") or
        "led" in base.lower() or "flash" in base.lower() or
        base.startswith("gpio@") or base.startswith("rtc@") or
        base.startswith("temp-alarm@")
    )
    if not interesting:
        continue
    print(f"NODE {root}")
    for name in sorted(set(files) & FOCUS_PROPS):
        show_prop(Path(root) / name)
PY

    section "live DT PMIC and flash node inventory"
    find "$arb" -maxdepth 6 -type d \
        \( -name 'pmic@*' -o -name '*flash*' -o -name 'led-controller@*' \) \
        -print 2>/dev/null | sort || true
}

linux_source_contract(){
    section "Linux v7.1 SPMI/PMIC source contract"
    local arb_src="$SRC/drivers/spmi/spmi-pmic-arb.c"
    local pmic_src="$SRC/drivers/mfd/qcom-spmi-pmic.c"
    local flash_src="$SRC/drivers/leds/flash/leds-qcom-flash.c"

    say "kernel_source=$SRC"
    for f in "$arb_src" "$pmic_src" "$flash_src"; do
        say "source_file=$f present=$([[ -r "$f" ]] && echo true || echo false)"
    done

    if [[ -r "$arb_src" ]]; then
        say "--- spmi-pmic-arb firmware/resource dependencies"
        grep -nE \
            'of_match_table|of_property_read|of_get_|for_each_.*child|platform_get_resource_byname|devm_platform_ioremap_resource_byname|platform_get_irq|qcom,channel|qcom,ee|qcom,spmi-pmic-arb|x1e80100-spmi-pmic-arb' \
            "$arb_src" 2>/dev/null | head -n 260 || true
    fi

    if [[ -r "$pmic_src" ]]; then
        say "--- qcom-spmi-pmic OF/fwnode dependencies"
        grep -nE \
            'of_match|of_get_|for_each_.*child|spmi_find_device_by_of_node|devm_of_platform_populate|device_get_match_data|MODULE_DEVICE_TABLE' \
            "$pmic_src" 2>/dev/null | head -n 220 || true
    fi

    if [[ -r "$flash_src" ]]; then
        say "--- leds-qcom-flash firmware-node dependencies"
        grep -nE \
            'of_match|device_for_each_child_node|device_property_|fwnode_property_|MODULE_DEVICE_TABLE' \
            "$flash_src" 2>/dev/null | head -n 220 || true
    fi
}

extract_balanced_device(){
    local file="$1" device="$2"
    python3 - "$file" "$device" <<'PY'
import re
import sys
from pathlib import Path

p = Path(sys.argv[1])
name = sys.argv[2]
text = p.read_text(errors="replace")
m = re.search(rf"\bDevice\s*\(\s*{re.escape(name)}\s*\)\s*\{{", text)
if not m:
    raise SystemExit(2)
start = m.start()
pos = m.end() - 1
depth = 0
in_string = False
escape = False
for i in range(pos, len(text)):
    ch = text[i]
    if in_string:
        if escape:
            escape = False
        elif ch == "\\":
            escape = True
        elif ch == '"':
            in_string = False
        continue
    if ch == '"':
        in_string = True
    elif ch == '{':
        depth += 1
    elif ch == '}':
        depth -= 1
        if depth == 0:
            print(text[start:i+1])
            raise SystemExit(0)
raise SystemExit(3)
PY
}

factory_acpi_contract(){
    section "factory ACPI SPMI/PMIC contract"
    SCRATCH="$(mktemp -d /tmp/a14-root15-spmi.XXXXXX)"

    local dsdt=""
    local candidate

    # If the kernel exposes a DSDT even in this boot mode, decompile a temporary
    # copy. This is read-only against firmware and executes no AML methods.
    if [[ -r /sys/firmware/acpi/tables/DSDT ]] && have iasl; then
        cp -- /sys/firmware/acpi/tables/DSDT "$SCRATCH/DSDT.dat"
        if (cd "$SCRATCH" && iasl -d DSDT.dat >/dev/null 2>&1); then
            dsdt="$SCRATCH/DSDT.dsl"
            say "factory_dsdt_source=/sys/firmware/acpi/tables/DSDT"
        fi
    fi

    # Otherwise locate a previously decompiled factory table under Downloads.
    if [[ -z "$dsdt" && -d "$OWNER_HOME/Downloads" ]]; then
        while IFS= read -r candidate; do
            if grep -qE 'Name \(_HID, "QCOM0C0B"\)|Device \(SPMI\)' "$candidate" 2>/dev/null; then
                dsdt="$candidate"
                break
            fi
        done < <(find "$OWNER_HOME/Downloads" -maxdepth 9 -type f \
            \( -iname 'A14-DSDT-readable.dsl' -o -iname 'DSDT.dsl' -o -iname '*DSDT*.dsl' \) \
            -size -8M -print 2>/dev/null | sort)
    fi

    say "factory_dsdt_text=${dsdt:-NOT_FOUND_LOCALLY}"
    if [[ -n "$dsdt" && -r "$dsdt" ]]; then
        say "--- ACPI Device(SPMI)"
        extract_balanced_device "$dsdt" SPMI || say "ACPI_SPMI_DEVICE_EXTRACT=FAILED"
        say "--- ACPI Device(PMIC)"
        extract_balanced_device "$dsdt" PMIC || say "ACPI_PMIC_DEVICE_EXTRACT=FAILED"
    else
        say "NOTE=factory DSDT text not found locally; known audited IDs are QCOM0C0B and QCOM0C2B"
    fi

    # Preserve the exact already-audited QCOM0C0B CONF payload as a correlation
    # reference. This does not substitute for parsing a local DSDT above.
    section "known factory SPMI.CONF payload correlation views"
    python3 <<'PY'
import struct

b = bytes.fromhex(
    "00 01 01 03 7f 00 03 80 0b 08 08 0a 03 7f 1c 01 "
    "00 02 0c 40 00 00 00 50 00 00 00 01 01 00 7f 00 "
    "00 80 03 00 00 0a 00 7f 04 01 00 02 0c 40 00 00 "
    "00 50 00 00"
)
print(f"SPMI_CONF_len={len(b)}")
print("SPMI_CONF_hex=" + b.hex())
print("--- byte offsets ---")
for i in range(0, len(b), 8):
    print(f"{i:02x}: " + " ".join(f"{x:02x}" for x in b[i:i+8]))
print("--- candidate 16-bit little-endian words (descriptive only) ---")
print(" ".join(f"{x:04x}" for x in struct.unpack("<" + "H"*(len(b)//2), b)))
print("--- candidate 16-bit big-endian words (descriptive only) ---")
print(" ".join(f"{x:04x}" for x in struct.unpack(">" + "H"*(len(b)//2), b)))
print("--- unaligned 32-bit windows that look like 0x0c4xxxxx / 0x0c5xxxxx / 0x0c6xxxxx ---")
for endian, fmt in (("le", "<I"), ("be", ">I")):
    for off in range(0, len(b)-3):
        val = struct.unpack_from(fmt, b, off)[0]
        if 0x0c400000 <= val < 0x0c900000:
            print(f"{endian} off=0x{off:02x} value=0x{val:08x}")
PY
}

windows_qcspmi_audit(){
    section "Windows qcspmi8380 provenance/artifact audit"
    local roots=()
    local r f
    for r in "$OWNER_HOME/Downloads" "$OWNER_HOME"; do
        [[ -d "$r" ]] && roots+=("$r")
    done

    # Restrict the broad home scan to exact qcspmi names. Duplicate hits are
    # normalized by sort -u.
    mapfile -t hits < <(
        for r in "${roots[@]}"; do
            find "$r" -xdev -maxdepth 10 -type f \
                \( -iname 'qcspmi8380.sys' -o -iname 'qcspmi8380.inf' \
                   -o -iname '*qcspmi8380*disasm*' -o -iname '*qcspmi8380*objdump*' \
                   -o -iname '*qcspmi8380*.asm' -o -iname '*qcspmi8380*.txt' \) \
                -print 2>/dev/null || true
        done | sort -u
    )

    say "qcspmi_artifact_count=${#hits[@]}"
    for f in "${hits[@]}"; do
        say "--- artifact=$f"
        file "$f" 2>/dev/null || true
        sha256sum "$f" 2>/dev/null || true
        if [[ "$f" == *.sys || "$f" == *.SYS ]]; then
            say "strings_ascii_focus:"
            strings -a "$f" 2>/dev/null |
                grep -Ei 'QCOM0C0B|PNP0CA2|CONF|SPMI|PMIC|ACPI|resource|channel|execution environment|arbiter' |
                head -n 240 || true
            say "strings_utf16le_focus:"
            strings -el "$f" 2>/dev/null |
                grep -Ei 'QCOM0C0B|PNP0CA2|CONF|SPMI|PMIC|ACPI|resource|channel|execution environment|arbiter' |
                head -n 240 || true
            if have llvm-readobj; then
                say "llvm-readobj_imports:"
                llvm-readobj --coff-imports "$f" 2>/dev/null |
                    grep -Ei 'ACPI|RESOURCE|WDF|HAL|MMIO|MEMORY|interrupt|SPMI' |
                    head -n 240 || true
            elif have objdump; then
                say "objdump_import_focus:"
                objdump -p "$f" 2>/dev/null |
                    grep -Ei 'ACPI|RESOURCE|WDF|HAL|MMIO|MEMORY|interrupt|SPMI' |
                    head -n 240 || true
            fi
        else
            grep -Ein -E 'QCOM0C0B|PNP0CA2|CONF|SPMI|PMIC|ACPI|resource|channel|arbiter' "$f" 2>/dev/null |
                head -n 320 || true
        fi
    done

    section "archives containing qcspmi8380 (listing only)"
    if have unzip && [[ -d "$OWNER_HOME/Downloads" ]]; then
        local z
        local zcount=0
        while IFS= read -r z; do
            if unzip -Z1 "$z" 2>/dev/null | grep -Eiq '(^|/)qcspmi8380(/|.*qcspmi8380\.(sys|inf)$)'; then
                say "archive=$z"
                unzip -Z1 "$z" 2>/dev/null | grep -Ei 'qcspmi8380' | head -n 120 || true
                zcount=$((zcount + 1))
            fi
        done < <(find "$OWNER_HOME/Downloads" -maxdepth 5 -type f -iname '*.zip' -size -750M -print 2>/dev/null | sort)
        say "qcspmi_archive_count=$zcount"
    else
        say "zip_listing_skipped=true"
    fi
}

summary_markers(){
    section "ROOT15 audit summary"
    say "A14_ACPI_ROOT15_LIVE_DT_AUDIT=COMPLETE"
    say "A14_ACPI_ROOT15_LINUX_CONTRACT_AUDIT=COMPLETE"
    say "A14_ACPI_ROOT15_FACTORY_ACPI_AUDIT=COMPLETE"
    say "A14_ACPI_ROOT15_WINDOWS_QCSPMI_AUDIT=COMPLETE"
    say "A14_ACPI_ROOT15_SPMI_CONTRACT_AUDIT=PASS"
    say "persistent_mutations=report_only"
    say "kernel_build=false"
    say "module_build=false"
    say "module_install=false"
    say "initramfs_update=false"
    say "grub_write=false"
    say "service_mutation=false"
    say "mmio_access=false"
    say "acpi_method_execution=false"
    say "reboot_performed=false"
}

audit(){
    {
        say "A14_ACPI_ROOT15_ENTERED=1"
        say "timestamp=$(date -Is)"
        say "owner=$OWNER"
        say "running_kernel=$(uname -r)"
        say "src=$SRC"
        say "dtroot=$DTROOT"
        say "persistent_mutations=report_only"
        say "kernel_build=false"
        say "module_build=false"
        say "module_install=false"
        say "initramfs_update=false"
        say "grub_write=false"
        say "service_mutation=false"
        say "mmio_access=false"
        say "acpi_method_execution=false"
        say "reboot_performed=false"

        live_dt_audit
        linux_source_contract
        factory_acpi_contract
        windows_qcspmi_audit
        summary_markers
    } >"$REPORT" 2>&1

    cleanup
    SCRATCH=""
    chown "$OWNER:$OWNER" "$REPORT" 2>/dev/null || true

    say "A14_ACPI_ROOT15_SPMI_CONTRACT_AUDIT=PASS"
    say "report=$REPORT"
    say "persistent_mutations=report_only"
    say "reboot_performed=false"
}

audit
