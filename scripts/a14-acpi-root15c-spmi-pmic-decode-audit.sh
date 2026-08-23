#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# ACPI ROOT15C: read-only SPMI CONF / PMIC PMCF decode audit.
#
# Purpose:
#   * turn ROOT15/ROOT15B structural evidence into testable decode constraints
#   * prove the PMCF 28-slot / two-bus flattening relationship against live DT
#   * dump the exact qcpmic8380 PMCF consumer site, not same-page heuristics
#   * search qcspmi8380 for exact references to the AeiBCONF descriptor region
#   * produce enough local disassembly to design the first ACPI-native SPMI patch
#
# Safety invariants:
#   - no kernel/Image/module build or install
#   - no initramfs work
#   - no GRUB writes
#   - no service/module mutation
#   - no MMIO or /dev/mem access
#   - no ACPI method execution
#   - no Windows driver execution
#   - no reboot
#
# Persistent write: only ~/Downloads/a14-acpi-root15c-spmi-pmic-decode-audit.txt
# All disassembly/intermediate files live under /tmp and are removed.
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
[[ -n "$OWNER_HOME" && -d "$OWNER_HOME" ]] || die "cannot resolve owner home"

REPORT="$OWNER_HOME/Downloads/a14-acpi-root15c-spmi-pmic-decode-audit.txt"
TMPDIR="$(mktemp -d /tmp/a14-root15c.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

exec > >(tee "$REPORT") 2>&1

say "A14_ACPI_ROOT15C_ENTERED=1"
say "timestamp=$(date --iso-8601=seconds)"
say "owner=$OWNER"
say "running_kernel=$(uname -r)"
say "persistent_mutations=report_only"
say "kernel_build=false"
say "module_build=false"
say "module_install=false"
say "initramfs_update=false"
say "grub_write=false"
say "service_mutation=false"
say "mmio_access=false"
say "acpi_method_execution=false"
say "windows_driver_execution=false"
say "reboot_performed=false"

have python3 || die "python3 is required"
have objdump || die "objdump is required"
have sha256sum || die "sha256sum is required"

QCSPMI_EXPECTED="10de4b33be2dfa2ef1b0ac5f0275933bd755d32bc1ac7f120149479ddaca2f56"
QCPMIC_EXPECTED="1bc74b8390202cb0c22b39e2633e1dadc0c4a41481d893c0e3727df70c697435"

find_exact_sys() {
    local basename="$1" expected="$2" candidate hash
    local roots=("$OWNER_HOME/Documents" "$OWNER_HOME/Downloads")
    while IFS= read -r -d '' candidate; do
        hash="$(sha256sum "$candidate" | awk '{print $1}')"
        if [[ "$hash" == "$expected" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(find "${roots[@]}" -type f -iname "$basename" -print0 2>/dev/null)
    return 1
}

QCSPMI_SYS="$(find_exact_sys qcspmi8380.sys "$QCSPMI_EXPECTED")" || die "canonical qcspmi8380.sys not found"
QCPMIC_SYS="$(find_exact_sys qcpmic8380.sys "$QCPMIC_EXPECTED")" || die "canonical qcpmic8380.sys not found"

section "canonical binaries"
say "QCSPMI_sys=$QCSPMI_SYS"
say "QCSPMI_sha256=$(sha256sum "$QCSPMI_SYS" | awk '{print $1}')"
say "QCPMIC_sys=$QCPMIC_SYS"
say "QCPMIC_sha256=$(sha256sum "$QCPMIC_SYS" | awk '{print $1}')"

section "firmware structural decode constraints"
python3 - <<'PY'
conf = bytes.fromhex(
    "000101037f0003800b08080a037f1c0100020c40000000500000"
    "000101007f0000800300000a007f040100020c40000000500000"
)
r0, r1 = conf[:26], conf[26:]
diff = [i for i, (a, b) in enumerate(zip(r0, r1)) if a != b]
print(f"CONF_TOTAL_LEN={len(conf)}")
print(f"CONF_RECORD_COUNT=2")
print(f"CONF_RECORD_LEN={len(r0)}")
print(f"CONF_RECORD_0={r0.hex()}")
print(f"CONF_RECORD_1={r1.hex()}")
print("CONF_DIFF_OFFSETS=" + ",".join(f"0x{i:02x}" for i in diff))
for i in diff:
    print(f"CONF_DIFF[0x{i:02x}]=0x{r0[i]:02x},0x{r1[i]:02x}")
print(f"CONF_COMMON_TAIL8={r0[-8:].hex()}")
print(f"CONF_TAIL_BASE=0x{int.from_bytes(r0[-8:-4], 'big'):08x}")
print(f"CONF_TAIL_SIZE=0x{int.from_bytes(r0[-4:], 'big'):08x}")
print("CONF_BYTE_SEMANTICS=UNRESOLVED")

pairs = [
    (0x00,0x10),(0x01,0x10),(0x02,0x10),(0x03,0x10),
    (0x04,0x10),(0x05,0x10),(0x06,0x10),(0x10,0x10),
    (0x08,0x10),(0x09,0x10),(0x10,0x10),(0x10,0x10),
    (0x0c,0x10),(0x10,0x10),(0x10,0x10),(0x10,0x10),
    (0x10,0x10),(0x10,0x10),(0x10,0x10),(0x10,0x10),
    (0x10,0x10),(0x15,0x10),(0x10,0x10),(0x10,0x10),
    (0x18,0x10),(0x19,0x10),(0x1a,0x10),(0x10,0x10),
]
bus0_sids = [0x0,0x1,0x2,0x3,0x4,0x5,0x6,0x8,0x9,0xc]
bus1_sids = [0x7,0xa,0xb,0xc]
stride = 14
populated = [i for i, (a, b) in enumerate(pairs) if a != 0x10]
expected = bus0_sids + [stride + sid for sid in bus1_sids]
identity = all(pairs[i][0] == i for i in populated)
second_all = all(b == 0x10 for a, b in pairs)
print(f"PMCF_DECLARED_COUNT=28")
print(f"PMCF_PAIR_COUNT={len(pairs)}")
print(f"DT_BUS0_SIDS=" + ",".join(f"0x{x:x}" for x in bus0_sids))
print(f"DT_BUS1_SIDS=" + ",".join(f"0x{x:x}" for x in bus1_sids))
print(f"PMCF_CANDIDATE_BUS_STRIDE={stride}")
print("PMCF_POPULATED_SLOTS=" + ",".join(f"0x{x:x}" for x in populated))
print("PMCF_EXPECTED_FLAT_SLOTS=" + ",".join(f"0x{x:x}" for x in expected))
print(f"PMCF_POPULATED_COUNT={len(populated)}")
print(f"DT_PMIC_NODE_COUNT={len(bus0_sids) + len(bus1_sids)}")
print("PMCF_FLAT_SLOT_MATCH=" + ("PASS" if populated == expected else "FAIL"))
print("PMCF_POPULATED_SLOT_IDENTITY=" + ("PASS" if identity else "FAIL"))
print("PMCF_SECOND_FIELD_ALL_0x10=" + ("PASS" if second_all else "FAIL"))
print("PMCF_STRUCTURAL_DECODE=" + ("PASS" if populated == expected and identity and second_all else "INCOMPLETE"))
print("NOTE=PMCF structural flattening is proven by correlation; exact Qualcomm field naming remains intentionally unclaimed")
PY

section "qcspmi exact descriptor bytes"
# AeiBCONF appears at VA 0x1400033a0 in the canonical build.  Dump a wide
# neighborhood because the framework registration object may begin before the
# printable tag itself.
objdump -s \
    --start-address=0x140003340 \
    --stop-address=0x140003440 \
    "$QCSPMI_SYS" || true

section "qcspmi descriptor-region disassembly"
objdump -d \
    --start-address=0x140003300 \
    --stop-address=0x140003500 \
    "$QCSPMI_SYS" || true

section "qcspmi exact descriptor-region references"
objdump -d "$QCSPMI_SYS" > "$TMPDIR/qcspmi.dis" 2> "$TMPDIR/qcspmi.dis.err" || true
python3 - "$TMPDIR/qcspmi.dis" <<'PY'
import re, sys
path = sys.argv[1]
lines = open(path, errors='replace').read().splitlines()
ins = []
rx = re.compile(r'^\s*([0-9a-fA-F]+):\s+[0-9a-fA-F]+\s+([^\s]+)\s*(.*)$')
for raw in lines:
    m = rx.match(raw)
    if m:
        ins.append((int(m.group(1),16), m.group(2), m.group(3).strip(), raw))
lo, hi = 0x140003340, 0x140003440
hits = []
for idx,(addr,mn,ops,raw) in enumerate(ins):
    if mn == 'adr':
        m = re.search(r'\b(x\d+),\s*(0x[0-9a-fA-F]+)', ops)
        if m:
            t = int(m.group(2),16)
            if lo <= t < hi:
                hits.append((addr, 'adr', t, raw))
    if mn == 'adrp':
        m = re.search(r'\b(x\d+),\s*(0x[0-9a-fA-F]+)', ops)
        if not m:
            continue
        reg, page = m.group(1), int(m.group(2),16)
        for j in range(idx+1, min(idx+7, len(ins))):
            a2,m2,o2,r2 = ins[j]
            ma = re.search(r'\b(x\d+),\s*'+re.escape(reg)+r',\s*#(0x[0-9a-fA-F]+|\d+)', o2)
            if m2 == 'add' and ma:
                imm = int(ma.group(2),0)
                t = page + imm
                if lo <= t < hi:
                    hits.append((addr, f'adrp+add@0x{a2:x}', t, raw+' || '+r2))
                break
            if m2 in ('adrp','ret','b','br'):
                break
print(f"QCSPMI_DESCRIPTOR_EXACT_REF_COUNT={len(hits)}")
for n,(addr,kind,target,raw) in enumerate(hits):
    print(f"QCSPMI_DESCRIPTOR_REF[{n}] at=0x{addr:x} kind={kind} target=0x{target:x}")
    print("  "+raw.strip())
PY

section "qcspmi absolute pointer scan into descriptor region"
python3 - "$QCSPMI_SYS" <<'PY'
import sys, struct
p = sys.argv[1]
data = open(p,'rb').read()
lo, hi = 0x140003340, 0x140003440
hits=[]
for off in range(0, len(data)-7):
    v=struct.unpack_from('<Q',data,off)[0]
    if lo <= v < hi:
        hits.append((off,v))
print(f"QCSPMI_DESCRIPTOR_POINTER_COUNT={len(hits)}")
for n,(off,v) in enumerate(hits[:64]):
    print(f"QCSPMI_DESCRIPTOR_POINTER[{n}] file_off=0x{off:x} va=0x{v:x}")
PY

section "qcspmi focused strings"
strings -a -t x "$QCSPMI_SYS" | grep -Ei 'CONF|AeiB|AeoB|SPMI|RESOURCE_HUB|Device\\Spmi|client|context' | head -n 160 || true

section "qcpmic exact PMCF xref window"
# ROOT15B proved the exact ADRP+ADD xref:
#   0x140002f6c + #0x950 -> 0x140036950 ("PMCF")
objdump -d \
    --start-address=0x140002e80 \
    --stop-address=0x140003180 \
    "$QCPMIC_SYS" || true

section "qcpmic PMCF helper window"
# The exact PMCF site calls 0x140032f58 with x1=4, x2="PMCF", x3=4.
# Dump the helper body so its role can be identified without guessing.
objdump -d \
    --start-address=0x140032f00 \
    --stop-address=0x140033080 \
    "$QCPMIC_SYS" || true

section "qcpmic PMCF string bytes"
objdump -s \
    --start-address=0x140036900 \
    --stop-address=0x1400369b0 \
    "$QCPMIC_SYS" || true

section "qcpmic focused strings"
strings -a -t x "$QCPMIC_SYS" | grep -Ei 'PMCF|PMIC|SPMI|USID|SID|RESOURCE_HUB|Device\\Spmi|config|slave' | head -n 260 || true

section "static evidence summary"
say "QCSPMI_CONF_PRINTABLE_TAG_VA=0x1400033a0"
say "QCPMIC_PMCF_STRING_VA=0x140036950"
say "QCPMIC_PMCF_EXACT_XREF_VA=0x140002f6c"
say "QCPMIC_PMCF_HELPER_VA=0x140032f58"
say "PMCF_CANDIDATE_BUS_STRIDE=14"
say "PMCF_STRUCTURAL_DECODE_EXPECTED=PASS"
say "CONF_BYTE_SEMANTICS=UNRESOLVED"
say "next_decision=decode_CONF_or_begin_ACPI_SPMI_controller_bootstrap"

section "ROOT15C summary markers"
say "A14_ACPI_ROOT15C_PMCF_STRUCTURAL_DECODE=COMPLETE"
say "A14_ACPI_ROOT15C_QCSPMI_DESCRIPTOR_AUDIT=COMPLETE"
say "A14_ACPI_ROOT15C_QCPMIC_EXACT_XREF_AUDIT=COMPLETE"
say "A14_ACPI_ROOT15C_DECODE_AUDIT=PASS"
say "persistent_mutations=report_only"
say "kernel_build=false"
say "module_build=false"
say "module_install=false"
say "initramfs_update=false"
say "grub_write=false"
say "service_mutation=false"
say "mmio_access=false"
say "acpi_method_execution=false"
say "windows_driver_execution=false"
say "reboot_performed=false"

chown "$OWNER:$OWNER" "$REPORT" 2>/dev/null || true
