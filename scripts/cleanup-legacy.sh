#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/var/backups/asus-zenbook-a14-ec/legacy-${STAMP}"
PATTERN='a14[_-]kbd([_-](led|backlight|init|userspace))?'
LEGACY_UNITS=(
  a14-kbd-init.service
  a14-kbd-userspace.service
  a14-kbd-led.service
  a14-kbd-backlight.service
)
mkdir -p "$BACKUP"

backup_file() {
  local path="$1"
  local target="$BACKUP$path"
  mkdir -p "$(dirname "$target")"
  cp -a "$path" "$target"
}

clean_text_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  grep -Eq "$PATTERN" "$file" 2>/dev/null || return 0

  echo "Cleaning legacy reference: $file"
  backup_file "$file"
  sed -i -E "/${PATTERN}/d" "$file"
  if ! grep -Eq '[^[:space:]#]' "$file"; then
    rm -f "$file"
  fi
}

clean_config_dir() {
  local directory="$1"
  [[ -d "$directory" ]] || return 0

  while IFS= read -r -d '' file; do
    clean_text_file "$file"
  done < <(find "$directory" -maxdepth 1 -type f -print0)
}

remove_or_mask_unit_file() {
  local unit_file="$1"
  local unit
  local owner
  unit="$(basename "$unit_file")"

  [[ -e "$unit_file" || -L "$unit_file" ]] || return 0

  if owner="$(dpkg-query -S "$unit_file" 2>/dev/null | head -n1)"; then
    echo "Preserving package-owned unit ($owner) and masking it: $unit"
    systemctl mask "$unit" >/dev/null 2>&1 || true
  else
    echo "Removing legacy systemd unit: $unit_file"
    backup_file "$unit_file"
    rm -f "$unit_file"
  fi
}

remove_or_mask_rule() {
  local rule="$1"
  local base owner
  base="$(basename "$rule")"

  [[ -f "$rule" ]] || return 0
  grep -Eq "$PATTERN" "$rule" 2>/dev/null || return 0

  if owner="$(dpkg-query -S "$rule" 2>/dev/null | head -n1)"; then
    echo "Masking package-owned legacy udev rule ($owner): $rule"
    mkdir -p /etc/udev/rules.d
    ln -sfn /dev/null "/etc/udev/rules.d/$base"
  else
    echo "Removing legacy udev rule: $rule"
    backup_file "$rule"
    rm -f "$rule"
  fi
}

# Stop known loaders before touching their files or the module.
for unit in "${LEGACY_UNITS[@]}"; do
  systemctl disable --now "$unit" >/dev/null 2>&1 || true
done

pkill -TERM -f 'a14-kbd-backlight|a14-kbd-userspace|a14_kbd_backlight' 2>/dev/null || true
sleep 1
pkill -KILL -f 'a14-kbd-backlight|a14-kbd-userspace|a14_kbd_backlight' 2>/dev/null || true

# Remove or mask system and user units from every normal lookup directory.
for directory in \
  /etc/systemd/system \
  /run/systemd/system \
  /usr/local/lib/systemd/system \
  /usr/lib/systemd/system \
  /lib/systemd/system \
  /etc/systemd/user \
  /usr/local/lib/systemd/user \
  /usr/lib/systemd/user \
  /lib/systemd/user; do
  [[ -d "$directory" ]] || continue

  while IFS= read -r -d '' unit_file; do
    if [[ "$(basename "$unit_file")" =~ $PATTERN ]] || \
       grep -Eq "$PATTERN" "$unit_file" 2>/dev/null; then
      unit="$(basename "$unit_file")"
      systemctl disable --now "$unit" >/dev/null 2>&1 || true
      remove_or_mask_unit_file "$unit_file"
    fi
  done < <(find "$directory" -maxdepth 2 \( -type f -o -type l \) -print0)
done

while IFS= read -r -d '' link; do
  target="$(readlink "$link" 2>/dev/null || true)"
  if [[ "$target" != "/dev/null" ]] && \
     [[ "$(basename "$link") $target" =~ $PATTERN ]]; then
    echo "Removing legacy systemd link: $link"
    backup_file "$link"
    rm -f "$link"
  fi
done < <(find /etc/systemd/system -type l -print0 2>/dev/null)

systemctl daemon-reload
systemctl reset-failed "${LEGACY_UNITS[@]}" >/dev/null 2>&1 || true

# Remove all common non-systemd autoload paths.
clean_text_file /etc/modules
clean_text_file /etc/initramfs-tools/modules
clean_config_dir /etc/modules-load.d
clean_config_dir /etc/modprobe.d
clean_config_dir /usr/local/lib/modules-load.d
clean_config_dir /usr/local/lib/modprobe.d

for directory in /etc/udev/rules.d /usr/local/lib/udev/rules.d /usr/lib/udev/rules.d /lib/udev/rules.d; do
  [[ -d "$directory" ]] || continue
  while IFS= read -r -d '' rule; do
    remove_or_mask_rule "$rule"
  done < <(find "$directory" -maxdepth 1 -type f -print0)
done

# Remove unowned initramfs hooks/scripts that explicitly add or load the bridge.
for directory in \
  /etc/initramfs-tools/hooks \
  /etc/initramfs-tools/scripts \
  /usr/local/share/initramfs-tools/hooks \
  /usr/local/share/initramfs-tools/scripts \
  /usr/share/initramfs-tools/hooks \
  /usr/share/initramfs-tools/scripts; do
  [[ -d "$directory" ]] || continue

  while IFS= read -r -d '' file; do
    grep -Eq "$PATTERN" "$file" 2>/dev/null || continue
    if owner="$(dpkg-query -S "$file" 2>/dev/null | head -n1)"; then
      echo "WARNING: package-owned initramfs file still references legacy module ($owner): $file" >&2
    else
      echo "Removing legacy initramfs file: $file"
      backup_file "$file"
      rm -f "$file"
    fi
  done < <(find "$directory" -type f -print0)
done

# Remove the live module and all persistent copies.
modprobe -r a14_kbd_led 2>/dev/null || rmmod a14_kbd_led 2>/dev/null || true

while IFS= read -r line; do
  module="${line%%/*}"
  remainder="${line#*/}"
  version="${remainder%%,*}"
  case "$module" in
    a14-kbd-led|a14_kbd_led|a14-kbd-backlight|a14_kbd_backlight)
      echo "Removing legacy DKMS entry: $module/$version"
      dkms remove -m "$module" -v "$version" --all >/dev/null 2>&1 || true
      ;;
  esac
done < <(dkms status 2>/dev/null || true)

while IFS= read -r -d '' module_file; do
  if dpkg-query -S "$module_file" >/dev/null 2>&1; then
    echo "Preserving package-owned legacy module: $module_file"
  else
    echo "Removing legacy module file: $module_file"
    backup_file "$module_file"
    rm -f "$module_file"
  fi
done < <(find /lib/modules -type f -name 'a14_kbd_led.ko*' -print0 2>/dev/null)

for source_tree in /usr/src/a14-kbd-led-* /usr/src/a14_kbd_led-*; do
  [[ -e "$source_tree" ]] || continue
  echo "Removing legacy source tree: $source_tree"
  backup_file "$source_tree"
  rm -rf "$source_tree"
done

rm -f /usr/local/bin/a14-kbd-backlight

# Block future modprobe-based resurrection even if a stale copy appears later.
cat >/etc/modprobe.d/blacklist-a14-kbd-led-legacy.conf <<'EOF'
# Legacy virtual LED bridge conflicts with hid_asus_ec.
blacklist a14_kbd_led
install a14_kbd_led /bin/false
EOF

depmod -a
udevadm control --reload 2>/dev/null || true

if command -v update-initramfs >/dev/null 2>&1; then
  update-initramfs -u -k all
fi

# Re-register the new HID LED after the old virtual LED name is released.
if lsmod | grep -q '^hid_asus_ec\b'; then
  modprobe -r hid_asus_ec
  modprobe hid_asus_ec
fi

# Fail visibly only if an actual legacy kernel module binary remains embedded.
# The intentional blacklist file may contain the same name and is expected.
if command -v lsinitramfs >/dev/null 2>&1 && \
   lsinitramfs "/boot/initrd.img-$(uname -r)" 2>/dev/null | \
   grep -Eq '(^|/)(a14_kbd_led|a14-kbd-led)\.ko(\.(gz|xz|zst))?$'; then
  echo "ERROR: current initramfs still contains the a14_kbd_led kernel module" >&2
  echo "Inspect initramfs hooks and package ownership before rebooting." >&2
  exit 1
fi

echo "Legacy A14 keyboard bridge cleanup complete. Backup: $BACKUP"
