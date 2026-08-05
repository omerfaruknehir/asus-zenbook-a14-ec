#!/bin/sh
# Apply the source patch, then repair/validate CompositeTemplate metadata.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
python3 "$script_dir/apply-a14-cpu-info.py" "$@"
python3 "$script_dir/repair-a14-cpu-info.py" "$@"
