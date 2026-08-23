#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# ACPI ROOT15B: read-only Qualcomm Windows SPMI/PMIC contract binary audit.
#
# Purpose:
#   * reverse-correlate QCOM0C0B CONF() with qcspmi8380.sys
#   * reverse-correlate QCOM0C2B PMCF() with qcpmic8380.sys
#   * identify static firmware-method xrefs and embedded controller constants
#   * compare duplicate driver builds already present on the machine
#
# Safety invariants:
#   - no kernel/Image/module build or install
#   - no initramfs work
#   - no GRUB writes
#   - no service/module mutation
#   - no MMIO or /dev/mem access
#   - no ACPI method execution
#   - no driver execution
#   - no reboot
#
# Persistent write: only ~/Downloads/a14-acpi-root15b-qcspmi-qcpmic-binary-audit.txt
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
[[ -d "$OWNER_HOME" ]] || die "cannot resolve owner home"

REPORT="$OWNER_HOME/Downloads/a14-acpi-root15b-qcspmi-qcpmic-binary-audit.txt"
SCRATCH=""

for c in bash cat cmp date file find getent grep head id od python3 sed sha256sum sort stat strings tail; do
    have "$c" || die "missing command: $c"
done

OBJDUMP=""
for c in objdump aarch64-linux-gnu-objdump llvm-objdump; do
    if have "$c"; then
        OBJDUMP="$c"
        break
    fi
done
[[ -n "$OBJDUMP" ]] || die "need objdump/aarch64-linux-gnu-objdump/llvm-objdump"

cleanup(){
    [[ -n "${SCRATCH:-}" && -d "$SCRATCH" ]] && rm -rf -- "$SCRATCH"
}
finalize(){
    cleanup
    [[ -f "$REPORT" ]] && chown "$OWNER:$OWNER" "$REPORT" 2>/dev/null || true
}
trap finalize EXIT INT TERM

find_exact_artifacts(){
    local base="$1"
    {
        find "$OWNER_HOME/Downloads" "$OWNER_HOME/Documents" \
            -xdev -maxdepth 12 -type f \
            \( -iname "${base}.sys" -o -iname "${base}.inf" \) \
            -print 2>/dev/null || true
    } | sort -u
}

pick_canonical_sys(){
    local base="$1" expected_sha="$2" f got first=""
    while IFS= read -r f; do
        [[ -r "$f" && "${f,,}" == *.sys ]] || continue
        [[ -z "$first" ]] && first="$f"
        got="$(sha256sum "$f" | awk '{print $1}')"
        if [[ "$got" == "$expected_sha" ]]; then
            printf '%s\n' "$f"
            return 0
        fi
    done < <(find_exact_artifacts "$base")
    printf '%s\n' "$first"
}

pick_canonical_inf(){
    local base="$1" f first=""
    while IFS= read -r f; do
        [[ -r "$f" && "${f,,}" == *.inf ]] || continue
        [[ -z "$first" ]] && first="$f"
        if [[ "$f" == "$OWNER_HOME/Downloads/"* ]]; then
            printf '%s\n' "$f"
            return 0
        fi
    done < <(find_exact_artifacts "$base")
    printf '%s\n' "$first"
}

pe_static_xref_analysis(){
    local label="$1" bin="$2" disasm="$3" method="$4"
    python3 - "$label" "$bin" "$disasm" "$method" <<'PY'
import re
import struct
import sys
from pathlib import Path

label, bin_path, disasm_path, method = sys.argv[1:]
p = Path(bin_path)
data = p.read_bytes()

def u16(o): return struct.unpack_from("<H", data, o)[0]
def u32(o): return struct.unpack_from("<I", data, o)[0]
def u64(o): return struct.unpack_from("<Q", data, o)[0]

print(f"PE_ANALYSIS_LABEL={label}")
print(f"PE_ANALYSIS_METHOD={method}")
print(f"PE_SIZE={len(data)}")

sections = []
image_base = 0
try:
    pe = u32(0x3c)
    if data[pe:pe+4] != b"PE\0\0":
        raise ValueError("missing PE signature")
    coff = pe + 4
    nsec = u16(coff + 2)
    opt_size = u16(coff + 16)
    opt = coff + 20
    magic = u16(opt)
    if magic == 0x20b:
        image_base = u64(opt + 24)
    elif magic == 0x10b:
        image_base = u32(opt + 28)
    else:
        raise ValueError(f"unexpected optional-header magic 0x{magic:x}")
    sec_off = opt + opt_size
    for i in range(nsec):
        o = sec_off + i * 40
        name = data[o:o+8].split(b"\0", 1)[0].decode("ascii", "replace")
        vsize = u32(o + 8)
        va = u32(o + 12)
        raw_size = u32(o + 16)
        raw = u32(o + 20)
        sections.append((name, va, vsize, raw, raw_size))
    print(f"PE_IMAGE_BASE=0x{image_base:x}")
    print(f"PE_SECTION_COUNT={len(sections)}")
    for name, va, vsize, raw, raw_size in sections:
        print(f"PE_SECTION name={name} rva=0x{va:x} vsize=0x{vsize:x} raw=0x{raw:x} raw_size=0x{raw_size:x}")
except Exception as e:
    print(f"PE_PARSE_ERROR={e}")

def map_offset(off):
    for name, va, vsize, raw, raw_size in sections:
        if raw <= off < raw + raw_size:
            rva = va + (off - raw)
            return name, rva, image_base + rva
    if off < len(data):
        return "headers_or_overlay", off, image_base + off
    return "unmapped", None, None

needles = [
    b"AeiB" + method.encode("ascii"),
    method.encode("ascii"),
    method.encode("utf-16le"),
    b"AeiB",
]
seen = set()
targets = []
print("--- firmware-method/string occurrences ---")
for needle in needles:
    start = 0
    while True:
        off = data.find(needle, start)
        if off < 0:
            break
        key = (off, needle)
        if key not in seen:
            seen.add(key)
            sec, rva, va = map_offset(off)
            print(f"STRING needle={needle!r} file_off=0x{off:x} section={sec} rva={None if rva is None else hex(rva)} va={None if va is None else hex(va)}")
            if rva is not None:
                targets.append((off, rva, va, needle))
            lo=max(0, off-16); hi=min(len(data), off+len(needle)+32)
            print("  HEX_CONTEXT=" + data[lo:hi].hex())
        start = off + 1

print("--- selected embedded constants ---")
constants = {
    "ACPI_WINDOW_BASE": 0x0c400000,
    "ACPI_WINDOW_SIZE": 0x00500000,
    "CORE_BASE": 0x0c400000,
    "CHNLS_BASE": 0x0c500000,
    "OBSRVR_BASE": 0x0c440000,
    "BUS0_CNFG": 0x0c42d000,
    "BUS0_INTR": 0x0c4c0000,
    "BUS1_CNFG": 0x0c432000,
    "BUS1_INTR": 0x0c4d0000,
}
for name, val in constants.items():
    hits=[]
    for endian, fmt in (("le","<I"),("be",">I")):
        needle=struct.pack(fmt,val)
        start=0
        while len(hits) < 20:
            off=data.find(needle,start)
            if off < 0: break
            sec,rva,va=map_offset(off)
            hits.append((endian,off,sec,rva,va))
            start=off+1
    print(f"CONST {name}=0x{val:08x} hit_count={len(hits)}")
    for endian,off,sec,rva,va in hits:
        print(f"  {endian} file_off=0x{off:x} section={sec} rva={None if rva is None else hex(rva)} va={None if va is None else hex(va)}")

# Disassembly xref recovery for common AArch64 address materialization:
#   adrp Xn, target_page
#   add  Xd, Xn, #pageoff
# and ADR direct references. This is heuristic and reported as such.
try:
    lines = Path(disasm_path).read_text(errors="replace").splitlines()
except Exception as e:
    print(f"DISASM_READ_ERROR={e}")
    raise SystemExit(0)

insns=[]
for idx,line in enumerate(lines):
    m=re.match(r"^\s*([0-9a-fA-F]+):\s+(?:[0-9a-fA-F]{8}\s+)?(.*)$", line)
    if not m:
        continue
    try: addr=int(m.group(1),16)
    except ValueError: continue
    asm=m.group(2).strip()
    insns.append((idx,addr,asm,line))

target_addrs=set()
for _,rva,va,_ in targets:
    target_addrs.add(rva)
    target_addrs.add(va)

xrefs=[]
for j,(line_idx,addr,asm,rawline) in enumerate(insns):
    m_adr=re.search(r"\badr\s+(x\d+),\s*(?:#)?(?:0x)?([0-9a-fA-F]+)", asm)
    if m_adr:
        try: dest=int(m_adr.group(2),16)
        except ValueError: dest=-1
        if dest in target_addrs:
            xrefs.append((j, f"adr_exact target=0x{dest:x}"))
    m_adrp=re.search(r"\badrp\s+(x\d+),\s*(?:#)?(?:0x)?([0-9a-fA-F]+)", asm)
    if not m_adrp:
        continue
    reg=m_adrp.group(1)
    try: page=int(m_adrp.group(2),16)
    except ValueError: continue
    for k in range(j+1, min(j+12, len(insns))):
        _,addr2,asm2,_=insns[k]
        if re.search(r"\b(ret|br)\b", asm2):
            break
        madd=re.search(r"\badd\s+(x\d+),\s*(x\d+),\s*#(?:0x)?([0-9a-fA-F]+)", asm2)
        if madd and madd.group(2)==reg:
            imm=int(madd.group(3),16)
            dest=page+imm
            if dest in target_addrs:
                xrefs.append((j, f"adrp_add target=0x{dest:x} via={reg} add_at=0x{addr2:x}"))
        madd_dec=re.search(r"\badd\s+(x\d+),\s*(x\d+),\s*#([0-9]+)\b", asm2)
        if madd_dec and madd_dec.group(2)==reg:
            imm=int(madd_dec.group(3),10)
            dest=page+imm
            if dest in target_addrs:
                xrefs.append((j, f"adrp_add_dec target=0x{dest:x} via={reg} add_at=0x{addr2:x}"))

for j,(line_idx,addr,asm,rawline) in enumerate(insns):
    m=re.search(r"\badrp\s+(x\d+),\s*(?:#)?(?:0x)?([0-9a-fA-F]+)", asm)
    if not m: continue
    try: page=int(m.group(2),16)
    except ValueError: continue
    for t in target_addrs:
        if (t & ~0xfff) == (page & ~0xfff):
            xrefs.append((j, f"adrp_same_page candidate_target=0x{t:x} via={m.group(1)}"))

uniq=[]
seen_x=set()
for item in xrefs:
    if item not in seen_x:
        seen_x.add(item); uniq.append(item)
print(f"DISASM_XREF_CANDIDATE_COUNT={len(uniq)}")
for num,(j,reason) in enumerate(uniq[:80]):
    _,addr,_,_=insns[j]
    print(f"XREF_CANDIDATE[{num}] at=0x{addr:x} reason={reason}")
    lo=max(0,j-8); hi=min(len(insns),j+18)
    for q in range(lo,hi):
        marker=">>" if q==j else "  "
        print(marker + insns[q][3])
    print("---")
PY
}

binary_audit(){
    local label="$1" base="$2" expected_sha="$3" method="$4"
    local sys inf disasm rc f

    section "$label artifact inventory"
    mapfile -t artifacts < <(find_exact_artifacts "$base")
    say "${label}_artifact_count=${#artifacts[@]}"
    for f in "${artifacts[@]}"; do
        say "artifact=$f"
        file "$f" 2>/dev/null || true
        sha256sum "$f" 2>/dev/null || true
    done

    sys="$(pick_canonical_sys "$base" "$expected_sha")"
    inf="$(pick_canonical_inf "$base")"
    say "${label}_canonical_sys=${sys:-NOT_FOUND}"
    say "${label}_canonical_inf=${inf:-NOT_FOUND}"
    say "${label}_expected_sha256=$expected_sha"

    if [[ -z "$sys" || ! -r "$sys" ]]; then
        say "${label}_binary_analysis=SKIPPED_NO_SYS"
        return 0
    fi

    say "${label}_canonical_sha256=$(sha256sum "$sys" | awk '{print $1}')"
    stat -c "${label}_size=%s" "$sys" 2>/dev/null || true

    if [[ -n "$inf" && -r "$inf" ]]; then
        section "$label INF focus"
        grep -Ein -A4 -B4 \
            'QCOM0C0B|QCOM0C2B|QCOM0CD3|AddService|ServiceBinary|Class|DeviceDesc|HardwareId' \
            "$inf" 2>/dev/null | head -n 360 || true
    fi

    section "$label PE headers/sections"
    "$OBJDUMP" -h "$sys" 2>&1 | head -n 220 || true
    "$OBJDUMP" -x "$sys" 2>&1 |
        grep -Ei -A6 -B3 \
            'file format|architecture:|ImageBase|Sections:|DLL Name:|Wdf|HAL|ACPI|Resource|Debug Directory|RSDS|pdb' |
        head -n 460 || true

    section "$label strings focus"
    strings -a -t x "$sys" 2>/dev/null |
        grep -Ei \
            'CONF|PMCF|AeiB|SPMI|PMIC|ACPI|RESOURCE_HUB|Device\.c|Queue\.c|PDB|interrupt|channel|arbiter|slave|usid|sid' |
        head -n 600 || true
    strings -el -t x "$sys" 2>/dev/null |
        grep -Ei \
            'CONF|PMCF|AeiB|SPMI|PMIC|ACPI|RESOURCE_HUB|interrupt|channel|arbiter|slave|usid|sid' |
        head -n 400 || true

    disasm="$SCRATCH/${label}.disasm.txt"
    section "$label disassembly generation"
    set +e
    "$OBJDUMP" -d -w "$sys" >"$disasm" 2>"$SCRATCH/${label}.disasm.err"
    rc=$?
    set -e
    say "${label}_objdump_disasm_exit=$rc"
    say "${label}_objdump=$OBJDUMP"
    say "${label}_disasm_bytes=$(stat -c %s "$disasm" 2>/dev/null || echo 0)"
    if [[ -s "$SCRATCH/${label}.disasm.err" ]]; then
        sed -n '1,120p' "$SCRATCH/${label}.disasm.err"
    fi
    if [[ $rc -ne 0 || ! -s "$disasm" ]]; then
        say "${label}_static_xref=SKIPPED_DISASM_FAILED"
        return 0
    fi

    section "$label PE/string/xref correlation"
    pe_static_xref_analysis "$label" "$sys" "$disasm" "$method"

    section "$label direct disassembly keyword/immediate focus"
    grep -Ein -A10 -B10 \
        '0c400000|c400000|00500000|500000|0c42d000|c42d000|0c432000|c432000|0c4c0000|c4c0000|0c4d0000|c4d0000' \
        "$disasm" 2>/dev/null | head -n 1000 || true
}

firmware_contract_reference(){
    section "factory firmware contract reference"
    python3 <<'PY'
import struct

conf = bytes.fromhex(
    "00 01 01 03 7f 00 03 80 0b 08 08 0a 03 7f 1c 01 "
    "00 02 0c 40 00 00 00 50 00 00 "
    "00 01 01 00 7f 00 00 80 03 00 00 0a 00 7f 04 01 "
    "00 02 0c 40 00 00 00 50 00 00"
)
print(f"CONF_TOTAL_LEN={len(conf)}")
print("CONF_HEX=" + conf.hex())
if len(conf) == 52:
    print("CONF_26_BYTE_RECORD_SPLIT=EXACT")
    for i in range(2):
        r=conf[i*26:(i+1)*26]
        print(f"CONF_RECORD_{i}_HEX={r.hex()}")
        print(f"CONF_RECORD_{i}_TAIL8={r[-8:].hex()}")
        print(f"CONF_RECORD_{i}_TAIL_BE32_A=0x{struct.unpack('>I',r[-8:-4])[0]:08x}")
        print(f"CONF_RECORD_{i}_TAIL_BE32_B=0x{struct.unpack('>I',r[-4:])[0]:08x}")
else:
    print("CONF_26_BYTE_RECORD_SPLIT=NO")

pmcf_first = [
    0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x10,
    0x08,0x09,0x10,0x10,0x0c,0x10,0x10,0x10,
    0x10,0x10,0x10,0x10,0x10,0x15,0x10,0x10,
    0x18,0x19,0x1a,0x10,
]
pmcf = [(x,0x10) for x in pmcf_first]
print(f"PMCF_DECLARED_COUNT=0x1c")
print(f"PMCF_PAIR_COUNT={len(pmcf)}")
for i,(a,b) in enumerate(pmcf):
    print(f"PMCF_PAIR[{i:02d}]=0x{a:02x},0x{b:02x}")
print("PMCF_NON_0x10_FIRST=" + ",".join(f"0x{x:02x}" for x in pmcf_first if x != 0x10))
print("NOTE=PMCF field semantics are intentionally not assumed here; qcpmic8380 static analysis is the decoder target")
PY

    section "known-good DT correlation constants"
    cat <<'EOF'
DT_ARB_COMPAT=qcom,x1e80100-spmi-pmic-arb
DT_CHANNEL=0
DT_EE=0
DT_CORE=0x0c400000+0x3000
DT_CHNLS=0x0c500000+0x400000
DT_OBSRVR=0x0c440000+0x80000
DT_BUS0_CNFG=0x0c42d000+0x4000
DT_BUS0_INTR=0x0c4c0000+0x10000
DT_BUS0_PDC_HWIRQ=1
DT_BUS1_CNFG=0x0c432000+0x4000
DT_BUS1_INTR=0x0c4d0000+0x10000
DT_BUS1_PDC_HWIRQ=3
ACPI_SPMI_CRS=0x0c400000+0x500000
EOF
}

compare_duplicate_builds(){
    local base="$1" label="$2" expected_sha="$3" f sha
    section "$label duplicate-build comparison"
    declare -A bysha=()
    while IFS= read -r f; do
        [[ -r "$f" && "${f,,}" == *.sys ]] || continue
        sha="$(sha256sum "$f" | awk '{print $1}')"
        bysha["$sha"]="${bysha[$sha]:-}${bysha[$sha]:+$'\n'}$f"
    done < <(find_exact_artifacts "$base")
    say "${label}_distinct_sys_sha_count=${#bysha[@]}"
    for sha in "${!bysha[@]}"; do
        say "SHA256=$sha expected=$([[ "$sha" == "$expected_sha" ]] && echo true || echo false)"
        printf '%s\n' "${bysha[$sha]}"
    done
}

audit(){
    SCRATCH="$(mktemp -d /tmp/a14-root15b-qcbin.XXXXXX)"
    {
        say "A14_ACPI_ROOT15B_ENTERED=1"
        say "timestamp=$(date -Is)"
        say "owner=$OWNER"
        say "running_kernel=$(uname -r 2>/dev/null || true)"
        say "objdump=$OBJDUMP"
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

        firmware_contract_reference

        binary_audit \
            QCSPMI qcspmi8380 \
            10de4b33be2dfa2ef1b0ac5f0275933bd755d32bc1ac7f120149479ddaca2f56 \
            CONF

        binary_audit \
            QCPMIC qcpmic8380 \
            1bc74b8390202cb0c22b39e2633e1dadc0c4a41481d893c0e3727df70c697435 \
            PMCF

        compare_duplicate_builds \
            qcspmi8380 QCSPMI \
            10de4b33be2dfa2ef1b0ac5f0275933bd755d32bc1ac7f120149479ddaca2f56

        compare_duplicate_builds \
            qcpmic8380 QCPMIC \
            1bc74b8390202cb0c22b39e2633e1dadc0c4a41481d893c0e3727df70c697435

        section "ROOT15B summary markers"
        say "A14_ACPI_ROOT15B_FIRMWARE_REFERENCE=COMPLETE"
        say "A14_ACPI_ROOT15B_QCSPMI_STATIC_AUDIT=COMPLETE"
        say "A14_ACPI_ROOT15B_QCPMIC_STATIC_AUDIT=COMPLETE"
        say "A14_ACPI_ROOT15B_BINARY_AUDIT=PASS"
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
    } >"$REPORT" 2>&1

    cleanup
    SCRATCH=""
    chown "$OWNER:$OWNER" "$REPORT" 2>/dev/null || true

    say "A14_ACPI_ROOT15B_BINARY_AUDIT=PASS"
    say "report=$REPORT"
    say "persistent_mutations=report_only"
    say "reboot_performed=false"
}

audit
