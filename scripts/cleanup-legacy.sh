#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/var/backups/asus-zenbook-a14-ec/legacy-${STAMP}"
PATTERN='a14_kbd_led|a14-kbd-led|a14_kbd_backlight|a14-kbd-backlight'
mkdir -p "$BACKUP"

backup_file() {
  local path="$1"
  local target="$BACKUP$path"
  mkdir -p "$(dirname "$target")"
  cp -a "$path" "$target"
}

clean_config_dir() {
  local directory="$1"
  [[ -d "$directory" ]] || return 0

  while IFS= read -r -d '' file; do
    if grep -Eq "$PATTERN" "$file" 2>/dev/null; then
      echo "Cleaning legacy reference: $file"
      backup_file "$file"
      sed -i -E "/${PATTERN}/d" "$file"
      if ! grep -Eq '[^[:space:]#]' "$file"; then
        rm -f "$file"
      fi
    fi
  done < <(find "$directory" -maxdepth 1 -type f -print0)
}

# Stop and remove locally-installed system units that load the old bridge.
for directory in \
  /etc/systemd/system \
  /usr/local/lib/systemd/system \
  /etc/systemd/user \
  /usr/local/lib/systemd/user; do
  [[ -d "$directory" ]] || continue

  while IFS= read -r -d '' unit_file; do
    if [[ "$(basename "$unit_file")" =~ $PATTERN ]] || \
       grep -Eq "$PATTERN" "$unit_file" 2>/dev/null; then
      unit="$(basename "$unit_file")"
      echo "Removing legacy systemd unit: $unit_file"
      systemctl disable --now "$unit" >/dev/null 2>&1 || true
      backup_file "$unit_file"
      rm -f "$unit_file"
    fi
  done < <(find "$directory" -maxdepth 2 \( -type f -o -type l \) -print0)
done

# Remove dangling wants/requires symlinks that reference removed units.
while IFS= read -r -d '' link; do
  target="$(readlink "$link" 2>/dev/null || true)"
  if [[ "$(basename "$link") $target" =~ $PATTERN ]]; then
    echo "Removing legacy systemd link: $link"
    backup_file "$link"
    rm -f "$link"
  fi
done < <(find /etc/systemd/system -type l -print0 2>/dev/null)

# Unload and remove the old out-of-tree module.
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

clean_config_dir /etc/modules-load.d
clean_config_dir /etc/modprobe.d

while IFS= read -r -d '' module_file; do
  if dpkg-query -S "$module_file" >/dev/null 2>&1; then
    echo "Preserving package-owned legacy module: $module_file"
  else
    echo "Removing legacy module file: $module_file"
    backup_file "$module_file"
    rm -f "$module_file"
  fi
done < <(find /lib/modules -type f -name 'a14_kbd_led.ko*' -print0 2>/dev/null)

rm -f /usr/local/bin/a14-kbd-backlight

systemctl daemon-reload
depmod -a
if command -v update-initramfs >/dev/null 2>&1; then
  update-initramfs -u -k all
fi

echo "Legacy A14 keyboard bridge cleanup complete. Backup: $BACKUP"
