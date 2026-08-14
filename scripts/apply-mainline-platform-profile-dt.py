#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: apply-mainline-platform-profile-dt.py /path/to/linux")

root = Path(sys.argv[1])
p = root / "drivers/acpi/platform_profile.c"
if not p.is_file():
    raise SystemExit(f"missing {p}")

s = p.read_text()

helper = '''static bool platform_profile_legacy_sysfs_available(void)\n{\n\treturn !acpi_disabled && acpi_kobj;\n}\n\nstatic void platform_profile_legacy_notify(void)\n{\n\tif (platform_profile_legacy_sysfs_available())\n\t\tsysfs_notify(acpi_kobj, NULL, "platform_profile");\n}\n\n'''

if helper not in s:
    anchor = 'static DEFINE_IDA(platform_profile_ida);\n\n'
    if s.count(anchor) != 1:
        raise SystemExit(f"platform_profile helper anchor count={s.count(anchor)}")

    # The individual platform-profile class devices are not ACPI-specific.
    # Only the legacy aggregate compatibility attributes live under acpi_kobj.
    s = s.replace('sysfs_notify(acpi_kobj, NULL, "platform_profile");',
                  'platform_profile_legacy_notify();')
    s = s.replace(anchor, anchor + helper, 1)

old_register = '''\tplatform_profile_legacy_notify();\n\n\terr = sysfs_update_group(acpi_kobj, &platform_profile_group);\n\tif (err)\n\t\tgoto cleanup_cur;\n\n\treturn ppdev;\n'''
new_register = '''\tplatform_profile_legacy_notify();\n\n\tif (!platform_profile_legacy_sysfs_available())\n\t\treturn ppdev;\n\n\terr = sysfs_update_group(acpi_kobj, &platform_profile_group);\n\tif (err)\n\t\tgoto cleanup_cur;\n\n\treturn ppdev;\n'''
if new_register not in s:
    if s.count(old_register) != 1:
        raise SystemExit(f"register legacy-sysfs anchor count={s.count(old_register)}")
    s = s.replace(old_register, new_register, 1)

old_remove = '''\tplatform_profile_legacy_notify();\n\tsysfs_update_group(acpi_kobj, &platform_profile_group);\n}\n'''
new_remove = '''\tplatform_profile_legacy_notify();\n\tif (platform_profile_legacy_sysfs_available())\n\t\tsysfs_update_group(acpi_kobj, &platform_profile_group);\n}\n'''
if new_remove not in s:
    if s.count(old_remove) != 1:
        raise SystemExit(f"remove legacy-sysfs anchor count={s.count(old_remove)}")
    s = s.replace(old_remove, new_remove, 1)

old_init = '''static int __init platform_profile_init(void)\n{\n\tint err;\n\n\tif (acpi_disabled)\n\t\treturn -EOPNOTSUPP;\n\n\terr = class_register(&platform_profile_class);\n\tif (err)\n\t\treturn err;\n\n\terr = sysfs_create_group(acpi_kobj, &platform_profile_group);\n\tif (err)\n\t\tclass_unregister(&platform_profile_class);\n\n\treturn err;\n}\n'''
new_init = '''static int __init platform_profile_init(void)\n{\n\tint err;\n\n\terr = class_register(&platform_profile_class);\n\tif (err)\n\t\treturn err;\n\n\t/* The class API is useful to DT-backed drivers too.  Only the legacy\n\t * aggregate attributes require the ACPI firmware kobject. */\n\tif (!platform_profile_legacy_sysfs_available())\n\t\treturn 0;\n\n\terr = sysfs_create_group(acpi_kobj, &platform_profile_group);\n\tif (err)\n\t\tclass_unregister(&platform_profile_class);\n\n\treturn err;\n}\n'''
if new_init not in s:
    if s.count(old_init) != 1:
        raise SystemExit(f"platform_profile init anchor count={s.count(old_init)}")
    s = s.replace(old_init, new_init, 1)

old_exit = '''static void __exit platform_profile_exit(void)\n{\n\tsysfs_remove_group(acpi_kobj, &platform_profile_group);\n\tclass_unregister(&platform_profile_class);\n}\n'''
new_exit = '''static void __exit platform_profile_exit(void)\n{\n\tif (platform_profile_legacy_sysfs_available())\n\t\tsysfs_remove_group(acpi_kobj, &platform_profile_group);\n\tclass_unregister(&platform_profile_class);\n}\n'''
if new_exit not in s:
    if s.count(old_exit) != 1:
        raise SystemExit(f"platform_profile exit anchor count={s.count(old_exit)}")
    s = s.replace(old_exit, new_exit, 1)

# Sanity checks: no unguarded legacy notification should remain outside helper,
# and the old DT-rejecting init must be gone.
if 'if (acpi_disabled)\n\t\treturn -EOPNOTSUPP;' in s:
    raise SystemExit('old ACPI-only platform_profile init still present')
if s.count('platform_profile_legacy_sysfs_available()') < 5:
    raise SystemExit('expected DT/legacy guards are incomplete')

p.write_text(s)
print('a14_platform_profile_dt=applied')
