#!/usr/bin/env python3
from pathlib import Path

p = Path('asus_zenbook_a14_ec.c')
s = p.read_text()


def once(old: str, new: str, label: str) -> None:
    global s
    if new in s:
        return
    count = s.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected one source anchor, found {count}')
    s = s.replace(old, new, 1)


# Returning the low-level fan controller to AUTO also restores the firmware's
# Normal/Standard profile.  Native profile changes then immediately replace
# that marker with Quiet/Turbo/Full-speed as required.  Keeping this policy in
# the common AUTO transition lets the hardening transform retain its original
# fail-safe blocks unchanged and therefore remain idempotent.
once(
'''static int asus_ec_set_fan_mode(struct asus_ec *ec, u8 mode)\n{\n\treturn asus_ec_write_reg(ec, EC_REG_FAN_MODE_MAJ,\n\t\t\t\t EC_REG_FAN_MODE_WMIN, mode);\n}\n''',
'''static int asus_ec_set_fan_mode(struct asus_ec *ec, u8 mode)\n{\n\tint ret;\n\n\tret = asus_ec_write_reg(ec, EC_REG_FAN_MODE_MAJ,\n\t\t\t\tEC_REG_FAN_MODE_WMIN, mode);\n\tif (!ret && mode == EC_FAN_MODE_AUTO)\n\t\tret = asus_ec_set_native_fan_profile(ec, EC_FW_FAN_PROFILE_NORMAL);\n\treturn ret;\n}\n''',
    'native normal on auto transition',
)

once(
'''\t\tret = asus_ec_force_auto_locked(ec);\n\t\tif (!ret)\n\t\t\tret = asus_ec_set_native_fan_profile(ec, EC_FW_FAN_PROFILE_NORMAL);\n\t\tif (!ret) {\n\t\t\tec->active_profile = ASUS_EC_PROFILE_BALANCED;\n\t\t\tasus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);\n\t\t\tsysfs_notify(&ec->dev->kobj, NULL, "profile");\n\t\t\tasus_ec_notify_profile(ec);\n\t\t\tgoto out;\n\t\t}\n\t\tec->active_profile = ASUS_EC_PROFILE_CUSTOM;\n''',
'''\t\tret = asus_ec_force_auto_locked(ec);\n\t\tif (!ret) {\n\t\t\tec->active_profile = ASUS_EC_PROFILE_BALANCED;\n\t\t\tasus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);\n\t\t\tsysfs_notify(&ec->dev->kobj, NULL, "profile");\n\t\t\tasus_ec_notify_profile(ec);\n\t\t\tgoto out;\n\t\t}\n''',
    'hardening-compatible safety fallback',
)

once(
'''\t\telse if (value == 2)\n\t\t\tret = asus_ec_apply_profile_locked(ec, ASUS_EC_PROFILE_BALANCED);\n''',
'''\t\telse if (value == 2)\n\t\t\tret = asus_ec_force_auto_locked(ec);\n''',
    'hardening-compatible hwmon auto',
)

p.write_text(s)
print('a14_native_hardening_compat=applied')
