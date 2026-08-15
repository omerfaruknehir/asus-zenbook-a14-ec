#!/usr/bin/env bash
set -euo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
root=/usr/lib/aegis-hello
capture="$root/aegis_hello/capture.py"
patch_file="$repo/userspace/aegis-hello/patches/aegis-hello-0.8.3-v4l2-torch-runtime.patch"
backup=/var/backups/aegis-hello-capture.py.pre-a14-v4l2-torch
marker=A14_IR_TORCH_FORCE_GATE_RELEASE

[[ -f "$capture" ]] || {
  echo "Aegis Hello is not installed at $root" >&2
  exit 2
}
[[ -f "$patch_file" ]] || {
  echo "missing runtime patch: $patch_file" >&2
  exit 2
}
command -v v4l2-ctl >/dev/null 2>&1 || {
  echo "v4l2-ctl is required; install package v4l-utils first" >&2
  exit 2
}

version=$(PYTHONPATH="$root" /usr/bin/python3 - <<'PY'
import aegis_hello
print(aegis_hello.__version__)
PY
)
[[ "$version" == 0.8.3 ]] || {
  echo "runtime patch is pinned to Aegis Hello 0.8.3; installed=$version" >&2
  exit 3
}

if grep -q "$marker" "$capture"; then
  echo "A14_IR_TORCH_RUNTIME_PATCH=current"
  sudo systemctl restart aegis-hello.service
  exit 0
fi

# If the V4L2 conversion is not present yet, require the original 0.8.3 file to
# match our pinned runtime patch exactly before stopping the service.
needs_base_patch=0
if ! grep -q '_find_v4l2_flash_device' "$capture"; then
  needs_base_patch=1
  sudo patch --dry-run --batch --forward -d "$root" -p1 < "$patch_file" >/dev/null
fi

sudo install -D -m 0644 "$capture" "$backup"
sudo systemctl stop aegis-hello.service
restore_on_error=1
cleanup() {
  if [[ $restore_on_error -eq 1 ]]; then
    echo "IR Torch hotfix failed; restoring original capture.py" >&2
    sudo install -m 0644 "$backup" "$capture" || true
    sudo systemctl start aegis-hello.service || true
  fi
}
trap cleanup EXIT INT TERM

if [[ $needs_base_patch -eq 1 ]]; then
  sudo patch --batch --forward -d "$root" -p1 < "$patch_file"
fi

# Upgrade both freshly patched and already-V4L2-patched 0.8.3 installs. The old
# code enabled led_mode=2 while force_off=1 held the HM1092 IR gate LOW.
sudo /usr/bin/python3 - "$capture" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
s = path.read_text()
marker = "A14_IR_TORCH_FORCE_GATE_RELEASE"
if marker in s:
    raise SystemExit(0)
old = '''        # Stop the SOF-gated/strobe path first, then select the driver's dedicated
        # continuous Torch mode and its real current control.  The A14 exposes
        # led_mode=2 (Torch) and intensity_torch_mode in microamps.
        _write_required(dev / "force_off", 1)
'''
new = '''        # Stop the SOF-gated/strobe path first, then select the driver's dedicated
        # continuous Torch mode and its real current control.  The A14 exposes
        # led_mode=2 (Torch) and intensity_torch_mode in microamps.
        # A14_IR_TORCH_FORCE_GATE_RELEASE: force_off=1 is the immediate-LOW
        # safety gate used by synchronized flash windows. Continuous Torch has
        # no timed window to override it, so release that gate before Torch ON.
        _write_required(dev / "force_off", 0)
'''
if s.count(old) != 1:
    raise SystemExit(f"expected one old continuous-Torch force gate, found {s.count(old)}")
s = s.replace(old, new, 1)
path.write_text(s)
PY

sudo grep -q "$marker" "$capture"
sudo grep -q '_write_required(dev / "force_off", 0)' "$capture"
sudo grep -q '_write(dev / "force_off", 1)' "$capture"
sudo /usr/bin/python3 -m compileall -q "$root/aegis_hello"
sudo systemctl start aegis-hello.service
sudo systemctl is-active --quiet aegis-hello.service

restore_on_error=0
trap - EXIT INT TERM
echo "A14_IR_TORCH_RUNTIME_PATCH=PASS"
echo "backup=$backup"
