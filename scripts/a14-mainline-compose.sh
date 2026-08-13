#!/usr/bin/env bash
set -euo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
K=${1:-}
[ -n "$K" ] || { echo "usage: $0 /path/to/linux" >&2; exit 2; }
K=$(CDPATH= cd -- "$K" && pwd)

"$repo/scripts/a14-mainline-check.sh" "$K"
"$repo/kernel-patches/camera/check-kernel-prereqs.sh" "$K"

for patch in "$repo"/kernel-patches/camera/000*.patch; do
  [ -s "$patch" ] || continue
  if git -C "$K" apply --reverse --check "$patch" >/dev/null 2>&1; then
    echo "already applied: $(basename "$patch")"
  else
    git -C "$K" apply --check "$patch"
    git -C "$K" apply "$patch"
    echo "applied: $(basename "$patch")"
  fi
done

if [ "${A14_ENABLE_AOS:-0}" = 1 ]; then
  "$repo/kernel-patches/aos/cpas-handoff/apply.sh" "$K"
fi

printf '%s\n' 'mainline_source_composition=ready'
printf '%s\n' 'platform_modules=build-from-repository-root'
printf '%s\n' 'camera_board_stack=applied'
printf 'aos_stack=%s\n' "${A14_ENABLE_AOS:-0}"