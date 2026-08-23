#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# ACPI ROOT16: minimal X1E80100 PDC irqdomain bootstrap from QCOM0C0C/GIO0.
#
# This milestone deliberately does NOT add ACPI SPMI or PMIC consumers.
# The PDC ACPI initializer preserves existing firmware PDC line state and
# only creates the hierarchy needed for the next milestone.
#
# Safety invariants:
#   * prepare always clears and leaves GRUB next_entry UNARMED
#   * arm sets one one-shot entry only and NEVER reboots
#   * experimental cmdline contains panic=0
#   * Image-only: no modules, modules_install, DKMS, initramfs rebuild
#   * ROOT11 kernel/initrd and persistent saved_entry are never replaced
set -euo pipefail

ACTION="${1:-}"
OWNER="${SUDO_USER:-}"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
section(){ printf '\n===== %s =====\n' "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }

[[ "$ACTION" == prepare || "$ACTION" == arm || "$ACTION" == status ]] ||
    die "usage: $0 {prepare|arm|status}"
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"
[[ -n "$OWNER" && "$OWNER" != root ]] || die "run with sudo from your normal login"

OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
OWNER_GROUP="$(id -gn "$OWNER")"
[[ -d "$OWNER_HOME" ]] || die "cannot resolve owner home"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="${A14_74C9_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="${A14_KERNEL_SRC:-$WORK/linux-7.1.5}"
DEFAULT_OUT="$WORK/root16-build"
OUT="${A14_KERNEL_OUT:-$DEFAULT_OUT}"
[[ "$OUT" == "$DEFAULT_OUT" ]] || die "ROOT16 requires dedicated output tree: $DEFAULT_OUT"

ARCH_NAME="${A14_ARCH:-arm64}"
JOBS="${A14_JOBS:-$(nproc)}"
ROOT11_KREL="${A14_ROOT11_KREL:-7.1.5-a14-acpi-root11}"
ROOT16_KREL="${A14_ROOT16_KREL:-7.1.5-a14-acpi-root16}"
ROOT11_CONFIG="${A14_ROOT11_CONFIG:-/boot/config-$ROOT11_KREL}"
ROOT11_INITRD="${A14_ROOT11_INITRD:-/boot/initrd.img-$ROOT11_KREL}"
ROOT16_IMAGE="/boot/vmlinuz-$ROOT16_KREL"
ROOT16_CONFIG="/boot/config-$ROOT16_KREL"
ROOT16_SYSTEM_MAP="/boot/System.map-$ROOT16_KREL"
TRANSFORM="$ROOT/scripts/apply-a14-acpi-root16-pdc-domain.py"
GRUB_CFG="${A14_GRUB_CFG:-/boot/grub/grub.cfg}"
GRUBENV="${A14_GRUBENV:-/boot/grub/grubenv}"
GRUB_FRAGMENT="${A14_ROOT16_GRUB_FRAGMENT:-/etc/grub.d/42_a14_acpi_root16}"
ENTRY_TITLE="${A14_ROOT16_ENTRY_TITLE:-ASUS Zenbook A14 ACPI ROOT16 PDC ($ROOT16_KREL)}"
PREP_REPORT="$OWNER_HOME/Downloads/a14-acpi-root16-prepare.txt"
STATUS_REPORT="$OWNER_HOME/Downloads/a14-acpi-root16-status.txt"

as_user(){ sudo -u "$OWNER" env HOME="$OWNER_HOME" LOCALVERSION= "$@"; }

cfg_val(){
    local cfg="$1" sym="$2"
    grep -E "^(CONFIG_${sym}=|# CONFIG_${sym} is not set)" "$cfg" | tail -n1 || true
}

assert_cfg(){
    local cfg="$1" sym="$2" expected="$3" got
    got="$(cfg_val "$cfg" "$sym")"
    case "$expected" in
        y|m) [[ "$got" == "CONFIG_${sym}=${expected}" ]] ||
                 die "Kconfig assertion failed: $sym expected=$expected got=${got:-MISSING}" ;;
        n) [[ "$got" == "# CONFIG_${sym} is not set" ]] ||
               die "Kconfig assertion failed: $sym expected=n got=${got:-MISSING}" ;;
        *) die "internal bad expected config state: $expected" ;;
    esac
    say "ASSERT_CONFIG_${sym}=$expected"
}

clear_next_entry(){
    [[ -f "$GRUBENV" ]] && grub-editenv "$GRUBENV" unset next_entry >/dev/null 2>&1 || true
}

assert_unarmed(){
    local envtxt=""
    [[ -f "$GRUBENV" ]] && envtxt="$(grub-editenv "$GRUBENV" list 2>/dev/null || true)"
    if grep -q '^next_entry=' <<<"$envtxt"; then
        printf '%s\n' "$envtxt" >&2
        die "GRUB next_entry remains armed"
    fi
    say "A14_ACPI_ROOT16_GRUB_NEXT_ENTRY=UNARMED"
}

extract_root11_clone(){
    python3 - "$GRUB_CFG" "$ROOT11_KREL" "$ROOT16_KREL" "$ENTRY_TITLE" <<'PY'
import re, sys
from pathlib import Path
cfg, old, new, title = sys.argv[1:]
lines = Path(cfg).read_text(errors="replace").splitlines()
needle = f"vmlinuz-{old}"
cands=[]
for i,line in enumerate(lines):
    if needle not in line or not re.match(r"^\s*linux(?:efi)?\s+", line):
        continue
    start=next((j for j in range(i,-1,-1) if re.match(r"^\s*menuentry\s+",lines[j])),None)
    end=next((j for j in range(i+1,len(lines)) if re.match(r"^\s*}\s*$",lines[j])),None)
    if start is None or end is None: continue
    block=lines[start:end+1]
    low="\n".join(block).lower()
    if "recovery mode" in block[0].lower() or " recovery" in low or " single" in low: continue
    if any(re.match(r"^\s*devicetree\s+",x) for x in block):
        continue
    cands.append((start,block))
if not cands:
    raise SystemExit("no safe ROOT11 GRUB stanza found")
cands.sort(key=lambda x:(1 if lines[x[0]][:1].isspace() else 0,x[0]))
block=cands[0][1]
idx=[i for i,x in enumerate(block) if needle in x and re.match(r"^\s*linux(?:efi)?\s+",x)]
if len(idx)!=1: raise SystemExit(f"expected one ROOT11 linux line, got {len(idx)}")
i=idx[0]
block[i]=block[i].replace(f"vmlinuz-{old}",f"vmlinuz-{new}",1)
if not re.search(r"(^|\s)panic=0(\s|$)",block[i]): block[i]=block[i].rstrip()+" panic=0"
m=re.match(r"^(\s*menuentry\s+)(['\"])(.*?)(\2)(.*)$",block[0])
if not m: raise SystemExit("cannot parse menuentry header")
q=m.group(2)
block[0]=f"{m.group(1)}{q}{title}{q}{m.group(5)}".replace(old,new)
print("\n".join(block))
PY
}

write_grub_fragment(){
    local stanza tmp
    stanza="$(extract_root11_clone)"
    [[ -n "$stanza" ]] || die "ROOT11 stanza clone empty"
    tmp="$(mktemp /tmp/a14-root16-grub.XXXXXX)"
    {
        printf '%s\n' '#!/bin/sh'
        printf '%s\n' '# Generated by a14-acpi-root16-pdc-domain-one-go.sh'
        printf '%s\n' 'exec tail -n +4 "$0"'
        printf '%s\n' '# A14_ACPI_ROOT16_GRUB_FRAGMENT'
        printf '%s\n' "$stanza"
    } >"$tmp"
    if [[ -e "$GRUB_FRAGMENT" ]] &&
       ! grep -q 'A14_ACPI_ROOT16_GRUB_FRAGMENT' "$GRUB_FRAGMENT" 2>/dev/null; then
        rm -f "$tmp"
        die "refusing to overwrite foreign GRUB fragment: $GRUB_FRAGMENT"
    fi
    install -m0755 "$tmp" "$GRUB_FRAGMENT"
    rm -f "$tmp"
}

verify_grub_entry(){
    python3 - "$GRUB_CFG" "$ROOT16_KREL" "$ENTRY_TITLE" "$ROOT11_KREL" <<'PY'
import re,sys
from pathlib import Path
cfg,krel,title,root11=sys.argv[1:]
lines=Path(cfg).read_text(errors="replace").splitlines(); needle=f"vmlinuz-{krel}"; hits=[]
for i,line in enumerate(lines):
    if needle not in line or not re.match(r"^\s*linux(?:efi)?\s+",line): continue
    s=next((j for j in range(i,-1,-1) if re.match(r"^\s*menuentry\s+",lines[j])),None)
    e=next((j for j in range(i+1,len(lines)) if re.match(r"^\s*}\s*$",lines[j])),None)
    if s is None or e is None: continue
    b=lines[s:e+1]
    if title in b[0]: hits.append(b)
if len(hits)!=1: raise SystemExit(f"expected one ROOT16 entry, found {len(hits)}")
b=hits[0]
if any(re.match(r"^\s*devicetree\s+",x) for x in b): raise SystemExit("ROOT16 contains devicetree")
linux=[x for x in b if needle in x and re.match(r"^\s*linux(?:efi)?\s+",x)]
if len(linux)!=1 or not re.search(r"(^|\s)panic=0(\s|$)",linux[0]): raise SystemExit("ROOT16 panic=0 check failed")
if not any(re.match(r"^\s*initrd(?:efi)?\s+",x) and root11 in x for x in b): raise SystemExit("ROOT16 does not retain ROOT11 initrd")
print("A14_ACPI_ROOT16_GRUB_ENTRY=PASS")
print(f"entry_title={title}")
print(linux[0].strip())
PY
}

prepare(){
    for c in bash cat chown cp date diff file getent grep grub-editenv install make mktemp \
             nproc python3 sed sha256sum stat sudo sync tee update-grub; do
        have "$c" || die "missing command: $c"
    done
    [[ -d "$SRC" && -f "$SRC/Makefile" ]] || die "kernel source missing: $SRC"
    [[ -x "$SRC/scripts/config" ]] || die "kernel scripts/config missing"
    [[ -r "$ROOT11_CONFIG" ]] || die "ROOT11 config missing: $ROOT11_CONFIG"
    [[ -r "$ROOT11_INITRD" ]] || die "ROOT11 initrd missing: $ROOT11_INITRD"
    [[ -r "$TRANSFORM" ]] || die "ROOT16 transform missing: $TRANSFORM"
    [[ -r "$GRUB_CFG" ]] || die "GRUB config missing: $GRUB_CFG"

    install -d -o "$OWNER" -g "$OWNER_GROUP" "$OUT"

    {
        say "A14_ACPI_ROOT16_PREPARE_ENTERED=1"
        say "timestamp=$(date -Is)"
        say "owner=$OWNER"
        say "src=$SRC"
        say "out=$OUT"
        say "root11_config=$ROOT11_CONFIG"
        say "root11_initrd=$ROOT11_INITRD"
        say "root16_krel=$ROOT16_KREL"
        say "image_only=true"
        say "pdc_child_irq_allocation=false"
        say "pdc_probe_state_policy=preserve"
        say "kernel_source_mutation=true"
        say "kernel_source_transform=idempotent_ROOT16"
        say "module_build=false"
        say "modules_install=false"
        say "initramfs_update=false"
        say "reboot_performed=false"

        section "safety: unarm before source/build work"
        clear_next_entry
        assert_unarmed

        section "source hashes before ROOT16 transform"
        for rel in drivers/irqchip/qcom-pdc.c include/linux/soc/qcom/irq.h drivers/pinctrl/qcom/pinctrl-x1e80100.c; do
            sha256sum "$SRC/$rel"
        done

        section "apply idempotent ROOT16 source transform"
        as_user python3 "$TRANSFORM" "$SRC"
        grep -Fq 'A14_ROOT16_PDC_ACPI_DOMAIN' "$SRC/drivers/irqchip/qcom-pdc.c" || die "PDC ROOT16 marker absent"
        grep -Fq 'qcom_pdc_acpi_init' "$SRC/drivers/pinctrl/qcom/pinctrl-x1e80100.c" || die "X1E ROOT16 call absent"
        grep -Fq 'preserve_state=1' "$SRC/drivers/irqchip/qcom-pdc.c" || die "PDC preserve-state marker absent"

        section "source hashes after ROOT16 transform"
        for rel in drivers/irqchip/qcom-pdc.c include/linux/soc/qcom/irq.h drivers/pinctrl/qcom/pinctrl-x1e80100.c; do
            sha256sum "$SRC/$rel"
        done

        section "seed known-good ROOT11 config"
        cp -- "$ROOT11_CONFIG" "$OUT/.config"
        chown "$OWNER:$OWNER_GROUP" "$OUT/.config"
        as_user "$SRC/scripts/config" --file "$OUT/.config" --set-str LOCALVERSION "-a14-acpi-root16"
        as_user "$SRC/scripts/config" --file "$OUT/.config" --disable LOCALVERSION_AUTO
        as_user "$SRC/scripts/config" --file "$OUT/.config" --enable QCOM_PDC
        as_user "$SRC/scripts/config" --file "$OUT/.config" --enable ACPI
        as_user "$SRC/scripts/config" --file "$OUT/.config" --enable PINCTRL_X1E80100
        as_user make -s -C "$SRC" O="$OUT" ARCH="$ARCH_NAME" olddefconfig

        section "ROOT16 config assertions"
        assert_cfg "$OUT/.config" QCOM_PDC y
        assert_cfg "$OUT/.config" ACPI y
        assert_cfg "$OUT/.config" PINCTRL y
        assert_cfg "$OUT/.config" PINCTRL_MSM y
        assert_cfg "$OUT/.config" PINCTRL_X1E80100 y
        assert_cfg "$OUT/.config" IRQ_DOMAIN y
        assert_cfg "$OUT/.config" IRQ_DOMAIN_HIERARCHY y
        assert_cfg "$OUT/.config" AUTOFS_FS y
        assert_cfg "$OUT/.config" I2C_CHARDEV y
        assert_cfg "$OUT/.config" I2C_QCOM_CCI y

        section "ROOT11 -> ROOT16 config delta"
        diff -u "$ROOT11_CONFIG" "$OUT/.config" || true

        section "regenerate release metadata"
        rm -f "$OUT/include/config/kernel.release" \
              "$OUT/include/generated/utsrelease.h" \
              "$OUT/include/generated/compile.h"
        as_user make -s -C "$SRC" O="$OUT" ARCH="$ARCH_NAME" prepare
        local actual_krel
        actual_krel="$(as_user make -s -C "$SRC" O="$OUT" ARCH="$ARCH_NAME" kernelrelease)"
        say "kernelrelease=$actual_krel"
        [[ "$actual_krel" == "$ROOT16_KREL" ]] ||
            die "unexpected kernelrelease expected=$ROOT16_KREL got=$actual_krel"

        section "targeted built-in object compile"
        rm -f "$OUT/drivers/irqchip/qcom-pdc.o" "$OUT/drivers/irqchip/.qcom-pdc.o.cmd" \
              "$OUT/drivers/pinctrl/qcom/pinctrl-x1e80100.o" "$OUT/drivers/pinctrl/qcom/.pinctrl-x1e80100.o.cmd"
        as_user make -C "$SRC" O="$OUT" ARCH="$ARCH_NAME" -j"$JOBS" \
            drivers/irqchip/qcom-pdc.o drivers/pinctrl/qcom/pinctrl-x1e80100.o
        say "A14_ACPI_ROOT16_OBJECT_BUILD=PASS"

        section "Image-only build"
        as_user make -C "$SRC" O="$OUT" ARCH="$ARCH_NAME" -j"$JOBS" Image
        local image="$OUT/arch/arm64/boot/Image"
        local vmlinux="$OUT/vmlinux"
        [[ -s "$image" && -s "$vmlinux" ]] || die "ROOT16 Image/vmlinux missing"
        grep -aFq 'A14ROOT16_PDC_ACPI: domain-ready' "$vmlinux" || die "compiled vmlinux lacks ROOT16 PDC marker"
        grep -aFq 'ACPI GIC domains use full GSIs' "$SRC/drivers/irqchip/qcom-pdc.c" || die "PDC ACPI parent-fwspec adaptation missing"
        file "$image" || true
        stat "$image"
        sha256sum "$image" "$vmlinux"

        section "install ROOT16 Image/config only"
        install -m0644 "$image" "$ROOT16_IMAGE"
        install -m0644 "$OUT/.config" "$ROOT16_CONFIG"
        [[ -s "$OUT/System.map" ]] && install -m0644 "$OUT/System.map" "$ROOT16_SYSTEM_MAP" || true
        sync
        stat "$ROOT16_IMAGE" "$ROOT16_CONFIG"
        sha256sum "$ROOT16_IMAGE" "$ROOT16_CONFIG"

        section "clone proven ROOT11 GRUB stanza"
        write_grub_fragment
        clear_next_entry
        update-grub
        clear_next_entry
        verify_grub_entry
        assert_unarmed

        section "ROOT16 prepare summary"
        say "A14_ACPI_ROOT16_SOURCE_TRANSFORM=PASS"
        say "A14_ACPI_ROOT16_CONFIG=PASS"
        say "A14_ACPI_ROOT16_IMAGE_BUILD=PASS"
        say "A14_ACPI_ROOT16_IMAGE_INSTALL=PASS"
        say "A14_ACPI_ROOT16_GRUB_CLONE=PASS"
        say "A14_ACPI_ROOT16_PREPARE=PASS"
        say "A14_ACPI_ROOT16_READY=UNARMED"
        say "reboot_performed=false"
        say "next_action=sudo bash scripts/a14-acpi-root16-pdc-domain-one-go.sh arm"
    } > >(tee "$PREP_REPORT") 2>&1

    chown "$OWNER:$OWNER_GROUP" "$PREP_REPORT" 2>/dev/null || true
}

arm(){
    for c in getent grep grub-editenv grub-reboot python3; do have "$c" || die "missing command: $c"; done
    [[ -s "$ROOT16_IMAGE" ]] || die "ROOT16 Image missing: $ROOT16_IMAGE"
    [[ -r "$GRUB_CFG" ]] || die "GRUB config missing"
    verify_grub_entry
    clear_next_entry
    assert_unarmed
    grub-reboot "$ENTRY_TITLE"
    local envtxt
    envtxt="$(grub-editenv "$GRUBENV" list 2>/dev/null || true)"
    printf '%s\n' "$envtxt"
    grep -q '^next_entry=' <<<"$envtxt" || die "grub-reboot did not set next_entry"
    grep -Fq "next_entry=$ENTRY_TITLE" <<<"$envtxt" || die "wrong one-shot entry was set"
    say "A14_ACPI_ROOT16_ARM=PASS"
    say "A14_ACPI_ROOT16_ONE_SHOT_SET=1"
    say "entry=$ENTRY_TITLE"
    say "reboot_performed=false"
    say "MANUAL_REBOOT_REQUIRED=1"
}

status(){
    for c in cat chown date find getent grep grub-editenv journalctl systemctl tee uname; do have "$c" || die "missing command: $c"; done
    {
        say "A14_ACPI_ROOT16_STATUS_ENTERED=1"
        say "timestamp=$(date -Is)"
        say "uname=$(uname -a)"
        say "running_kernel=$(uname -r)"
        say "expected_kernel=$ROOT16_KREL"
        say "cmdline=$(cat /proc/cmdline 2>/dev/null || true)"
        if [[ "$(uname -r)" == "$ROOT16_KREL" ]]; then
            say "A14_ACPI_ROOT16_BOOTED=PASS"
        else
            say "A14_ACPI_ROOT16_BOOTED=NO"
        fi

        section "ROOT16 kernel markers"
        local klog
        klog="$(journalctl -k -b --no-pager 2>/dev/null || true)"
        grep -E 'A14ROOT16_PDC_ACPI|A14GIO0|QCOM WoA GPIO|qcom.*pdc|[[:space:]]PDC[[:space:]]' <<<"$klog" | tail -n 500 || true
        if grep -Fq 'A14ROOT16_PDC_ACPI: domain-ready' <<<"$klog"; then
            say "A14_ACPI_ROOT16_PDC_DOMAIN=PASS"
        else
            say "A14_ACPI_ROOT16_PDC_DOMAIN=NO"
        fi
        if grep -Fq 'preserve_state=1' <<<"$klog"; then
            say "A14_ACPI_ROOT16_PDC_PRESERVE_STATE=PASS"
        else
            say "A14_ACPI_ROOT16_PDC_PRESERVE_STATE=NO"
        fi

        section "GIO0 and SPMI ACPI platform devices"
        find /sys/bus/platform/devices -maxdepth 1 \
            \( -name '*QCOM0C0C*' -o -name '*QCOM0C0B*' \) -printf '%f -> %l\n' 2>/dev/null || true

        section "PDC / PMIC IRQ observations"
        grep -E 'PDC|pmic_arb' /proc/interrupts 2>/dev/null || true
        if grep -Eq 'PDC[[:space:]]+(1|3)[[:space:]]' /proc/interrupts 2>/dev/null; then
            say "A14_ACPI_ROOT16_UNEXPECTED_PDC_CHILD_IRQ=YES"
        else
            say "A14_ACPI_ROOT16_UNEXPECTED_PDC_CHILD_IRQ=NO"
        fi

        section "running config"
        local cfg="/boot/config-$(uname -r)"
        if [[ -r "$cfg" ]]; then
            for sym in QCOM_PDC ACPI PINCTRL_X1E80100 SPMI SPMI_MSM_PMIC_ARB MFD_SPMI_PMIC; do
                say "$sym=$(cfg_val "$cfg" "$sym")"
            done
        fi

        section "failed units"
        systemctl --failed --no-pager 2>/dev/null || true

        section "GRUB one-shot state after boot"
        [[ -f "$GRUBENV" ]] && grub-editenv "$GRUBENV" list 2>/dev/null || true

        say "A14_ACPI_ROOT16_STATUS=PASS"
        say "pdc_child_irq_allocation_expected=false"
        say "service_mutation=false"
        say "reboot_performed=false"
    } > >(tee "$STATUS_REPORT") 2>&1
    chown "$OWNER:$OWNER_GROUP" "$STATUS_REPORT" 2>/dev/null || true
}

case "$ACTION" in
    prepare) prepare ;;
    arm) arm ;;
    status) status ;;
esac
