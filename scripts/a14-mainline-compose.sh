#!/usr/bin/env bash

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
K=${1:-}
ok=1

if [ -z "$K" ]; then
  echo "usage: $0 /path/to/linux" >&2
  ok=0
else
  K=$(CDPATH= cd -- "$K" 2>/dev/null && pwd)
  if [ -z "$K" ]; then
    echo "kernel source path is not accessible" >&2
    ok=0
  fi
fi

if [ "$ok" -eq 1 ]; then
  "$repo/scripts/a14-mainline-check.sh" "$K" || ok=0
fi

if [ "$ok" -eq 1 ]; then
  "$repo/kernel-patches/camera/check-kernel-prereqs.sh" "$K" || ok=0
fi

if [ "$ok" -eq 1 ]; then
  python3 "$repo/scripts/apply-mainline-platform-profile-dt.py" "$K" || ok=0
fi

if [ "$ok" -eq 1 ]; then
  for patch in "$repo"/kernel-patches/camera/000*.patch; do
    [ -s "$patch" ] || continue
    if git -C "$K" apply --reverse --check "$patch" >/dev/null 2>&1; then
      echo "already applied: $(basename "$patch")"
    elif git -C "$K" apply --check "$patch"; then
      if git -C "$K" apply "$patch"; then
        echo "applied: $(basename "$patch")"
      else
        ok=0
        break
      fi
    else
      ok=0
      break
    fi
  done
fi

if [ "$ok" -eq 1 ] && [ "${A14_ENABLE_AOS:-0}" = 1 ]; then
  "$repo/kernel-patches/aos/cpas-handoff/apply.sh" "$K" || ok=0
fi

# If the caller already created a kernel .config, enforce X1E's standard SCMI
# CPUFreq chain now. If not, leave source composition usable and print the exact
# follow-up command; a14-mainline-scmi-cpufreq-config.sh can create arm64
# defconfig itself.
scmi_config=pending
if [ "$ok" -eq 1 ] && [ -f "$K/.config" ]; then
  if "$repo/scripts/a14-mainline-scmi-cpufreq-config.sh" "$K"; then
    scmi_config=ready
  else
    scmi_config=failed
    ok=0
  fi
fi

if [ "$ok" -eq 1 ]; then
  printf '%s\n' 'mainline_source_composition=ready'
  printf '%s\n' 'platform_profile_dt=enabled'
  printf '%s\n' 'platform_modules=build-from-repository-root'
  printf '%s\n' 'camera_board_stack=applied'
  printf 'aos_stack=%s\n' "${A14_ENABLE_AOS:-0}"
  printf 'scmi_cpufreq_config=%s\n' "$scmi_config"
  if [ "$scmi_config" = pending ]; then
    printf 'next_config_step=%q %q\n' \
      "$repo/scripts/a14-mainline-scmi-cpufreq-config.sh" "$K"
  fi
else
  printf '%s\n' 'mainline_source_composition=failed' >&2
fi

test "$ok" -eq 1
