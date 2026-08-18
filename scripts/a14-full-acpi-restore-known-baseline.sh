#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

ACTION="${1:-status}"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
ROOT="${A14_FULL_ACPI_WORKDIR:-${A14_FULL_ACPI_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}}"
SRC="$ROOT/linux-7.1.5"
OUT="$ROOT/build"
KREL="7.1.5-a14-acpi-full0"
KERNEL="/boot/vmlinuz-$KREL"
INITRD="/boot/initrd.img-$KREL"
CONFIG="/boot/config-$KREL"
BACKUP="/boot/vmlinuz-$KREL.pre-known-baseline-rollback"
BASELINE_SNIPPET="/etc/grub.d/41_a14_full_acpi_baseline"
ENTRY_ID="a14-full-acpi-known-baseline"
ENTRY="ASUS Zenbook A14 — ACPI-ONLY KNOWN BASELINE ($KREL)"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROGRESS="$SCRIPT_DIR/a14-kbuild-progress.py"
JOBS="${A14_BUILD_JOBS:-$(nproc)}"
LOG="$ROOT/a14-build-known-baseline-Image.log"
MODLOG="$ROOT/a14-build-known-baseline-pinctrl.log"
PINCTRL_REL="drivers/pinctrl/qcom/pinctrl-x1e80100"
PINCTRL_OBJ="$OUT/$PINCTRL_REL.o"
PINCTRL_KO="$OUT/$PINCTRL_REL.ko"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_user(){ [[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as your normal user, not root"; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "this action requires sudo/root"; }

config_state(){
    local sym="$1"
    if grep -q "^CONFIG_${sym}=y$" "$OUT/.config"; then echo y
    elif grep -q "^CONFIG_${sym}=m$" "$OUT/.config"; then echo m
    else echo n
    fi
}

verify_tree(){
    [[ -d "$SRC/.git" ]] || die "missing kernel git tree: $SRC"
    [[ -f "$OUT/.config" ]] || die "missing build tree: $OUT"
    git -C "$SRC" rev-parse --verify 'refs/tags/v7.1.5^{commit}' >/dev/null 2>&1 || die "v7.1.5 tag missing in source tree"
    state="$(config_state PINCTRL_X1E80100)"
    [[ "$state" == y || "$state" == m ]] || die "CONFIG_PINCTRL_X1E80100 is not enabled"
}

restore_upstream_later_experiment_files(){
    local f
    for f in \
        drivers/acpi/bus.c \
        drivers/acpi/scan.c \
        drivers/acpi/power.c \
        drivers/gpio/gpiolib-acpi-core.c; do
        git -C "$SRC" show "v7.1.5:$f" > "$SRC/$f"
    done
}

restore_old_tlmm_match(){
    python3 - "$SRC/drivers/pinctrl/qcom/pinctrl-x1e80100.c" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text()
pat = re.compile(r'static const struct acpi_device_id x1e80100_pinctrl_acpi_match\[\] = \{\n.*?\n\};', re.S)
m = pat.search(s)
if not m:
    raise SystemExit('ERROR: x1e80100 TLMM ACPI match table not found')
new = '''static const struct acpi_device_id x1e80100_pinctrl_acpi_match[] = {
\t{ "QCOM0C0D", 0 },
\t{ }
};'''
s = s[:m.start()] + new + s[m.end():]
p.write_text(s)
print('tlmm_match=restored_QCOM0C0D')
PY
}

verify_source(){
    python3 - "$SRC/drivers/pinctrl/qcom/pinctrl-x1e80100.c" <<'PY'
from pathlib import Path
import re, sys
s = Path(sys.argv[1]).read_text()
m = re.search(r'static const struct acpi_device_id x1e80100_pinctrl_acpi_match\[\] = \{(.*?)\n\};', s, re.S)
if not m:
    raise SystemExit('ERROR: TLMM ACPI match table missing')
t = m.group(1)
if 'QCOM0C0D' not in t or 'QCOM0C0C' in t or 'QCOMFFEB' in t:
    raise SystemExit('ERROR: TLMM ACPI table is not the old QCOM0C0D-only baseline')
PY
    ! grep -q 'A14_QCOM_WOA_ACPI_GPIO_XLATE' "$SRC/drivers/gpio/gpiolib-acpi-core.c" || die "virtual GPIO translation still present"
    ! grep -q 'A14TRACE' "$SRC/drivers/acpi/scan.c" || die "ACPI scan trace still present"
    ! grep -q 'A14TRACE' "$SRC/drivers/acpi/power.c" || die "ACPI power trace still present"
    ! grep -q 'A14TRACE' "$SRC/drivers/acpi/bus.c" || die "ACPI bus trace still present"
    grep -q 'A14 ACPI: wrapperless GENI SE' "$SRC/drivers/i2c/busses/i2c-qcom-geni.c" || die "GENI wrapperless patch missing; refusing to call this the known baseline"
    say "A14_KNOWN_BASELINE_SOURCE=VERIFIED"
    say "tlmm_acpi_id=QCOM0C0D"
    say "gio0_qcom0c0c_binding=false"
    say "woa_virtual_gpio_translation=false"
    say "acpi_scan_trace=false"
    say "geni_wrapperless=true"
    say "pinctrl_config=$(config_state PINCTRL_X1E80100)"
}

verify_pinctrl_artifact(){
    local state target
    state="$(config_state PINCTRL_X1E80100)"
    if [[ "$state" == m ]]; then target="$PINCTRL_KO"; else target="$PINCTRL_OBJ"; fi
    [[ -s "$target" ]] || die "pinctrl build artifact missing: $target"
    strings "$target" | grep -qx 'QCOM0C0D' || die "rebuilt pinctrl artifact lacks QCOM0C0D"
    if strings "$target" | grep -Eq '^(QCOM0C0C|QCOMFFEB)$'; then
        die "rebuilt pinctrl artifact still contains new GIO0 IDs"
    fi
    say "A14_KNOWN_BASELINE_PINCTRL=VERIFIED"
    say "pinctrl_artifact=$target"
}

verify_image(){
    local image="$OUT/arch/arm64/boot/Image"
    [[ -s "$image" ]] || die "Image missing: $image"
    if grep -aFq 'A14TRACE2' "$image" || grep -aFq 'A14_QCOM_WOA_ACPI_GPIO_XLATE' "$image"; then
        die "built Image still contains later trace/translation code"
    fi
    verify_pinctrl_artifact
    say "A14_KNOWN_BASELINE_IMAGE=VERIFIED"
}

build_pinctrl(){
    local state rc
    state="$(config_state PINCTRL_X1E80100)"
    if [[ "$state" == m ]]; then
        say "A14_KNOWN_BASELINE_PINCTRL_BUILD=START"
        say "scope=single in-tree module target: $PINCTRL_REL.ko"
        set +e
        make -C "$SRC" O="$OUT" -j"$JOBS" "$PINCTRL_REL.ko" 2>&1 | tee "$MODLOG"
        rc=${PIPESTATUS[0]}
        set -e
        (( rc == 0 )) || { tail -n 120 "$MODLOG" >&2 || true; die "pinctrl module build failed rc=$rc"; }
    else
        say "pinctrl_config=y; Image build will rebuild the built-in object"
    fi
}

build_baseline(){
    need_user
    need strings
    verify_tree
    restore_upstream_later_experiment_files
    restore_old_tlmm_match
    verify_source

    export LOCALVERSION=
    say "A14_KNOWN_BASELINE_BUILD=START"
    say "scope=incremental Image + affected pinctrl artifact only"
    say "jobs=$JOBS"
    say "raw_log=$LOG"

    # Build the module explicitly when CONFIG_PINCTRL_X1E80100=m.  `make Image`
    # does not rebuild module-only objects, which was the bug in the first rollback helper.
    build_pinctrl

    set +e
    if [[ -t 1 && -f "$PROGRESS" ]]; then
        make -C "$SRC" O="$OUT" -j"$JOBS" Image 2>&1 \
            | tee "$LOG" \
            | python3 "$PROGRESS" --label "Known ACPI baseline Image" --logfile "$LOG" --module-total 0 --module-built 0
        rc=${PIPESTATUS[0]}
    else
        make -C "$SRC" O="$OUT" -j"$JOBS" Image 2>&1 | tee "$LOG"
        rc=${PIPESTATUS[0]}
    fi
    set -e
    if (( rc != 0 )); then
        echo "ERROR: baseline Image build failed rc=$rc" >&2
        tail -n 120 "$LOG" >&2 || true
        exit "$rc"
    fi

    verify_image
    say "A14_KNOWN_BASELINE_BUILD=COMPLETE"
    say "image=$OUT/arch/arm64/boot/Image"
    say "sha256=$(sha256sum "$OUT/arch/arm64/boot/Image" | awk '{print $1}')"
}

cleanup_grub_pollution(){
    need_root
    local f removed=0 next
    shopt -s nullglob
    for f in /etc/grub.d/*a14_full_acpi*; do
        [[ -f "$f" || -L "$f" ]] || continue
        case "$(basename "$f")" in
            41_a14_full_acpi|41_a14_full_acpi_*|42_a14_full_acpi_*|43_a14_full_acpi_*|44_a14_full_acpi_*)
                say "removing_grub_snippet=$f"
                rm -f -- "$f"
                removed=$((removed + 1))
                ;;
        esac
    done
    shopt -u nullglob

    if command -v grub-editenv >/dev/null 2>&1 && [[ -f /boot/grub/grubenv ]]; then
        next="$(grub-editenv /boot/grub/grubenv list 2>/dev/null | sed -n 's/^next_entry=//p' | head -n1 || true)"
        case "$next" in
            a14-*|*a14-full-acpi*|*ACPI-ONLY*)
                grub-editenv /boot/grub/grubenv unset next_entry || true
                say "cleared_grub_next_entry=$next"
                ;;
        esac
    fi
    say "A14_GRUB_POLLUTION_REMOVED=$removed"
}

write_single_baseline_entry(){
    need_root
    for c in grub-probe grub-mkrelpath update-grub; do need "$c"; done
    [[ -s "$KERNEL" ]] || die "missing $KERNEL"
    [[ -s "$INITRD" ]] || die "missing $INITRD"

    local uuid kp ip cmdline linux_line
    local -a args=()
    uuid="$(grub-probe --target=fs_uuid "$KERNEL")"
    kp="$(grub-mkrelpath "$KERNEL")"
    ip="$(grub-mkrelpath "$INITRD")"

    for arg in $(cat /proc/cmdline); do
        case "$arg" in
            BOOT_IMAGE=*|initrd=*|acpi=*|panic=*|oops=*|quiet|splash|break=*|debug|debug=*|loglevel=*|earlycon=*|console=*|ignore_loglevel|initcall_debug|keep_bootcon|a14_*=*|reserve_mem=*|ramoops.*|nokaslr|systemd.unit=*|plymouth.enable=*|rd.plymouth=*) ;;
            *) args+=("$arg") ;;
        esac
    done
    cmdline="${args[*]} earlycon=efifb console=tty0 loglevel=8 ignore_loglevel printk.time=1 acpi=force"

    cat > "$BASELINE_SNIPPET" <<EOF
#!/bin/sh
exec tail -n +3 \$0
# Single clean A14 ACPI-only baseline entry. Intentionally NO devicetree command.
menuentry '$ENTRY' --id '$ENTRY_ID' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root $uuid
    linux $kp $cmdline
    initrd $ip
}
EOF
    chmod 0755 "$BASELINE_SNIPPET"

    linux_line="$(awk '/^menuentry .*KNOWN BASELINE/{seen=1} seen && /^[[:space:]]*linux[[:space:]]/{print; exit}' "$BASELINE_SNIPPET")"
    [[ -n "$linux_line" ]] || die "failed to validate baseline GRUB entry"
    grep -q 'acpi=force' <<<"$linux_line" || die "baseline entry lacks acpi=force"
    grep -q 'earlycon=efifb' <<<"$linux_line" || die "baseline entry lacks earlycon=efifb"
    ! grep -q 'keep_bootcon' <<<"$linux_line" || die "baseline unexpectedly contains keep_bootcon"
    ! grep -q 'initcall_debug' <<<"$linux_line" || die "baseline unexpectedly contains initcall_debug"
    ! grep -qE '(^|[[:space:]])panic=' <<<"$linux_line" || die "baseline unexpectedly contains panic=..."
    ! grep -qE '^[[:space:]]*devicetree[[:space:]]' "$BASELINE_SNIPPET" || die "baseline unexpectedly loads a DTB"

    update-grub
    say "A14_SINGLE_BASELINE_GRUB_ENTRY=READY"
    say "entry=$ENTRY"
    say "snippet=$BASELINE_SNIPPET"
}

install_pinctrl_module(){
    local state installed
    state="$(config_state PINCTRL_X1E80100)"
    [[ "$state" == m ]] || { say "pinctrl_config=y; no standalone module install needed"; return 0; }
    [[ -s "$PINCTRL_KO" ]] || die "rebuilt pinctrl module missing: $PINCTRL_KO"

    # Use Kbuild's in-tree modules_install for this one directory so signing,
    # stripping and configured module compression follow the kernel config.
    say "A14_KNOWN_BASELINE_PINCTRL_INSTALL=START"
    make -C "$SRC" O="$OUT" M=drivers/pinctrl/qcom modules_install

    installed="$(find "/lib/modules/$KREL" -type f \( -name 'pinctrl-x1e80100.ko' -o -name 'pinctrl-x1e80100.ko.xz' -o -name 'pinctrl-x1e80100.ko.zst' -o -name 'pinctrl-x1e80100.ko.gz' \) -print -quit)"
    [[ -n "$installed" ]] || die "installed pinctrl-x1e80100 module not found under /lib/modules/$KREL"
    say "installed_pinctrl_module=$installed"
}

install_baseline(){
    need_root
    need strings
    for c in depmod update-initramfs; do need "$c"; done
    verify_tree
    verify_source
    verify_image
    [[ "$(uname -r)" != "$KREL" ]] || die "boot the normal DT kernel before replacing the experimental kernel"
    [[ -s "$INITRD" ]] || die "missing existing experimental initramfs: $INITRD"

    if [[ ! -e "$BACKUP" && -s "$KERNEL" ]]; then
        cp -a "$KERNEL" "$BACKUP"
        say "backup_created=$BACKUP"
    elif [[ -e "$BACKUP" ]]; then
        say "backup_preserved=$BACKUP"
    fi

    install -m0644 "$OUT/arch/arm64/boot/Image" "$KERNEL"
    cmp -s "$OUT/arch/arm64/boot/Image" "$KERNEL" || die "installed baseline Image does not match build"

    install_pinctrl_module
    depmod -a "$KREL"

    # The experimental initramfs may contain the previously installed GIO0
    # pinctrl module. Rebuild it so the rollback module is the one actually booted.
    say "A14_KNOWN_BASELINE_INITRAMFS_REFRESH=START"
    update-initramfs -u -k "$KREL"
    say "A14_KNOWN_BASELINE_INITRAMFS_REFRESH=COMPLETE"

    cleanup_grub_pollution
    write_single_baseline_entry

    say "A14_KNOWN_BASELINE_INSTALL=COMPLETE"
    say "kernel=$KERNEL"
    say "installed_sha256=$(sha256sum "$KERNEL" | awk '{print $1}')"
    say "affected_pinctrl_module_refreshed=$([[ $(config_state PINCTRL_X1E80100) == m ]] && echo true || echo built-in)"
    say "initramfs_refreshed=true"
    say "normal_DT_kernel_untouched=true"
    say "custom_A14_GRUB_entries=1"
}

status(){
    say "source=$SRC"
    say "build=$OUT"
    say "kernel=$KERNEL"
    say "backup=$BACKUP"
    say "running_kernel=$(uname -r)"
    [[ -f "$OUT/.config" ]] && say "pinctrl_config=$(config_state PINCTRL_X1E80100)"
    say "--- A14 GRUB snippets ---"
    find /etc/grub.d -maxdepth 1 -type f -name '*a14_full_acpi*' -printf '%f\n' 2>/dev/null | sort || true
    if [[ -f "$SRC/drivers/gpio/gpiolib-acpi-core.c" ]]; then
        say "virtual_gpio_translation=$([[ $(grep -c A14_QCOM_WOA_ACPI_GPIO_XLATE "$SRC/drivers/gpio/gpiolib-acpi-core.c" || true) -gt 0 ]] && echo present || echo absent)"
    fi
    if [[ -f "$SRC/drivers/acpi/scan.c" ]]; then
        say "acpi_trace=$([[ $(grep -c A14TRACE "$SRC/drivers/acpi/scan.c" || true) -gt 0 ]] && echo present || echo absent)"
    fi
}

case "$ACTION" in
    build) build_baseline ;;
    install) install_baseline ;;
    cleanup-grub) cleanup_grub_pollution; write_single_baseline_entry ;;
    status) status ;;
    *) die "usage: $0 {build|install|cleanup-grub|status}" ;;
esac
