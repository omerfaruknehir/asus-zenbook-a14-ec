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
BACKUP="/boot/vmlinuz-$KREL.pre-known-baseline-rollback"
BASELINE_SNIPPET="/etc/grub.d/41_a14_full_acpi_baseline"
ENTRY_ID="a14-full-acpi-known-baseline"
ENTRY="ASUS Zenbook A14 — ACPI-ONLY KNOWN BASELINE ($KREL)"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROGRESS="$SCRIPT_DIR/a14-kbuild-progress.py"
JOBS="${A14_BUILD_JOBS:-$(nproc)}"
IMG_LOG="$ROOT/a14-build-known-baseline-Image.log"
PIN_LOG="$ROOT/a14-build-known-baseline-pinctrl.log"
PIN_REL="drivers/pinctrl/qcom/pinctrl-x1e80100"
PIN_SRC="$SRC/$PIN_REL.c"
PIN_OBJ="$OUT/$PIN_REL.o"
PIN_KO="$OUT/$PIN_REL.ko"
PIN_CMD="$OUT/drivers/pinctrl/qcom/.pinctrl-x1e80100.o.cmd"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_user(){ [[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as normal user, not root"; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "this action requires sudo/root"; }

config_state(){
    if grep -q '^CONFIG_PINCTRL_X1E80100=y$' "$OUT/.config"; then echo y
    elif grep -q '^CONFIG_PINCTRL_X1E80100=m$' "$OUT/.config"; then echo m
    else echo n
    fi
}

verify_tree(){
    [[ -d "$SRC/.git" ]] || die "missing source tree: $SRC"
    [[ -f "$OUT/.config" ]] || die "missing build config: $OUT/.config"
    git -C "$SRC" rev-parse --verify 'refs/tags/v7.1.5^{commit}' >/dev/null 2>&1 || die "v7.1.5 tag missing"
    local st; st="$(config_state)"
    [[ "$st" == y || "$st" == m ]] || die "CONFIG_PINCTRL_X1E80100 is not enabled"
}

restore_baseline_source(){
    local f
    for f in drivers/acpi/bus.c drivers/acpi/scan.c drivers/acpi/power.c drivers/gpio/gpiolib-acpi-core.c; do
        git -C "$SRC" show "v7.1.5:$f" > "$SRC/$f"
    done

    python3 - "$PIN_SRC" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text()
pat = re.compile(r'static const struct acpi_device_id x1e80100_pinctrl_acpi_match\[\] = \{\n.*?\n\};', re.S)
m = pat.search(s)
if not m:
    raise SystemExit('ERROR: TLMM ACPI match table not found')
new = '''static const struct acpi_device_id x1e80100_pinctrl_acpi_match[] = {
\t{ "QCOM0C0D", 0 },
\t{ }
};'''
p.write_text(s[:m.start()] + new + s[m.end():])
PY
}

verify_source(){
    grep -q 'QCOM0C0D' "$PIN_SRC" || die "source lacks baseline QCOM0C0D"
    ! grep -q 'QCOM0C0C' "$PIN_SRC" || die "source still contains QCOM0C0C"
    ! grep -q 'QCOMFFEB' "$PIN_SRC" || die "source still contains QCOMFFEB"
    ! grep -q 'A14_QCOM_WOA_ACPI_GPIO_XLATE' "$SRC/drivers/gpio/gpiolib-acpi-core.c" || die "virtual GPIO translation still present"
    ! grep -q 'A14TRACE' "$SRC/drivers/acpi/scan.c" || die "scan trace still present"
    ! grep -q 'A14TRACE' "$SRC/drivers/acpi/power.c" || die "power trace still present"
    ! grep -q 'A14TRACE' "$SRC/drivers/acpi/bus.c" || die "bus trace still present"
    grep -q 'A14 ACPI: wrapperless GENI SE' "$SRC/drivers/i2c/busses/i2c-qcom-geni.c" || die "GENI wrapperless patch missing"
    say "A14_KNOWN_BASELINE_SOURCE=VERIFIED"
    say "tlmm_acpi_id=QCOM0C0D"
    say "gio0_qcom0c0c_binding=false"
    say "woa_virtual_gpio_translation=false"
    say "acpi_scan_trace=false"
    say "geni_wrapperless=true"
    say "pinctrl_config=$(config_state)"
}

verify_pinctrl_artifact(){
    local st target
    st="$(config_state)"
    if [[ "$st" == m ]]; then target="$PIN_KO"; else target="$PIN_OBJ"; fi
    [[ -s "$target" ]] || die "missing rebuilt pinctrl artifact: $target"
    grep -aFq 'QCOM0C0D' "$target" || die "rebuilt pinctrl artifact lacks QCOM0C0D"
    ! grep -aFq 'QCOM0C0C' "$target" || die "rebuilt pinctrl artifact still contains QCOM0C0C"
    ! grep -aFq 'QCOMFFEB' "$target" || die "rebuilt pinctrl artifact still contains QCOMFFEB"
    say "A14_KNOWN_BASELINE_PINCTRL=VERIFIED"
    say "pinctrl_artifact=$target"
}

force_rebuild_pinctrl(){
    local st rc target
    st="$(config_state)"
    say "A14_KNOWN_BASELINE_PINCTRL_BUILD=START"
    say "pinctrl_config=$st"

    # Do not trust old Kbuild timestamps from the preceding experiments.
    rm -f -- "$PIN_OBJ" "$PIN_KO" "$PIN_CMD" \
        "$OUT/drivers/pinctrl/qcom/.pinctrl-x1e80100.ko.cmd" \
        "$OUT/drivers/pinctrl/qcom/.pinctrl-x1e80100.mod.o.cmd"

    if [[ "$st" == y ]]; then target="$PIN_REL.o"; else target="$PIN_REL.ko"; fi
    say "forced_target=$target"
    set +e
    make -C "$SRC" O="$OUT" -j"$JOBS" "$target" 2>&1 | tee "$PIN_LOG"
    rc=${PIPESTATUS[0]}
    set -e
    (( rc == 0 )) || { tail -n 120 "$PIN_LOG" >&2 || true; die "forced pinctrl rebuild failed rc=$rc"; }

    grep -Eq "(^|[[:space:]])CC([[:space:]]|.*)$PIN_REL\\.o|$PIN_REL\\.o" "$PIN_LOG" \
        || say "note=Kbuild log did not expose a conventional CC line; artifact verification is authoritative"
    verify_pinctrl_artifact
}

verify_image(){
    local image="$OUT/arch/arm64/boot/Image"
    [[ -s "$image" ]] || die "Image missing: $image"
    ! grep -aFq 'A14TRACE' "$image" || die "Image still contains A14TRACE"
    ! grep -aFq 'A14_QCOM_WOA_ACPI_GPIO_XLATE' "$image" || die "Image still contains virtual GPIO translation marker"
    ! grep -aFq 'ACPI: QCOM WoA GPIO:' "$image" || die "Image still contains WoA GPIO translation code"
    if [[ "$(config_state)" == y ]]; then
        grep -aFq 'QCOM0C0D' "$image" || die "built-in pinctrl baseline ID missing from Image"
        ! grep -aFq 'QCOM0C0C' "$image" || die "new GIO0 ID QCOM0C0C still present in Image"
        ! grep -aFq 'QCOMFFEB' "$image" || die "new GIO0 ID QCOMFFEB still present in Image"
    fi
    say "A14_KNOWN_BASELINE_IMAGE=VERIFIED"
}

build_baseline(){
    need_user; need make; verify_tree
    restore_baseline_source
    verify_source
    export LOCALVERSION=

    # First rebuild and verify the exact driver that kept remaining stale.
    force_rebuild_pinctrl

    say "A14_KNOWN_BASELINE_IMAGE_BUILD=START"
    say "scope=incremental Image after forced pinctrl rebuild"
    say "jobs=$JOBS"
    set +e
    if [[ -t 1 && -f "$PROGRESS" ]]; then
        make -C "$SRC" O="$OUT" -j"$JOBS" Image 2>&1 | tee "$IMG_LOG" | \
            python3 "$PROGRESS" --label "Known ACPI baseline Image" --logfile "$IMG_LOG" --module-total 0 --module-built 0
        rc=${PIPESTATUS[0]}
    else
        make -C "$SRC" O="$OUT" -j"$JOBS" Image 2>&1 | tee "$IMG_LOG"
        rc=${PIPESTATUS[0]}
    fi
    set -e
    (( rc == 0 )) || { tail -n 120 "$IMG_LOG" >&2 || true; die "Image build failed rc=$rc"; }

    verify_pinctrl_artifact
    verify_image
    say "A14_KNOWN_BASELINE_BUILD=COMPLETE"
    say "image=$OUT/arch/arm64/boot/Image"
    say "sha256=$(sha256sum "$OUT/arch/arm64/boot/Image" | awk '{print $1}')"
}

cleanup_grub(){
    need_root
    local f removed=0 next
    shopt -s nullglob
    for f in /etc/grub.d/*a14_full_acpi*; do
        [[ -f "$f" || -L "$f" ]] || continue
        say "removing_grub_snippet=$f"
        rm -f -- "$f"
        removed=$((removed + 1))
    done
    shopt -u nullglob

    if command -v grub-editenv >/dev/null 2>&1 && [[ -f /boot/grub/grubenv ]]; then
        next="$(grub-editenv /boot/grub/grubenv list 2>/dev/null | sed -n 's/^next_entry=//p' | head -n1 || true)"
        case "$next" in a14-*|*a14-full-acpi*|*ACPI-ONLY*) grub-editenv /boot/grub/grubenv unset next_entry || true; say "cleared_grub_next_entry=$next";; esac
    fi
    say "A14_GRUB_POLLUTION_REMOVED=$removed"
}

write_baseline_entry(){
    need_root
    for c in grub-probe grub-mkrelpath update-grub; do need "$c"; done
    [[ -s "$KERNEL" ]] || die "missing $KERNEL"
    [[ -s "$INITRD" ]] || die "missing $INITRD"

    local uuid kp ip cmdline linux_line arg
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
menuentry '$ENTRY' --id '$ENTRY_ID' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root $uuid
    linux $kp $cmdline
    initrd $ip
}
EOF
    chmod 0755 "$BASELINE_SNIPPET"
    linux_line="$(awk '/KNOWN BASELINE/{seen=1} seen && /^[[:space:]]*linux[[:space:]]/{print; exit}' "$BASELINE_SNIPPET")"
    [[ -n "$linux_line" ]] || die "failed to validate baseline entry"
    grep -q 'acpi=force' <<<"$linux_line" || die "acpi=force missing"
    ! grep -q 'keep_bootcon' <<<"$linux_line" || die "keep_bootcon unexpectedly present"
    ! grep -q 'initcall_debug' <<<"$linux_line" || die "initcall_debug unexpectedly present"
    ! grep -qE '(^|[[:space:]])panic=' <<<"$linux_line" || die "panic= unexpectedly present"
    ! grep -qE '^[[:space:]]*devicetree[[:space:]]' "$BASELINE_SNIPPET" || die "unexpected devicetree command"
    update-grub
    say "A14_SINGLE_BASELINE_GRUB_ENTRY=READY"
    say "entry=$ENTRY"
}

install_baseline(){
    need_root; verify_tree; verify_source; verify_pinctrl_artifact; verify_image
    [[ "$(uname -r)" != "$KREL" ]] || die "boot the normal DT kernel before install"
    [[ -s "$INITRD" ]] || die "missing $INITRD"

    if [[ ! -e "$BACKUP" && -s "$KERNEL" ]]; then cp -a "$KERNEL" "$BACKUP"; say "backup_created=$BACKUP"; fi
    install -m0644 "$OUT/arch/arm64/boot/Image" "$KERNEL"
    cmp -s "$OUT/arch/arm64/boot/Image" "$KERNEL" || die "installed Image mismatch"

    # Current A14 config has PINCTRL_X1E80100=y. Keep module handling for safety if that ever changes.
    if [[ "$(config_state)" == m ]]; then
        local dest="/lib/modules/$KREL/kernel/drivers/pinctrl/qcom"
        mkdir -p "$dest"
        install -m0644 "$PIN_KO" "$dest/pinctrl-x1e80100.ko"
        depmod -a "$KREL"
        update-initramfs -u -k "$KREL"
    fi

    cleanup_grub
    write_baseline_entry
    say "A14_KNOWN_BASELINE_INSTALL=COMPLETE"
    say "kernel=$KERNEL"
    say "installed_sha256=$(sha256sum "$KERNEL" | awk '{print $1}')"
    say "normal_DT_kernel_untouched=true"
    say "custom_A14_GRUB_entries=1"
}

status(){
    say "running_kernel=$(uname -r)"
    say "source=$SRC"
    say "build=$OUT"
    [[ -f "$OUT/.config" ]] && say "pinctrl_config=$(config_state)"
    say "--- A14 GRUB snippets ---"
    find /etc/grub.d -maxdepth 1 -type f -name '*a14_full_acpi*' -printf '%f\n' 2>/dev/null | sort || true
}

case "$ACTION" in
    build) build_baseline ;;
    install) install_baseline ;;
    cleanup-grub) need_root; cleanup_grub; write_baseline_entry ;;
    status) status ;;
    *) die "usage: $0 {build|install|cleanup-grub|status}" ;;
esac
