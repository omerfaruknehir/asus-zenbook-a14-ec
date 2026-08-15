#!/usr/bin/env python3
"""Run the native five-profile GNOME builder with stock Settings row styling.

GNOME Shell keeps profile icons in Quick Settings. GNOME Settings > Power keeps
its normal icon-free power-profile rows; this wrapper changes only the profile
vocabulary and labels there.
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


def patch_control_center_semantic(src: Path) -> None:
    h = src / "panels/power/cc-power-profile-row.h"
    c = src / "panels/power/cc-power-profile-row.c"

    hs = h.read_text(encoding="utf-8")
    cs = c.read_text(encoding="utf-8")

    hs = base.replace_once(
        hs,
        """typedef enum\n{\n  CC_POWER_PROFILE_PERFORMANCE,\n  CC_POWER_PROFILE_BALANCED,\n  CC_POWER_PROFILE_POWER_SAVER,\n  NUM_CC_POWER_PROFILES,\n""",
        """typedef enum\n{\n  CC_POWER_PROFILE_FULL_SPEED,\n  CC_POWER_PROFILE_PERFORMANCE,\n  CC_POWER_PROFILE_BALANCED,\n  CC_POWER_PROFILE_POWER_SAVER,\n  CC_POWER_PROFILE_QUIET,\n  NUM_CC_POWER_PROFILES,\n""",
        "control-center-five-profile-enum",
    )

    cs = base.replace_once(
        cs,
        """  CcPowerProfileRow *self;\n  const char *text, *subtext;\n\n  self = g_object_new (CC_TYPE_POWER_PROFILE_ROW, NULL);\n\n  self->power_profile = power_profile;\n  switch (self->power_profile)\n    {\n      case CC_POWER_PROFILE_PERFORMANCE:\n        text = C_(\"Power profile\", \"P_erformance\");\n        subtext = _(\"High performance and power usage\");\n        break;\n      case CC_POWER_PROFILE_BALANCED:\n        text = C_(\"Power profile\", \"Ba_lanced\");\n        subtext = _(\"Standard performance and power usage\");\n        break;\n      case CC_POWER_PROFILE_POWER_SAVER:\n        text = C_(\"Power profile\", \"P_ower Saver\");\n        subtext = _(\"Reduced performance and power usage\");\n        break;\n      default:\n        g_assert_not_reached ();\n    }\n\n  adw_preferences_row_set_title (ADW_PREFERENCES_ROW (self), text);\n""",
        """  CcPowerProfileRow *self;\n  const char *text, *subtext;\n\n  self = g_object_new (CC_TYPE_POWER_PROFILE_ROW, NULL);\n\n  self->power_profile = power_profile;\n  switch (self->power_profile)\n    {\n      case CC_POWER_PROFILE_FULL_SPEED:\n        text = C_(\"Power profile\", \"_Full Speed\");\n        subtext = _(\"Maximum cooling and no artificial CPU frequency cap\");\n        break;\n      case CC_POWER_PROFILE_PERFORMANCE:\n        text = C_(\"Power profile\", \"P_erformance\");\n        subtext = _(\"High performance and power usage\");\n        break;\n      case CC_POWER_PROFILE_BALANCED:\n        text = C_(\"Power profile\", \"Ba_lanced\");\n        subtext = _(\"Standard performance and power usage\");\n        break;\n      case CC_POWER_PROFILE_POWER_SAVER:\n        text = C_(\"Power profile\", \"P_ower Saver\");\n        subtext = _(\"Reduced performance and power usage\");\n        break;\n      case CC_POWER_PROFILE_QUIET:\n        text = C_(\"Power profile\", \"_Quiet\");\n        subtext = _(\"Acoustic-first mode with strong CPU throttling\");\n        break;\n      default:\n        g_assert_not_reached ();\n    }\n\n  adw_preferences_row_set_title (ADW_PREFERENCES_ROW (self), text);\n""",
        "control-center-five-profile-rows-stock-style",
    )

    cs = base.replace_once(
        cs,
        """CcPowerProfile\ncc_power_profile_from_str (const char *profile)\n{\n  if (g_strcmp0 (profile, \"power-saver\") == 0)\n    return CC_POWER_PROFILE_POWER_SAVER;\n  if (g_strcmp0 (profile, \"balanced\") == 0)\n    return CC_POWER_PROFILE_BALANCED;\n  if (g_strcmp0 (profile, \"performance\") == 0)\n    return CC_POWER_PROFILE_PERFORMANCE;\n""",
        """CcPowerProfile\ncc_power_profile_from_str (const char *profile)\n{\n  if (g_strcmp0 (profile, \"full-speed\") == 0)\n    return CC_POWER_PROFILE_FULL_SPEED;\n  if (g_strcmp0 (profile, \"power-saver\") == 0)\n    return CC_POWER_PROFILE_POWER_SAVER;\n  if (g_strcmp0 (profile, \"balanced\") == 0)\n    return CC_POWER_PROFILE_BALANCED;\n  if (g_strcmp0 (profile, \"performance\") == 0)\n    return CC_POWER_PROFILE_PERFORMANCE;\n  if (g_strcmp0 (profile, \"quiet\") == 0)\n    return CC_POWER_PROFILE_QUIET;\n""",
        "control-center-profile-from-string",
    )

    cs = base.replace_once(
        cs,
        """const char *\ncc_power_profile_to_str (CcPowerProfile profile)\n{\n  switch (profile)\n  {\n  case CC_POWER_PROFILE_POWER_SAVER:\n    return \"power-saver\";\n  case CC_POWER_PROFILE_BALANCED:\n    return \"balanced\";\n  case CC_POWER_PROFILE_PERFORMANCE:\n    return \"performance\";\n""",
        """const char *\ncc_power_profile_to_str (CcPowerProfile profile)\n{\n  switch (profile)\n  {\n  case CC_POWER_PROFILE_FULL_SPEED:\n    return \"full-speed\";\n  case CC_POWER_PROFILE_POWER_SAVER:\n    return \"power-saver\";\n  case CC_POWER_PROFILE_BALANCED:\n    return \"balanced\";\n  case CC_POWER_PROFILE_PERFORMANCE:\n    return \"performance\";\n  case CC_POWER_PROFILE_QUIET:\n    return \"quiet\";\n""",
        "control-center-profile-to-string",
    )

    required_h = (
        "CC_POWER_PROFILE_FULL_SPEED",
        "CC_POWER_PROFILE_QUIET",
        "NUM_CC_POWER_PROFILES",
    )
    required_c = (
        'g_strcmp0 (profile, "quiet")',
        'g_strcmp0 (profile, "full-speed")',
        'return "quiet";',
        'return "full-speed";',
        'C_("Power profile", "_Quiet")',
        'C_("Power profile", "_Full Speed")',
    )
    forbidden_c = (
        "a14-power-profile-quiet-symbolic",
        "a14-power-profile-full-speed-symbolic",
        "gtk_image_set_from_icon_name",
    )
    if any(token not in hs for token in required_h):
        raise RuntimeError("GNOME Control Center enum semantic edit incomplete")
    if any(token not in cs for token in required_c):
        raise RuntimeError("GNOME Control Center C semantic edit incomplete")
    if any(token in cs for token in forbidden_c):
        raise RuntimeError("GNOME Settings profile rows unexpectedly gained profile icons")

    h.write_text(hs, encoding="utf-8")
    c.write_text(cs, encoding="utf-8")
    print("gnome_control_center_five_profile_semantic=applied")
    print("gnome_settings_profile_icons=stock-none")


base.patch_control_center_semantic = patch_control_center_semantic


if __name__ == "__main__":
    try:
        raise SystemExit(base.main())
    except (RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"A14_GNOME_NATIVE_FIVE_PROFILE_INSTALL=FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
