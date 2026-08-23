#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# ACPI ROOT14: Image-only Qualcomm flash dependency conversion.
#
# Purpose:
#   * start from the known-good ROOT11 kernel config
#   * make the SPMI/PMIC + LED flash class chain built-in
#   * deliberately disable V4L2_FLASH_LED_CLASS for this boot milestone
#     because VIDEO_DEV remains modular in ROOT11 and otherwise caps
#     LEDS_QCOM_FLASH at =m
#   * build Image only -- never build or install modules
#   * clone the already-proven ROOT11 GRUB stanza and replace only the
#     kernel image/title, retaining the ROOT11 initrd and boot semantics
#
# Safety invariants:
#   * prepare NEVER arms a boot and leaves grubenv next_entry unset
#   * arm ONLY sets a one-shot GRUB entry; it NEVER reboots
#   * every experimental boot command line contains panic=0
#   * no module build, modules_install, DKMS, initramfs rebuild, or service mutation
set -euo pipefail

ACTION="${1:-}"
OWNER="${SUDO_USER:-}"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
section(){ printf '\n===== %s =====\n' "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }

[[ -n "$ACTION" ]] || die "usage: $0 {prepare|arm|status}"
[[ "$ACTION" == prepare || "$ACTION" == arm || "$ACTION" == status ]] ||
    die "usage: $0 {prepare|arm|status}"
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"
[[ -n "$OWNER" && "$OWNER" != root ]] || die "run with sudo from your normal login"

OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
[[ -d "$OWNER_HOME" ]] || die "cannot resolve owner home"

WORK="${A14_74C9_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="${A14_KERNEL_SRC:-$WORK/linux-7.1.5}"
OUT="${A14_KERNEL_OUT:-$WORK/root0-build}"
ROOT11_KREL="${A14_ROOT11_KREL:-7.1.5-a14-acpi-root11}"
ROOT14_KREL="${A14_ROOT14_KREL:-7.1.5-a14-acpi-root14}"
ROOT11_CONFIG="${A14_ROOT11_CONFIG:-/boot/config-$ROOT11_KREL}"
ROOT11_INITRD="${A14_ROOT11_INITRD:-/boot/initrd.img-$ROOT11_KREL}"
ROOT14_IMAGE="/boot/vmlinuz-$ROOT14_KREL"
ROOT14_CONFIG="/boot/config-$ROOT14_KREL"
ROOT14_SYSTEM_MAP="/boot/System.map-$ROOT14_KREL"
GRUB_CFG="${A14_GRUB_CFG:-/boot/grub/grub.cfg}"
GRUBENV="${A14_GRUBENV:-/boot/grub/grubenv}"
GRUB_FRAGMENT="${A14_ROOT14_GRUB_FRAGMENT:-/etc/grub.d/42_a14_acpi_root14}"
ENTRY_TITLE="${A14_ROOT14_ENTRY_TITLE:-ASUS Zenbook A14 ACPI ROOT14 ($ROOT14_KREL)}"
ARCH_NAME="${A14_ARCH:-arm64}"
JOBS="${A14_JOBS:-$(nproc)}"
PREP_REPORT="$OWNER_HOME/Downloads/a14-acpi-root14-prepare.txt"
STATUS_REPORT="$OWNER_HOME/Downloads/a14-acpi-root14-status.txt"

cfg_val(){
    local cfg="$1" sym="$2"
    grep -E "^(CONFIG_${sym}=|# CONFIG_${sym} is not set)" "$cfg" | tail -n1 || true
}

assert_cfg(){
    local cfg="$1" sym="$2" expected="$3" got
    got="$(cfg_val "$cfg" "$sym")"
    case "$expected" in
        y|m)
            [[ "$got" == "CONFIG_${sym}=${expected}" ]] ||
                die "Kconfig assertion failed: $sym expected=$expected got=${got:-MISSING}"
            ;;
        n)
            [[ "$got" == "# CONFIG_${sym} is not set" ]] ||
                die "Kconfig assertion failed: $sym expected=n got=${got:-MISSING}"
            ;;
        *)
            die "internal error: bad expected state '$expected' for $sym"
            ;;
    esac
    say "ASSERT_CONFIG_${sym}=$expected"
}

clear_next_entry(){
    if [[ -f "$GRUBENV" ]]; then
        grub-editenv "$GRUBENV" unset next_entry >/dev/null 2>&1 || true
    fi
}

assert_unarmed(){
    local envtxt=""
    [[ -f "$GRUBENV" ]] && envtxt="$(grub-editenv "$GRUBENV" list 2>/dev/null || true)"
    if grep -q '^next_entry=' <<<"$envtxt"; then
        printf '%s\n' "$envtxt" >&2
        die "GRUB next_entry is still armed"
    fi
    say "A14_ACPI_ROOT14_GRUB_NEXT_ENTRY=UNARMED"
}

extract_stanza(){
    local wanted_krel="$1" replacement_krel="$2" title="$3" mode="$4"
    python3 - "$GRUB_CFG" "$wanted_krel" "$replacement_krel" "$title" "$mode" <<'PY'
import re
import sys
from pathlib import Path

cfg, wanted, replacement, title, mode = sys.argv[1:]
p = Path(cfg)
if not p.is_file():
    raise SystemExit(f"grub.cfg missing: {cfg}")

lines = p.read_text(errors="replace").splitlines()
needle = f"vmlinuz-{wanted}"

candidates = []
for i, line in enumerate(lines):
    if needle not in line or not re.match(r"^\s*linux(?:efi)?\s+", line):
        continue

    start = None
    for j in range(i, -1, -1):
        if re.match(r"^\s*menuentry\s+", lines[j]):
            start = j
            break
    if start is None:
        continue

    # Standard generated GRUB menuentry bodies do not use nested braces.
    end = None
    for j in range(i + 1, len(lines)):
        if re.match(r"^\s*}\s*$", lines[j]):
            end = j
            break
    if end is None:
        continue

    block = lines[start:end + 1]
    header = block[0].lower()
    cmdline = "\n".join(block).lower()
    if "recovery mode" in header or " single" in cmdline or " recovery" in cmdline:
        continue
    key = (start, end)
    if key not in [(a, b) for a, b, _ in candidates]:
        candidates.append((start, end, block))

if not candidates:
    raise SystemExit(f"no non-recovery GRUB menuentry found for {needle}")

# Prefer a top-level-looking entry (column 0 menuentry), then the first normal candidate.
candidates.sort(key=lambda x: (1 if lines[x[0]][:1].isspace() else 0, x[0]))
start, end, block = candidates[0]

if any(re.match(r"^\s*devicetree\s+", ln) for ln in block):
    raise SystemExit("selected ROOT11 stanza contains a devicetree command; refusing ROOT14 clone")

linux_idx = [
    i for i, ln in enumerate(block)
    if re.match(r"^\s*linux(?:efi)?\s+", ln) and needle in ln
]
if len(linux_idx) != 1:
    raise SystemExit(f"expected exactly one ROOT11 linux line, got {len(linux_idx)}")

if mode == "clone":
    idx = linux_idx[0]
    block[idx] = block[idx].replace(
        f"vmlinuz-{wanted}", f"vmlinuz-{replacement}", 1
    )
    # panic=0 is mandatory for experimental boots.
    if not re.search(r"(^|\s)panic=0(\s|$)", block[idx]):
        block[idx] = block[idx].rstrip() + " panic=0"

    # Replace only the first menuentry title, leaving menuentry IDs/options intact.
    header = block[0]
    m = re.match(r"^(\s*menuentry\s+)(['\"])(.*?)(\2)(.*)$", header)
    if not m:
        raise SystemExit(f"cannot safely parse ROOT11 menuentry header: {header}")
    q = m.group(2)
    block[0] = f"{m.group(1)}{q}{title}{q}{m.group(5)}"
    # Avoid duplicating ROOT11's menuentry ID when the generated header embeds
    # the kernel release in $menuentry_id_option.
    block[0] = block[0].replace(wanted, replacement)

elif mode == "verify":
    pass
else:
    raise SystemExit(f"unknown mode: {mode}")

print("\n".join(block))
PY
}

verify_root14_grub_entry(){
    python3 - "$GRUB_CFG" "$ROOT14_KREL" "$ENTRY_TITLE" <<'PY'
import re
import sys
from pathlib import Path

cfg, krel, title = sys.argv[1:]
lines = Path(cfg).read_text(errors="replace").splitlines()
needle = f"vmlinuz-{krel}"
matches = []

for i, line in enumerate(lines):
    if needle not in line or not re.match(r"^\s*linux(?:efi)?\s+", line):
        continue
    start = next((j for j in range(i, -1, -1)
                  if re.match(r"^\s*menuentry\s+", lines[j])), None)
    if start is None:
        continue
    end = next((j for j in range(i + 1, len(lines))
                if re.match(r"^\s*}\s*$", lines[j])), None)
    if end is None:
        continue
    block = lines[start:end + 1]
    if title not in block[0]:
        continue
    matches.append(block)

if len(matches) != 1:
    raise SystemExit(f"expected exactly one ROOT14 GRUB entry, found {len(matches)}")

block = matches[0]
if any(re.match(r"^\s*devicetree\s+", ln) for ln in block):
    raise SystemExit("ROOT14 GRUB entry unexpectedly contains devicetree")
linux = [ln for ln in block if needle in ln and re.match(r"^\s*linux(?:efi)?\s+", ln)]
if len(linux) != 1 or not re.search(r"(^|\s)panic=0(\s|$)", linux[0]):
    raise SystemExit("ROOT14 linux line missing or panic=0 absent")
if not any(re.match(r"^\s*initrd(?:efi)?\s+", ln) and "a14-acpi-root11" in ln for ln in block):
    raise SystemExit("ROOT14 entry does not retain the proven ROOT11 initrd")
print("A14_ACPI_ROOT14_GRUB_ENTRY=PASS")
print(f"entry_title={title}")
print(linux[0].strip())
PY
}

write_grub_fragment(){
    local stanza tmp
    stanza="$(extract_stanza "$ROOT11_KREL" "$ROOT14_KREL" "$ENTRY_TITLE" clone)"
    [[ -n "$stanza" ]] || die "failed to extract ROOT11 GRUB stanza"

    tmp="$(mktemp /tmp/a14-root14-grub.XXXXXX)"
    {
        printf '%s\n' '#!/bin/sh'
        printf '%s\n' '# Generated by a14-acpi-root14-qcom-flash-one-go.sh'
        printf '%s\n' 'exec tail -n +4 "$0"'
        printf '%s\n' '# A14_ACPI_ROOT14_GRUB_FRAGMENT'
        printf '%s\n' "$stanza"
    } >"$tmp"

    if [[ -e "$GRUB_FRAGMENT" ]] &&
       ! grep -q 'A14_ACPI_ROOT14_GRUB_FRAGMENT' "$GRUB_FRAGMENT" 2>/dev/null; then
        rm -f "$tmp"
        die "refusing to overwrite non-ROOT14 GRUB fragment: $GRUB_FRAGMENT"
    fi

    install -m 0755 "$tmp" "$GRUB_FRAGMENT"
    rm -f "$tmp"
}

prepare(){
    for c in bash cat chown cp date diff file getent grep grub-editenv install make mktemp \
             nproc python3 sed sha256sum stat sync tee update-grub; do
        have "$c" || die "missing command: $c"
    done

    [[ -d "$SRC" && -f "$SRC/Makefile" ]] || die "kernel source missing: $SRC"
    [[ -x "$SRC/scripts/config" ]] || die "kernel scripts/config missing"
    [[ -r "$ROOT11_CONFIG" ]] || die "ROOT11 config missing: $ROOT11_CONFIG"
    [[ -r "$ROOT11_INITRD" ]] || die "ROOT11 initrd missing: $ROOT11_INITRD"
    [[ -r "$GRUB_CFG" ]] || die "GRUB config missing: $GRUB_CFG"

    mkdir -p "$OUT"

    {
        say "A14_ACPI_ROOT14_PREPARE_ENTERED=1"
        say "timestamp=$(date -Is)"
        say "owner=$OWNER"
        say "src=$SRC"
        say "out=$OUT"
        say "root11_config=$ROOT11_CONFIG"
        say "root11_initrd=$ROOT11_INITRD"
        say "root14_krel=$ROOT14_KREL"
        say "image_only=true"
        say "module_build=false"
        say "modules_install=false"
        say "initramfs_update=false"
        say "service_mutation=false"
        say "reboot_performed=false"

        section "safety: clear stale one-shot boot before any work"
        clear_next_entry
        assert_unarmed

        section "seed ROOT11 config and apply ROOT14 built-in conversion"
        cp -- "$ROOT11_CONFIG" "$OUT/.config"

        "$SRC/scripts/config" --file "$OUT/.config" --set-str LOCALVERSION "-a14-acpi-root14"
        "$SRC/scripts/config" --file "$OUT/.config" --disable LOCALVERSION_AUTO

        "$SRC/scripts/config" --file "$OUT/.config" --enable SPMI
        "$SRC/scripts/config" --file "$OUT/.config" --enable SPMI_MSM_PMIC_ARB
        "$SRC/scripts/config" --file "$OUT/.config" --enable MFD_SPMI_PMIC
        "$SRC/scripts/config" --file "$OUT/.config" --enable LEDS_CLASS_FLASH
        "$SRC/scripts/config" --file "$OUT/.config" --disable V4L2_FLASH_LED_CLASS
        "$SRC/scripts/config" --file "$OUT/.config" --enable LEDS_QCOM_FLASH

        make -s -C "$SRC" O="$OUT" ARCH="$ARCH_NAME" olddefconfig

        section "post-olddefconfig assertions"
        assert_cfg "$OUT/.config" SPMI y
        assert_cfg "$OUT/.config" SPMI_MSM_PMIC_ARB y
        assert_cfg "$OUT/.config" MFD_SPMI_PMIC y
        assert_cfg "$OUT/.config" LEDS_CLASS y
        assert_cfg "$OUT/.config" LEDS_CLASS_FLASH y
        assert_cfg "$OUT/.config" V4L2_FLASH_LED_CLASS n
        assert_cfg "$OUT/.config" LEDS_QCOM_FLASH y

        # ROOT11 regressions that must remain built in.
        assert_cfg "$OUT/.config" AUTOFS_FS y
        assert_cfg "$OUT/.config" I2C_CHARDEV y
        assert_cfg "$OUT/.config" I2C_QCOM_CCI y

        section "ROOT11 -> ROOT14 config delta"
        diff -u "$ROOT11_CONFIG" "$OUT/.config" || true

        section "kernel release"
        local actual_krel
        actual_krel="$(make -s -C "$SRC" O="$OUT" ARCH="$ARCH_NAME" kernelrelease)"
        say "kernelrelease=$actual_krel"
        [[ "$actual_krel" == "$ROOT14_KREL" ]] ||
            die "unexpected kernelrelease: expected=$ROOT14_KREL got=$actual_krel"

        section "Image-only build"
        say "make_target=Image"
        say "jobs=$JOBS"
        make -C "$SRC" O="$OUT" ARCH="$ARCH_NAME" -j"$JOBS" Image

        local image="$OUT/arch/arm64/boot/Image"
        [[ -s "$image" ]] || die "Image build did not produce $image"
        file "$image" || true
        stat "$image"
        sha256sum "$image"

        section "install ROOT14 Image/config only"
        install -m 0644 "$image" "$ROOT14_IMAGE"
        install -m 0644 "$OUT/.config" "$ROOT14_CONFIG"
        if [[ -s "$OUT/System.map" ]]; then
            install -m 0644 "$OUT/System.map" "$ROOT14_SYSTEM_MAP"
        fi
        sync
        stat "$ROOT14_IMAGE" "$ROOT14_CONFIG"
        sha256sum "$ROOT14_IMAGE" "$ROOT14_CONFIG"

        section "clone proven ROOT11 GRUB stanza"
        write_grub_fragment

        # prepare must remain unarmed both before and after update-grub.
        clear_next_entry
        update-grub
        clear_next_entry

        verify_root14_grub_entry
        assert_unarmed

        section "ROOT14 prepare summary"
        say "A14_ACPI_ROOT14_CONFIG=PASS"
        say "A14_ACPI_ROOT14_IMAGE_BUILD=PASS"
        say "A14_ACPI_ROOT14_IMAGE_INSTALL=PASS"
        say "A14_ACPI_ROOT14_GRUB_CLONE=PASS"
        say "A14_ACPI_ROOT14_PREPARE=PASS"
        say "A14_ACPI_ROOT14_READY=UNARMED"
        say "reboot_performed=false"
        say "next_action=sudo bash scripts/a14-acpi-root14-qcom-flash-one-go.sh arm"
    } > >(tee "$PREP_REPORT") 2>&1

    chown "$OWNER:$OWNER" "$PREP_REPORT" 2>/dev/null || true
}

arm(){
    for c in getent grep grub-editenv grub-reboot python3; do
        have "$c" || die "missing command: $c"
    done

    [[ -s "$ROOT14_IMAGE" ]] || die "ROOT14 Image missing: $ROOT14_IMAGE"
    [[ -r "$GRUB_CFG" ]] || die "GRUB config missing: $GRUB_CFG"

    verify_root14_grub_entry

    # Remove any stale one-shot selection, then set exactly ROOT14.
    clear_next_entry
    assert_unarmed
    grub-reboot "$ENTRY_TITLE"

    local envtxt
    envtxt="$(grub-editenv "$GRUBENV" list 2>/dev/null || true)"
    printf '%s\n' "$envtxt"
    grep -q '^next_entry=' <<<"$envtxt" ||
        die "grub-reboot did not set next_entry"

    say "A14_ACPI_ROOT14_ARM=PASS"
    say "A14_ACPI_ROOT14_ONE_SHOT_SET=1"
    say "entry=$ENTRY_TITLE"
    say "reboot_performed=false"
    say "MANUAL_REBOOT_REQUIRED=1"
}

status(){
    for c in cat chown date find getent grep grub-editenv journalctl sort systemctl tail tee uname; do
        have "$c" || die "missing command: $c"
    done

    {
        say "A14_ACPI_ROOT14_STATUS_ENTERED=1"
        say "timestamp=$(date -Is)"
        say "uname=$(uname -a)"
        say "running_kernel=$(uname -r)"
        say "expected_kernel=$ROOT14_KREL"
        say "cmdline=$(cat /proc/cmdline 2>/dev/null || true)"
        if [[ "$(uname -r)" == "$ROOT14_KREL" ]]; then
            say "A14_ACPI_ROOT14_BOOTED=PASS"
        else
            say "A14_ACPI_ROOT14_BOOTED=NO"
        fi

        section "boot config target symbols"
        local cfg="/boot/config-$(uname -r)"
        if [[ -r "$cfg" ]]; then
            for sym in SPMI SPMI_MSM_PMIC_ARB MFD_SPMI_PMIC LEDS_CLASS \
                       LEDS_CLASS_FLASH V4L2_FLASH_LED_CLASS LEDS_QCOM_FLASH \
                       AUTOFS_FS I2C_CHARDEV I2C_QCOM_CCI; do
                say "$sym=$(cfg_val "$cfg" "$sym")"
            done
        else
            say "running_config_missing=$cfg"
        fi

        section "loaded/module-request diagnostics"
        journalctl -k -b --no-pager 2>/dev/null |
            grep -Ei 'spmi|pmic.*arb|qcom.*flash|leds[-_]qcom[-_]flash|hm1092|qcom[-_]cci[-_]sync|hid[-_]asus[-_]ec|i2c[-_]qcom[-_]cci|failed to find module|unknown symbol' |
            tail -n 500 || true

        section "systemd module-loader diagnostics"
        journalctl -b -u systemd-modules-load.service --no-pager 2>/dev/null |
            tail -n 400 || true

        section "/sys/class/leds"
        find /sys/class/leds -maxdepth 2 -mindepth 1 -printf '%p -> %l\n' 2>/dev/null |
            sort || true

        section "failed units"
        systemctl --failed --no-pager 2>/dev/null || true

        section "GRUB one-shot state after boot"
        if [[ -f "$GRUBENV" ]]; then
            grub-editenv "$GRUBENV" list 2>/dev/null || true
        fi

        say "A14_ACPI_ROOT14_STATUS=PASS"
        say "service_mutation=false"
        say "reboot_performed=false"
    } > >(tee "$STATUS_REPORT") 2>&1

    chown "$OWNER:$OWNER" "$STATUS_REPORT" 2>/dev/null || true
}

case "$ACTION" in
    prepare) prepare ;;
    arm) arm ;;
    status) status ;;
esac
