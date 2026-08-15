#!/usr/bin/env python3
from pathlib import Path

p = Path('asus_zenbook_a14_ec.c')
s = p.read_text()

# A previous experiment treated DSDT c6:18/c6:19 as a literal FAN1 RPM value.
# That reading was never calibrated against the physical fan and produced
# implausible ~4k RPM values at the selector path's minimum PWM.  Keep both
# channels on the already hardware-validated selector/tach interface instead:
#   select fan with (0x01, 0x8c), read tach (0x01, 0x09), raw * 88 RPM.
legacy_constants = '''/* A14 DSDT SFAN(0): FAN1._FST speed = (c6:19 << 8) | c6:18. */
#define EC_NATIVE_FAN_MAJ               0xc6
#define EC_NATIVE_FAN1_RPM_LO           0x18
#define EC_NATIVE_FAN1_RPM_HI           0x19
'''
s = s.replace('\n' + legacy_constants, '')
s = s.replace(legacy_constants, '')

legacy_helper = '''static int asus_ec_read_native_fan1_rpm(struct asus_ec *ec, long *rpm)
{
\tu8 low, high;
\tint ret;

\tmutex_lock(&ec->ec_lock);
\tret = __ec_rb(ec, EC_NATIVE_FAN_MAJ, EC_NATIVE_FAN1_RPM_LO, &low);
\tif (!ret)
\t\tret = __ec_rb(ec, EC_NATIVE_FAN_MAJ, EC_NATIVE_FAN1_RPM_HI, &high);
\tmutex_unlock(&ec->ec_lock);

\tif (!ret)
\t\t*rpm = ((u16)high << 8) | low;
\treturn ret;
}

'''
s = s.replace(legacy_helper, '')

legacy_read = '''\tcase hwmon_fan:
\t\tif (attr != hwmon_fan_input || channel >= EC_NUM_FANS)
\t\t\treturn -EOPNOTSUPP;

\t\tif (channel == 0) {
\t\t\tret = asus_ec_read_native_fan1_rpm(ec, value);
\t\t\tif (!ret)
\t\t\t\treturn 0;
\t\t\tdev_dbg_ratelimited(ec->dev,
\t\t\t\t"native FAN1 telemetry unavailable (%d); using selector fallback\\n",
\t\t\t\tret);
\t\t}

\t\t/* FAN2 has no proven direct DSDT RPM register; keep the validated
\t\t * selector path for it, and as a compatibility fallback for FAN1. */
\t\tret = asus_ec_read_fan_reg(ec, channel, EC_REG_FAN_TACH_MIN, &raw);
\t\tif (!ret)
\t\t\t*value = (long)raw * EC_TACH_RPM_MULT;
\t\treturn ret;
'''
selector_read = '''\tcase hwmon_fan:
\t\tif (attr != hwmon_fan_input || channel >= EC_NUM_FANS)
\t\t\treturn -EOPNOTSUPP;
\t\tret = asus_ec_read_fan_reg(ec, channel, EC_REG_FAN_TACH_MIN, &raw);
\t\tif (!ret)
\t\t\t*value = (long)raw * EC_TACH_RPM_MULT;
\t\treturn ret;
'''
if legacy_read in s:
    s = s.replace(legacy_read, selector_read, 1)
elif selector_read not in s:
    raise SystemExit('validated selector fan telemetry anchor missing')

for forbidden in ('EC_NATIVE_FAN_MAJ', 'EC_NATIVE_FAN1_RPM_LO',
                  'EC_NATIVE_FAN1_RPM_HI', 'asus_ec_read_native_fan1_rpm'):
    if forbidden in s:
        raise SystemExit(f'unvalidated direct FAN1 telemetry still present: {forbidden}')

p.write_text(s)
print('a14_native_fan_telemetry=selector-calibrated')
