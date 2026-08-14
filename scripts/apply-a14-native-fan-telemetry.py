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


once(
    '#define EC_REG_TEMP_MAJ                 0x05\n#define EC_REG_TEMP_MIN                 0x02\n',
    '#define EC_REG_TEMP_MAJ                 0x05\n#define EC_REG_TEMP_MIN                 0x02\n\n'
    '/* A14 DSDT SFAN(0): FAN1._FST speed = (c6:19 << 8) | c6:18. */\n'
    '#define EC_NATIVE_FAN_MAJ               0xc6\n'
    '#define EC_NATIVE_FAN1_RPM_LO           0x18\n'
    '#define EC_NATIVE_FAN1_RPM_HI           0x19\n',
    'native fan telemetry constants',
)

anchor = '''static int asus_ec_read_fan_reg(struct asus_ec *ec, unsigned int fan,\n'''
helper = '''static int asus_ec_read_native_fan1_rpm(struct asus_ec *ec, long *rpm)\n{\n\tu8 low, high;\n\tint ret;\n\n\tmutex_lock(&ec->ec_lock);\n\tret = __ec_rb(ec, EC_NATIVE_FAN_MAJ, EC_NATIVE_FAN1_RPM_LO, &low);\n\tif (!ret)\n\t\tret = __ec_rb(ec, EC_NATIVE_FAN_MAJ, EC_NATIVE_FAN1_RPM_HI, &high);\n\tmutex_unlock(&ec->ec_lock);\n\n\tif (!ret)\n\t\t*rpm = ((u16)high << 8) | low;\n\treturn ret;\n}\n\n'''
if helper not in s:
    if s.count(anchor) != 1:
        raise SystemExit(f'native FAN1 helper: expected one source anchor, found {s.count(anchor)}')
    s = s.replace(anchor, helper + anchor, 1)

once(
'''\tcase hwmon_fan:\n\t\tif (attr != hwmon_fan_input || channel >= EC_NUM_FANS)\n\t\t\treturn -EOPNOTSUPP;\n\t\tret = asus_ec_read_fan_reg(ec, channel, EC_REG_FAN_TACH_MIN, &raw);\n\t\tif (!ret)\n\t\t\t*value = (long)raw * EC_TACH_RPM_MULT;\n\t\treturn ret;\n''',
'''\tcase hwmon_fan:\n\t\tif (attr != hwmon_fan_input || channel >= EC_NUM_FANS)\n\t\t\treturn -EOPNOTSUPP;\n\n\t\tif (channel == 0) {\n\t\t\tret = asus_ec_read_native_fan1_rpm(ec, value);\n\t\t\tif (!ret)\n\t\t\t\treturn 0;\n\t\t\tdev_dbg_ratelimited(ec->dev,\n\t\t\t\t"native FAN1 telemetry unavailable (%d); using selector fallback\\n",\n\t\t\t\tret);\n\t\t}\n\n\t\t/* FAN2 has no proven direct DSDT RPM register; keep the validated\n\t\t * selector path for it, and as a compatibility fallback for FAN1. */\n\t\tret = asus_ec_read_fan_reg(ec, channel, EC_REG_FAN_TACH_MIN, &raw);\n\t\tif (!ret)\n\t\t\t*value = (long)raw * EC_TACH_RPM_MULT;\n\t\treturn ret;\n''',
    'native FAN1 hwmon read',
)

p.write_text(s)
print('a14_native_fan_telemetry=applied')
