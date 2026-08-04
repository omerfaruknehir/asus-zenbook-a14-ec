#!/usr/bin/env python3
"""Apply small idempotent userspace/package fixes before validation."""
from pathlib import Path

path = Path("scripts/asus-a14-control")
text = path.read_text()
old = '''unit_state() {
  systemctl is-active "$1" 2>/dev/null || printf 'inactive\\n'
}
'''
new = '''unit_state() {
  if systemctl is-active --quiet "$1" 2>/dev/null; then
    printf 'active\\n'
  else
    printf 'inactive\\n'
  fi
}
'''
if new not in text:
    if old not in text:
        raise SystemExit("Cannot fix unit_state: expected source block not found")
    text = text.replace(old, new, 1)
path.write_text(text)
print("Userspace status fixes applied")
