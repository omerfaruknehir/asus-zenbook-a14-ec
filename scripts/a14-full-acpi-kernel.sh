#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ACTION="${1:-status}"
BASE_KVER="${A14_FULL_ACPI_BASE_KVER:-7.1.5-070105-generic}"
BASE_TAG="v7.1.5"
BASE_COMMIT="155b42bec9cbb6b8cdc47dd9bd09503a81fbe493"
LOCALVERSION="-a14-acpi-full0"
KREL="7.1.5${LOCALVERSION}"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
WORK="${A14_FULL_ACPI_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="$WORK/linux-7.1.5"
OUT="$WORK/build"
META="$WORK/meta.env"
GRUB_SNIPPET="/etc/grub.d/41_a14_full_acpi"
ENTRY="ASUS Zenbook A14 — FULL ACPI experimental ($KREL)"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "this action requires sudo/root"; }
need_user(){ [[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as your normal user, not root"; }
check_arch(){ case "$(uname -m)" in aarch64|arm64) ;; *) die "AArch64 host required; found $(uname -m)";; esac; }

kernel_config_source(){
  if [[ -r "/boot/config-$BASE_KVER" ]]; then echo "/boot/config-$BASE_KVER";
  elif [[ "$(uname -r)" == "$BASE_KVER" && -r /proc/config.gz ]]; then echo /proc/config.gz;
  else return 1; fi
}

prepare(){
  need_user; check_arch
  for c in git python3 make gcc bc bison flex perl rsync pahole openssl cpio; do need "$c"; done
  mkdir -p "$WORK"
  if [[ ! -d "$SRC/.git" ]]; then git clone --filter=blob:none --no-checkout https://github.com/gregkh/linux.git "$SRC"; fi
  git -C "$SRC" fetch --force --depth=1 origin "refs/tags/$BASE_TAG:refs/tags/$BASE_TAG"
  git -C "$SRC" checkout --detach "$BASE_TAG"
  [[ "$(git -C "$SRC" rev-parse HEAD)" == "$BASE_COMMIT" ]] || die "unexpected $BASE_TAG commit"
  git -C "$SRC" reset --hard "$BASE_COMMIT"; git -C "$SRC" clean -fdx
  python3 "$ROOT/scripts/apply-a14-full-acpi.py" "$SRC"
  rm -rf "$OUT"; mkdir -p "$OUT"
  cfg="$(kernel_config_source)" || die "cannot find config for $BASE_KVER"
  if [[ "$cfg" == *.gz ]]; then zcat "$cfg" >"$OUT/.config"; else cp "$cfg" "$OUT/.config"; fi
  C="$SRC/scripts/config --file $OUT/.config"
  $C --set-str LOCALVERSION "$LOCALVERSION"
  $C --disable LOCALVERSION_AUTO
  $C --enable ACPI --enable EFI --enable OF --enable PCI --enable PCI_ACPI
  $C --enable ACPI_WMI --enable ACPI_BATTERY --enable ACPI_VIDEO
  $C --enable I2C --enable I2C_QCOM_GENI
  $C --enable PINCTRL_MSM --enable PINCTRL_X1E80100
  $C --enable ARM64_PLATFORM_DEVICES --enable QCOM_WOA_PEP_COMPAT
  $C --enable ASUS_WMI_ARM64 --enable ASUS_NB_WMI_ARM64
  $C --enable TCG_TPM --enable TCG_CRB
  $C --set-str SYSTEM_TRUSTED_KEYS "" --set-str SYSTEM_REVOCATION_KEYS ""
  export LOCALVERSION=
  make -C "$SRC" O="$OUT" olddefconfig
  [[ "$(make -s -C "$SRC" O="$OUT" kernelrelease)" == "$KREL" ]] || die "unexpected kernelrelease"
  cat >"$META" <<EOF
KREL='$KREL'
SRC='$SRC'
OUT='$OUT'
BASE_COMMIT='$BASE_COMMIT'
EOF
  say "A14_FULL_ACPI_PREPARED=1"; say "kernelrelease=$KREL"; say "source=$SRC"; say "build=$OUT"
}

build(){
  prepare
  make -C "$SRC" O="$OUT" -j"${A14_BUILD_JOBS:-$(nproc)}" Image modules
  [[ -s "$OUT/arch/arm64/boot/Image" ]] || die "Image missing"
  say "A14_FULL_ACPI_BUILD=COMPLETE"
  say "image=$OUT/arch/arm64/boot/Image"
  say "sha256=$(sha256sum "$OUT/arch/arm64/boot/Image" | awk '{print $1}')"
}

load_meta(){ [[ -r "$META" ]] || die "run '$0 build' first"; source "$META"; [[ "$KREL" == "7.1.5-a14-acpi-full0" ]] || die "metadata mismatch"; }

write_grub(){
  need grub-probe; need grub-mkrelpath; need update-grub
  kernel="/boot/vmlinuz-$KREL"; initrd="/boot/initrd.img-$KREL"
  uuid="$(grub-probe --target=fs_uuid "$kernel")"
  kp="$(grub-mkrelpath "$kernel")"; ip="$(grub-mkrelpath "$initrd")"
  args=()
  for arg in $(cat /proc/cmdline); do case "$arg" in BOOT_IMAGE=*|initrd=*|acpi=*) ;; *) args+=("$arg");; esac; done
  cmdline="${args[*]} acpi=force"
  cat >"$GRUB_SNIPPET" <<EOF
#!/bin/sh
exec tail -n +3 \$0
# ACPI-only UX3407RA experiment. Intentionally NO devicetree command.
menuentry '$ENTRY' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root $uuid
    linux $kp $cmdline
    initrd $ip
}
EOF
  chmod 0755 "$GRUB_SNIPPET"
  ! grep -qE '^[[:space:]]*devicetree[[:space:]]' "$GRUB_SNIPPET" || die "GRUB safety check: unexpected DT"
  grep -q 'acpi=force' "$GRUB_SNIPPET" || die "GRUB safety check: acpi=force missing"
  update-grub
}

install(){
  need_root; check_arch; load_meta
  [[ "$(uname -r)" != "$KREL" ]] || die "refusing to reinstall running experimental kernel"
  export LOCALVERSION=
  make -C "$SRC" O="$OUT" modules_install
  ln -sfn "$OUT" "/lib/modules/$KREL/build"; ln -sfn "$SRC" "/lib/modules/$KREL/source"
  install -m0644 "$OUT/arch/arm64/boot/Image" "/boot/vmlinuz-$KREL"
  [[ ! -s "$OUT/System.map" ]] || install -m0644 "$OUT/System.map" "/boot/System.map-$KREL"
  install -m0644 "$OUT/.config" "/boot/config-$KREL"
  depmod -a "$KREL"
  rm -f "/boot/initrd.img-$KREL"; update-initramfs -c -k "$KREL"
  write_grub
  say "A14_FULL_ACPI_INSTALL=COMPLETE"
  say "grub_entry=$ENTRY"
  say "dtb_loaded=false"
  say "normal_kernel_untouched=$BASE_KVER"
  say "Select the entry manually for the first boot; do not make it default yet."
}

status(){
  say "===== A14 FULL ACPI STATUS ====="
  say "running_kernel=$(uname -r)"; say "expected_kernel=$KREL"; say "cmdline=$(cat /proc/cmdline)"
  say "acpi_force=$(grep -qw 'acpi=force' /proc/cmdline && echo yes || echo no)"
  say "device_tree=$([[ -d /proc/device-tree ]] && echo PRESENT_UNEXPECTED || echo absent_expected)"
  say "acpi_tables=$([[ -d /sys/firmware/acpi/tables ]] && echo present || echo absent)"
  say "grub_snippet=$([[ -f "$GRUB_SNIPPET" ]] && echo present || echo absent)"
  if [[ "$(uname -r)" == "$KREL" ]]; then
    say "----- key ACPI devices -----"
    for x in /sys/bus/acpi/devices/{QCOM0C17,QCOM0C0D,QCOM0C10,PNP0C14}*; do [[ -e "$x" ]] && echo "$x"; done
    say "----- buses / WMI / TPM -----"
    ls -ld /sys/bus/i2c/devices/i2c-* /sys/bus/wmi/devices/* /dev/tpm* 2>/dev/null || true
    say "----- diagnostic dmesg -----"
    dmesg 2>/dev/null | grep -Ei 'ACPI|QCOM0C|PEP|GENI|I2C|WMI|ASUS|TPM|IORT|PCI' | tail -n 400 || true
  fi
}

remove(){
  need_root
  [[ "$(uname -r)" != "$KREL" ]] || die "boot the known-good DT kernel before removal"
  rm -f "$GRUB_SNIPPET" "/boot/vmlinuz-$KREL" "/boot/initrd.img-$KREL" "/boot/System.map-$KREL" "/boot/config-$KREL"
  rm -rf "/lib/modules/$KREL"
  update-grub
  say "A14_FULL_ACPI_REMOVE=COMPLETE"
}

case "$ACTION" in prepare) prepare;; build) build;; install) install;; status) status;; remove) remove;; *) die "usage: $0 {prepare|build|install|status|remove}";; esac
