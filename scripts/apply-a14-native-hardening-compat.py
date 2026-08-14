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


# The A14 has two distinct controls:
#   1. the low-level EC fan controller AUTO/MANUAL bit, and
#   2. the native 0x00110019 firmware thermal/fan profile mailbox.
#
# Earlier composition coupled AUTO to the native Normal marker.  The recovered
# DSDT does not do that: DEVS(0x00110019, mode) explicitly invokes WEBC(0x11)
# as a separate policy operation.  Keep those paths independent so shutdown,
# suspend, and rollback can return PWM ownership to firmware without silently
# changing the selected native thermal policy.
once(
'''static int asus_ec_set_fan_mode(struct asus_ec *ec, u8 mode)\n{\n\tint ret;\n\n\tret = asus_ec_write_reg(ec, EC_REG_FAN_MODE_MAJ,\n\t\t\t\tEC_REG_FAN_MODE_WMIN, mode);\n\tif (!ret && mode == EC_FAN_MODE_AUTO)\n\t\tret = asus_ec_set_native_fan_profile(ec, EC_FW_FAN_PROFILE_NORMAL);\n\treturn ret;\n}\n''',
'''static int asus_ec_set_fan_mode(struct asus_ec *ec, u8 mode)\n{\n\treturn asus_ec_write_reg(ec, EC_REG_FAN_MODE_MAJ,\n\t\t\t\t EC_REG_FAN_MODE_WMIN, mode);\n}\n''',
    'separate low-level AUTO from native policy',
)

# Safety fallback is a policy decision: leave manual PWM, then explicitly
# establish native Normal/Standard.  This also repairs trees composed with the
# older compatibility transform.
once(
'''\t\tret = asus_ec_force_auto_locked(ec);\n\t\tif (!ret) {\n\t\t\tec->active_profile = ASUS_EC_PROFILE_BALANCED;\n\t\t\tasus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);\n\t\t\tsysfs_notify(&ec->dev->kobj, NULL, "profile");\n\t\t\tasus_ec_notify_profile(ec);\n\t\t\tgoto out;\n\t\t}\n''',
'''\t\tret = asus_ec_force_auto_locked(ec);\n\t\tif (!ret)\n\t\t\tret = asus_ec_set_native_fan_profile(ec, EC_FW_FAN_PROFILE_NORMAL);\n\t\tif (!ret) {\n\t\t\tec->active_profile = ASUS_EC_PROFILE_BALANCED;\n\t\t\tasus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);\n\t\t\tsysfs_notify(&ec->dev->kobj, NULL, "profile");\n\t\t\tasus_ec_notify_profile(ec);\n\t\t\tgoto out;\n\t\t}\n\t\tec->active_profile = ASUS_EC_PROFILE_CUSTOM;\n''',
    'explicit native normal safety fallback',
)

# pwm_enable=2 means "return to firmware automatic policy", not merely clear
# the manual PWM bit.  Reuse the normal profile path so state reporting and the
# native 0x00110019 command stay synchronized.
once(
'''\t\telse if (value == 2)\n\t\t\tret = asus_ec_force_auto_locked(ec);\n''',
'''\t\telse if (value == 2)\n\t\t\tret = asus_ec_apply_profile_locked(ec, ASUS_EC_PROFILE_BALANCED);\n''',
    'hwmon auto restores native normal profile',
)

p.write_text(s)
print('a14_native_hardening_compat=applied')
