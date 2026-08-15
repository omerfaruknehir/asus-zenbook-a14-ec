#!/usr/bin/env python3
"""Stable entry point for the native GNOME five-mode A14 builder.

The base builder preserves Settings' stock icon-free rows. This wrapper also
normalizes Control Center's enum order to the same conventional high-to-low
order GNOME Shell gets by reversing the bridge's ascending Profiles array:
Full Speed, Turbo, Normal, Quiet, Whisper.
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASE_PATH = HERE / "a14-gnome-native-five-profile.py"

spec = importlib.util.spec_from_file_location("a14_gnome_native_five_profile_base", BASE_PATH)
if spec is None or spec.loader is None:
    raise SystemExit(f"cannot load base GNOME builder: {BASE_PATH}")
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)

_base_patch_control_center = base.patch_control_center_semantic


def patch_control_center_semantic(src: Path) -> None:
    _base_patch_control_center(src)
    header = src / "panels/power/cc-power-profile-row.h"
    text = header.read_text(encoding="utf-8")
    old = """  CC_POWER_PROFILE_FULL_SPEED,\n  CC_POWER_PROFILE_PERFORMANCE,\n  CC_POWER_PROFILE_BALANCED,\n  CC_POWER_PROFILE_POWER_SAVER,\n  CC_POWER_PROFILE_QUIET,\n"""
    new = """  CC_POWER_PROFILE_FULL_SPEED,\n  CC_POWER_PROFILE_PERFORMANCE,\n  CC_POWER_PROFILE_BALANCED,\n  CC_POWER_PROFILE_QUIET,\n  CC_POWER_PROFILE_POWER_SAVER,\n"""
    if new not in text:
        if text.count(old) != 1:
            raise RuntimeError("cannot normalize GNOME Settings A14 profile order")
        text = text.replace(old, new, 1)
        header.write_text(text, encoding="utf-8")
    print("gnome_settings_profile_order=full-speed,turbo,normal,quiet,whisper")


base.patch_control_center_semantic = patch_control_center_semantic


if __name__ == "__main__":
    try:
        raise SystemExit(base.main())
    except (RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"A14_GNOME_NATIVE_FIVE_PROFILE_INSTALL=FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
