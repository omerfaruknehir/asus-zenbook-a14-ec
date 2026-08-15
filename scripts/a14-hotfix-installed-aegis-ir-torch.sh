#!/usr/bin/env bash
set -euo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
root=/usr/lib/aegis-hello
capture="$root/aegis_hello/capture.py"
patch_file="$repo/userspace/aegis-hello/patches/aegis-hello-0.8.3-v4l2-torch-runtime.patch"
backup=/var/backups/aegis-hello-capture.py.pre-a14-v4l2-torch

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

if grep -q '_find_v4l2_flash_device' "$capture"; then
  echo "A14_IR_TORCH_RUNTIME_PATCH=current"
  sudo systemctl restart aegis-hello.service
  exit 0
fi

# Refuse a fuzzy/partial edit. The dry-run must match the installed 0.8.3 file
# exactly enough for patch(1) to apply before the service is stopped.
sudo patch --dry-run --batch --forward -d "$root" -p1 < "$patch_file" >/dev/null

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

sudo patch --batch --forward -d "$root" -p1 < "$patch_file"
sudo /usr/bin/python3 -m compileall -q "$root/aegis_hello"
sudo systemctl start aegis-hello.service
sudo systemctl is-active --quiet aegis-hello.service

restore_on_error=0
trap - EXIT INT TERM
echo "A14_IR_TORCH_RUNTIME_PATCH=PASS"
echo "backup=$backup"
