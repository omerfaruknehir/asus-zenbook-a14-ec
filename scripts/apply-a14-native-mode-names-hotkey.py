#!/usr/bin/env python3
from pathlib import Path

p = Path("asus_zenbook_a14_ec.c")
s = p.read_text()

MARKER = "A14_NATIVE_MODE_NAMES_HOTKEY"
if MARKER in s:
    print("a14_native_mode_names_hotkey=current")
    raise SystemExit(0)

if "EC_FW_FAN_PROFILE_FULL_SPEED" not in s or "PLATFORM_PROFILE_MAX_POWER" not in s:
    raise SystemExit("native mode names/hotkey layer requires all four ASUS firmware modes first")


def once(old: str, new: str, label: str) -> None:
    global s
    count = s.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one source anchor, found {count}")
    s = s.replace(old, new, 1)


# The internal enum names remain aligned with Linux platform_profile vocabulary,
# but the private A14 sysfs/API uses the actual ASUS firmware mode names.
once(
    '''static const char *asus_ec_profile_name(enum asus_ec_profile profile)\n{\n\tswitch (profile) {\n\tcase ASUS_EC_PROFILE_QUIET:\n\t\treturn "quiet";\n\tcase ASUS_EC_PROFILE_BALANCED:\n\t\treturn "balanced";\n\tcase ASUS_EC_PROFILE_PERFORMANCE:\n\t\treturn "performance";\n\tcase ASUS_EC_PROFILE_FULL_SPEED:\n\t\treturn "full-speed";\n\tdefault:\n\t\treturn "custom";\n\t}\n}\n''',
    '''#define A14_NATIVE_MODE_NAMES_HOTKEY 1\n\nstatic const char *asus_ec_profile_name(enum asus_ec_profile profile)\n{\n\tswitch (profile) {\n\tcase ASUS_EC_PROFILE_QUIET:\n\t\treturn "quiet";\n\tcase ASUS_EC_PROFILE_BALANCED:\n\t\treturn "normal";\n\tcase ASUS_EC_PROFILE_PERFORMANCE:\n\t\treturn "turbo";\n\tcase ASUS_EC_PROFILE_FULL_SPEED:\n\t\treturn "full-speed";\n\tdefault:\n\t\treturn "custom";\n\t}\n}\n''',
    "native user-facing profile names",
)

once(
    '''static int asus_ec_profile_parse(const char *buf)\n{\n\tif (sysfs_streq(buf, "quiet"))\n\t\treturn ASUS_EC_PROFILE_QUIET;\n\tif (sysfs_streq(buf, "balanced"))\n\t\treturn ASUS_EC_PROFILE_BALANCED;\n\tif (sysfs_streq(buf, "performance"))\n\t\treturn ASUS_EC_PROFILE_PERFORMANCE;\n\tif (sysfs_streq(buf, "full-speed"))\n\t\treturn ASUS_EC_PROFILE_FULL_SPEED;\n\treturn -EINVAL;\n}\n''',
    '''static int asus_ec_profile_parse(const char *buf)\n{\n\tif (sysfs_streq(buf, "quiet"))\n\t\treturn ASUS_EC_PROFILE_QUIET;\n\tif (sysfs_streq(buf, "normal") || sysfs_streq(buf, "balanced"))\n\t\treturn ASUS_EC_PROFILE_BALANCED;\n\tif (sysfs_streq(buf, "turbo") || sysfs_streq(buf, "performance"))\n\t\treturn ASUS_EC_PROFILE_PERFORMANCE;\n\tif (sysfs_streq(buf, "full-speed"))\n\t\treturn ASUS_EC_PROFILE_FULL_SPEED;\n\treturn -EINVAL;\n}\n''',
    "native profile parser with Linux compatibility aliases",
)

once(
    'return sysfs_emit(buf, "quiet balanced performance full-speed\\n");',
    'return sysfs_emit(buf, "quiet normal turbo full-speed\\n");',
    "native profile ordering",
)

anchor = '''static ssize_t profile_choices_show(struct device *dev,\n'''
cycle = '''/* Fn+F entry point used by hid_asus_ec. The HID interrupt handler schedules\n * this from process context, so firmware mailbox transactions may sleep. */\nint asus_a14_cycle_native_profile(void)\n{\n\tstruct asus_ec *ec;\n\tenum asus_ec_profile next;\n\tint ret;\n\n\tif (!asus_ec_pdev)\n\t\treturn -ENODEV;\n\tec = platform_get_drvdata(asus_ec_pdev);\n\tif (!ec)\n\t\treturn -ENODEV;\n\n\tmutex_lock(&ec->mode_lock);\n\tswitch (ec->active_profile) {\n\tcase ASUS_EC_PROFILE_QUIET:\n\t\tnext = ASUS_EC_PROFILE_BALANCED;\n\t\tbreak;\n\tcase ASUS_EC_PROFILE_BALANCED:\n\t\tnext = ASUS_EC_PROFILE_PERFORMANCE;\n\t\tbreak;\n\tcase ASUS_EC_PROFILE_PERFORMANCE:\n\t\tnext = ASUS_EC_PROFILE_FULL_SPEED;\n\t\tbreak;\n\tcase ASUS_EC_PROFILE_FULL_SPEED:\n\tdefault:\n\t\tnext = ASUS_EC_PROFILE_QUIET;\n\t\tbreak;\n\t}\n\n\tret = asus_ec_apply_profile_locked(ec, next);\n\tmutex_unlock(&ec->mode_lock);\n\tif (!ret) {\n\t\tsysfs_notify(&ec->dev->kobj, NULL, "profile");\n\t\tasus_ec_notify_profile(ec);\n\t}\n\treturn ret;\n}\nEXPORT_SYMBOL_GPL(asus_a14_cycle_native_profile);\n\n'''
if s.count(anchor) != 1:
    raise SystemExit(f"Fn+F cycle insertion anchor: expected one, found {s.count(anchor)}")
s = s.replace(anchor, cycle + anchor, 1)

required = (
    MARKER,
    'return "normal";',
    'return "turbo";',
    'quiet normal turbo full-speed',
    'sysfs_streq(buf, "balanced")',
    'sysfs_streq(buf, "performance")',
    'int asus_a14_cycle_native_profile(void)',
    'EXPORT_SYMBOL_GPL(asus_a14_cycle_native_profile)',
    'next = ASUS_EC_PROFILE_BALANCED;',
    'next = ASUS_EC_PROFILE_PERFORMANCE;',
    'next = ASUS_EC_PROFILE_FULL_SPEED;',
    'next = ASUS_EC_PROFILE_QUIET;',
)
missing = [token for token in required if token not in s]
if missing:
    raise SystemExit("native mode names/hotkey transform incomplete: " + ", ".join(missing))

p.write_text(s)
print("a14_native_mode_names_hotkey=applied")
