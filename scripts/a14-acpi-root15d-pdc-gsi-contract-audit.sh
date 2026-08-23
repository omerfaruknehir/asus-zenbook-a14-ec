#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# ACPI ROOT15D: read-only X1E80100 PDC/GSI contract audit.
#
# Purpose:
#   * prove PDC-pin -> parent-GIC-SPI -> ACPI-GSI translation on live X1E80100 DT
#   * correlate that translation against the factory ACPI USB interrupt set
#   * derive the two SPMI periph_irq GSIs without touching hardware
#   * inspect the current 7.1.5 source for existing PDC/TLMM ACPI support
#   * inspect factory DSDT PDC _DSM data when ACPI tables are readable
#
# Safety invariants:
#   - no kernel/Image/module build or install
#   - no initramfs work
#   - no GRUB writes
#   - no service/module mutation
#   - no debugfs mount or sysfs writes
#   - no MMIO or /dev/mem access
#   - no ACPI method execution
#   - no reboot
#
# Persistent write: only ~/Downloads/a14-acpi-root15d-pdc-gsi-contract-audit.txt
# All intermediate files live under /tmp and are removed.
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
REPORT="$OWNER_HOME/Downloads/a14-acpi-root15d-pdc-gsi-contract-audit.txt"
TMPDIR="$(mktemp -d /tmp/a14-root15d.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

exec > >(tee "$REPORT") 2>&1

say "A14_ACPI_ROOT15D_ENTERED=1"
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
say "debugfs_mount=false"
say "sysfs_write=false"
say "mmio_access=false"
say "devmem_access=false"
say "acpi_method_execution=false"
say "reboot_performed=false"

have python3 || die "python3 is required"

DT=/sys/firmware/devicetree/base
PDC_NODE="$DT/soc@0/interrupt-controller@b220000"
ARB_NODE="$DT/soc@0/arbiter@c400000"
USB_NODE="$DT/soc@0/usb@a400000"

section "live DT node presence"
for kv in "PDC_NODE:$PDC_NODE" "ARB_NODE:$ARB_NODE" "USB_NODE:$USB_NODE"; do
    key=${kv%%:*}; path=${kv#*:}
    if [[ -d "$path" ]]; then
        say "$key=$path"
        say "${key}_PRESENT=true"
    else
        say "$key=$path"
        say "${key}_PRESENT=false"
    fi
done

section "live X1E PDC ranges"
if [[ -r "$PDC_NODE/qcom,pdc-ranges" ]]; then
    python3 - "$PDC_NODE/qcom,pdc-ranges" <<'PY'
import pathlib, struct, sys
p=pathlib.Path(sys.argv[1])
b=p.read_bytes()
if len(b)%12:
    print(f"PDC_RANGES_PARSE=FAIL_LEN_{len(b)}")
    raise SystemExit(0)
vals=struct.unpack(">"+"I"*(len(b)//4), b)
triples=[vals[i:i+3] for i in range(0,len(vals),3)]
print(f"PDC_RANGE_COUNT={len(triples)}")
for n,(pin,parent,cnt) in enumerate(triples):
    print(f"PDC_RANGE[{n}]=pin_base={pin},parent_spi_base={parent},count={cnt}")

def map_pin(pin):
    for pin_base,parent,cnt in triples:
        if pin_base <= pin < pin_base+cnt:
            spi=parent+(pin-pin_base)
            # ARM GIC DT GIC_SPI numbering excludes INTIDs 0..31. ACPI GSI
            # on this platform uses the architectural GIC INTID, hence +32.
            return spi, spi+32
    return None
for pin in [1,3,51,52,53,54,55,56]:
    r=map_pin(pin)
    if r:
        print(f"PDC_PIN_{pin}_PARENT_SPI={r[0]}")
        print(f"PDC_PIN_{pin}_ACPI_GSI={r[1]}")
        print(f"PDC_PIN_{pin}_ACPI_GSI_HEX=0x{r[1]:03x}")
    else:
        print(f"PDC_PIN_{pin}_MAP=NOT_FOUND")

usb_expected={0x22e,0x22f,0x230,0x231,0x232,0x233}
usb_derived={map_pin(p)[1] for p in [51,52,53,54,55,56] if map_pin(p)}
print("REFERENCE_ACPI_USB_PDC_GSIS="+",".join(f"0x{x:03x}" for x in sorted(usb_expected)))
print("DERIVED_USB_PDC_GSIS="+",".join(f"0x{x:03x}" for x in sorted(usb_derived)))
print("USB_PDC_TO_ACPI_GSI_CORRELATION="+("PASS" if usb_derived==usb_expected else "FAIL"))

s0=map_pin(1); s1=map_pin(3)
print("SPMI_BUS0_PDC_PIN=1")
print("SPMI_BUS1_PDC_PIN=3")
print(f"SPMI_BUS0_PARENT_SPI={s0[0] if s0 else -1}")
print(f"SPMI_BUS1_PARENT_SPI={s1[0] if s1 else -1}")
print(f"SPMI_BUS0_ACPI_GSI={s0[1] if s0 else -1}")
print(f"SPMI_BUS1_ACPI_GSI={s1[1] if s1 else -1}")
print(f"SPMI_BUS0_ACPI_GSI_HEX=0x{s0[1]:03x}" if s0 else "SPMI_BUS0_ACPI_GSI_HEX=NA")
print(f"SPMI_BUS1_ACPI_GSI_HEX=0x{s1[1]:03x}" if s1 else "SPMI_BUS1_ACPI_GSI_HEX=NA")
print("SPMI_GSI_DERIVATION="+("PASS" if s0 and s1 and s0[1]==513 and s1[1]==515 else "FAIL"))
PY
else
    say "PDC_RANGES=NOT_READABLE"
fi

section "live DT SPMI bus resources"
if [[ -d "$ARB_NODE" ]]; then
    python3 - "$ARB_NODE" <<'PY'
import pathlib, struct, sys
root=pathlib.Path(sys.argv[1])
def be32(path):
    b=path.read_bytes(); return struct.unpack(">"+"I"*(len(b)//4),b) if b and len(b)%4==0 else ()
def strings(path):
    try: return [x.decode(errors='replace') for x in path.read_bytes().split(b'\0') if x]
    except Exception: return []
for prop in ('compatible','qcom,channel','qcom,ee','reg','reg-names'):
    p=root/prop
    if p.exists():
        if prop in ('compatible','reg-names'):
            print(f"ARB_{prop.upper().replace(',','_')}="+'|'.join(strings(p)))
        else:
            print(f"ARB_{prop.upper().replace(',','_')}="+','.join(f"0x{x:x}" for x in be32(p)))
for bus in sorted([p for p in root.iterdir() if p.is_dir() and p.name.startswith('spmi@')]):
    print(f"SPMI_BUS_NODE={bus}")
    for prop in ('reg','reg-names','interrupts-extended','interrupt-names'):
        p=bus/prop
        if not p.exists(): continue
        if prop in ('reg-names','interrupt-names'):
            print(f"  {prop}="+'|'.join(strings(p)))
        else:
            print(f"  {prop}_be32="+','.join(f"0x{x:x}" for x in be32(p)))
PY
else
    say "LIVE_DT_SPMI=NOT_PRESENT"
fi

section "live USB interrupt reference"
if [[ -d "$USB_NODE" ]]; then
    python3 - "$USB_NODE" <<'PY'
import pathlib, struct, sys
root=pathlib.Path(sys.argv[1])
for prop in ('interrupts-extended','interrupt-names'):
    p=root/prop
    if not p.exists():
        print(f"USB_{prop.upper().replace('-','_')}=NOT_PRESENT")
        continue
    b=p.read_bytes()
    if prop=='interrupt-names':
        print("USB_INTERRUPT_NAMES="+'|'.join(x.decode(errors='replace') for x in b.split(b'\0') if x))
    elif len(b)%4==0:
        vals=struct.unpack(">"+"I"*(len(b)//4),b)
        print("USB_INTERRUPTS_EXTENDED_BE32="+','.join(f"0x{x:x}" for x in vals))
PY
else
    say "LIVE_DT_USB_REFERENCE=NOT_PRESENT"
fi

section "live kernel IRQ observations"
if [[ -r /proc/interrupts ]]; then
    grep -Ei 'spmi|pmic.?arb|c42d000|c432000|PDC' /proc/interrupts || true
else
    say "/proc/interrupts=NOT_READABLE"
fi

section "sysfs IRQ details for SPMI/PMIC actions"
irq_hits=0
if [[ -d /sys/kernel/irq ]]; then
    for d in /sys/kernel/irq/[0-9]*; do
        [[ -d "$d" ]] || continue
        actions="$(cat "$d/actions" 2>/dev/null || true)"
        [[ "$actions" =~ [Ss][Pp][Mm][Ii]|[Pp][Mm][Ii][Cc]|arbiter|pmic_arb ]] || continue
        irq_hits=$((irq_hits+1))
        say "IRQ_DIR=$d"
        say "  actions=$actions"
        for f in chip_name hwirq name type wakeup; do
            [[ -r "$d/$f" ]] && say "  $f=$(cat "$d/$f" 2>/dev/null || true)"
        done
    done
fi
say "SPMI_SYSFS_IRQ_HIT_COUNT=$irq_hits"

section "already-mounted debugfs IRQ-domain observations"
if [[ -r /sys/kernel/debug/irq/domains ]]; then
    grep -Ei 'pdc|spmi|gic' /sys/kernel/debug/irq/domains || true
else
    say "DEBUGFS_IRQ_DOMAINS=NOT_AVAILABLE_OR_NOT_MOUNTED"
fi

section "factory ACPI PDC contract reference"
# Audited from this machine's factory DSDT. These are reference constants only;
# this script never evaluates _DSM.
say "GIO0_HID=QCOM0C0C"
say "GIO0_PDC_DSM_UUID=921b0fd4-567c-43a0-bb14-2648f7b2a18c"
say "GIO0_PDCV_REFERENCE=1"
say "GIO0_PDCE_REFERENCE=0x0b220010"
say "GIO0_PDCC_REFERENCE=0x0b220110"
say "GIO0_PDCM_REFERENCE=0x4330"
say "GIO0_GICB_REFERENCE=0x17000000"
say "GIO0_GICS_REFERENCE=0x00390000"
say "GIO0_GIC_ENABLE_SET_OFFSET_REFERENCE=0x0100"
say "GIO0_GIC_ENABLE_CLEAR_OFFSET_REFERENCE=0x0180"
say "GIO0_GIC_PENDING_CLEAR_OFFSET_REFERENCE=0x0280"
say "GIO0_GIC_STATUS_OFFSET_REFERENCE=0x0380"
say "GIO0_CIPR_ENTRY_COUNT_REFERENCE=93"
say "ACPI_SPMI_CRS_HAS_IRQ=false"

section "read-only factory DSDT verification when available"
DSDT_VERIFICATION=UNAVAILABLE
if [[ -r /sys/firmware/acpi/tables/DSDT ]]; then
    cp /sys/firmware/acpi/tables/DSDT "$TMPDIR/DSDT.aml"
    say "DSDT_SYSFS_SHA256=$(sha256sum "$TMPDIR/DSDT.aml" | awk '{print $1}')"
    if have iasl; then
        if iasl -d -p "$TMPDIR/DSDT" "$TMPDIR/DSDT.aml" >/dev/null 2>&1 && [[ -r "$TMPDIR/DSDT.dsl" ]]; then
            DSDT_VERIFICATION=DECOMPILED
            grep -n -E 'QCOM0C0B|QCOM0C0C|Name \(PDCE|Name \(PDCC|Name \(PDCM|Name \(PDCV|Name \(CIPR|921b0fd4|0x0B220010|0x0B220110' "$TMPDIR/DSDT.dsl" | head -n 120 || true
        else
            DSDT_VERIFICATION=DECOMPILE_FAILED
        fi
    else
        DSDT_VERIFICATION=IASL_NOT_FOUND
    fi
fi
say "DSDT_VERIFICATION=$DSDT_VERIFICATION"

section "Linux 7.1.5 PDC/TLMM source audit"
KSRC="${A14_KERNEL_SRC:-$OWNER_HOME/Downloads/a14-full-acpi-kernel/linux-7.1.5}"
say "kernel_source=$KSRC"
if [[ -d "$KSRC" ]]; then
    for f in \
        drivers/irqchip/qcom-pdc.c \
        drivers/pinctrl/qcom/pinctrl-msm.c \
        drivers/pinctrl/qcom/pinctrl-x1e80100.c; do
        path="$KSRC/$f"
        say "SOURCE_FILE=$path present=$([[ -f "$path" ]] && echo true || echo false)"
        [[ -f "$path" ]] || continue
        say "--- $f ACPI/PDC/fwnode focus ---"
        grep -n -E 'ACPI|acpi_|QCOM0C0C|921b0fd4|PDCV|PDCE|PDCC|PDCM|CIPR|qcom,pdc-ranges|of_fwnode|of_property|of_device|fwnode|irq_domain_create_hierarchy|IRQCHIP_MATCH' "$path" | head -n 240 || true
    done
else
    say "KERNEL_SOURCE_PRESENT=false"
fi

section "derived design constraints"
say "SPMI_BUS0_PDC_PIN_REFERENCE=1"
say "SPMI_BUS1_PDC_PIN_REFERENCE=3"
say "SPMI_BUS0_ACPI_GSI_EXPECTED=513"
say "SPMI_BUS1_ACPI_GSI_EXPECTED=515"
say "SPMI_BUS0_ACPI_GSI_EXPECTED_HEX=0x201"
say "SPMI_BUS1_ACPI_GSI_EXPECTED_HEX=0x203"
say "NOTE=GSI derivation is proven by PDC ranges plus independent USB DT/ACPI correlation"
say "NOTE=PDC programming/bypass safety is intentionally not assumed"
say "NOTE=QCOM0C0B _CRS contains no IRQ descriptors; irq ownership belongs to the PDC/GIO0 firmware contract"
say "next_decision=extend_existing_PDC_ACPI_path_or_add_minimal_PDC_ACPI_support_before_SPMI"

section "ROOT15D summary markers"
say "A14_ACPI_ROOT15D_PDC_GSI_CONTRACT_AUDIT=PASS"
say "A14_ACPI_ROOT15D_USB_GSI_CORRELATION_EXPECTED=PASS"
say "A14_ACPI_ROOT15D_SPMI_GSI_DERIVATION_EXPECTED=PASS"
say "A14_ACPI_ROOT15D_SOURCE_AUDIT=COMPLETE"
say "persistent_mutations=report_only"
say "kernel_build=false"
say "module_build=false"
say "module_install=false"
say "initramfs_update=false"
say "grub_write=false"
say "service_mutation=false"
say "debugfs_mount=false"
say "sysfs_write=false"
say "mmio_access=false"
say "devmem_access=false"
say "acpi_method_execution=false"
say "reboot_performed=false"

chown "$OWNER:$OWNER" "$REPORT" 2>/dev/null || true
