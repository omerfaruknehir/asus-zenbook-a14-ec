#!/usr/bin/env python3
"""Compatibility entry point for the native GNOME five-mode A14 builder.

The base builder now preserves GNOME Settings' stock icon-free row styling by
default, so the former clean-UI override is no longer necessary. Keep this file
as the stable entry point used by a14-gnome-native-install.sh.
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


if __name__ == "__main__":
    try:
        raise SystemExit(base.main())
    except (RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"A14_GNOME_NATIVE_FIVE_PROFILE_INSTALL=FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
