#!/usr/bin/env bash
set -euo pipefail

# Source-tree helper for Aegis Hello 0.8.3.  This deliberately patches source
# rather than editing an installed Python file in place.
root=${1:-}
repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
patch_file="$repo/userspace/aegis-hello/patches/aegis-hello-0.8.3-v4l2-torch.patch"

if [[ -z "$root" ]]; then
  echo "usage: $0 /path/to/aegis-hello-0.8.3" >&2
  exit 2
fi
root=$(CDPATH= cd -- "$root" 2>/dev/null && pwd) || {
  echo "Aegis source path is not accessible: $1" >&2
  exit 2
}
[[ -f "$root/src/aegis_hello/capture.py" ]] || {
  echo "not an Aegis Hello source tree: $root" >&2
  exit 2
}

grep -q '__version__ = "0.8.3"' "$root/src/aegis_hello/__init__.py" || {
  echo "this patch is pinned to Aegis Hello 0.8.3" >&2
  exit 3
}

if grep -q '_find_v4l2_flash_device' "$root/src/aegis_hello/capture.py"; then
  echo "A14_IR_TORCH_PATCH=current"
else
  patch -d "$root" -p1 --forward --batch < "$patch_file"
fi

python3 -m compileall -q "$root/src/aegis_hello"
PYTHONPATH="$root/src" python3 -m unittest discover -s "$root/tests" -q

echo "A14_IR_TORCH_PATCH=PASS"
echo "Install with: sudo $root/scripts/install.sh"
