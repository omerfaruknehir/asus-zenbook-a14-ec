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
    '#define EC_REG_FAN_MODE_MAJ             0x01\n',
    '/* A14 DSDT I2C6.WEBC firmware mailbox (major 0xc9). */\n'
    '#define EC_FW_MAJ                       0xc9\n'
    '#define EC_FW_DATA_BASE                 0x40\n'
    '#define EC_FW_COMMAND                   0x6e\n'
    '#define EC_FW_STATUS                    0x6f\n'
    '#define EC_FW_STATUS_TIMEOUT             BIT(6)\n'
    '#define EC_FW_STATUS_START               BIT(7)\n'
    '#define EC_FW_WAIT_ATTEMPTS              200\n'
    '/* DSDT WEBC uses Sleep(100): 100 ms per busy poll, not 100 us. */\n'
    '#define EC_FW_WAIT_MIN_US                100000\n'
    '#define EC_FW_WAIT_MAX_US                110000\n'
    '#define EC_FW_FAN_PROFILE_COMMAND        0x11\n'
    '#define EC_FW_FAN_PROFILE_NORMAL         0x01\n'
    '#define EC_FW_FAN_PROFILE_QUIET          0x02\n'
    '#define EC_FW_FAN_PROFILE_TURBO          0x04\n'
    '#define EC_FW_FAN_PROFILE_FULL_SPEED     0x10\n\n'
    '#define EC_REG_FAN_MODE_MAJ             0x01\n',
    'native firmware mailbox constants',
)

once(
    '\tASUS_EC_PROFILE_PERFORMANCE,\n\tASUS_EC_PROFILE_CUSTOM,\n',
    '\tASUS_EC_PROFILE_PERFORMANCE,\n\tASUS_EC_PROFILE_FULL_SPEED,\n\tASUS_EC_PROFILE_CUSTOM,\n',
    'full-speed profile enum',
)

once(
    'static uint quiet_max_khz = 1440000;\n'
    'module_param(quiet_max_khz, uint, 0644);\n'
    'MODULE_PARM_DESC(quiet_max_khz, "Maximum CPU frequency used by quiet profile");\n',
    '/* Native A14 firmware profiles do not use a synthetic CPU frequency cap. */\n',
    'remove synthetic quiet QoS parameter',
)

once(
    'MODULE_PARM_DESC(performance_pwm, "Fixed dual-fan PWM used by performance profile (75-255)");\n',
    'MODULE_PARM_DESC(performance_pwm, "Default dual-fan PWM used when hwmon manual mode is enabled (75-255)");\n',
    'manual PWM description',
)

anchor = '''/* Caller holds ec_lock. */\nstatic int __ec_settle(struct asus_ec *ec)\n'''
helper = '''/* Caller holds ec_lock. Mirrors the A14 DSDT I2C6.WEBC method. */\nstatic int __ec_webc(struct asus_ec *ec, u8 command,\n\t\t\t const u8 *payload, size_t payload_len)\n{\n\tu8 status;\n\tunsigned int attempt;\n\tsize_t i;\n\tint ret;\n\n\tif (!payload || !payload_len ||\n\t    payload_len > EC_FW_COMMAND - EC_FW_DATA_BASE)\n\t\treturn -EINVAL;\n\n\tfor (attempt = 0; attempt < EC_FW_WAIT_ATTEMPTS; attempt++) {\n\t\tret = __ec_rb(ec, EC_FW_MAJ, EC_FW_STATUS, &status);\n\t\tif (ret)\n\t\t\treturn ret;\n\t\tif (!status)\n\t\t\tbreak;\n\t\tusleep_range(EC_FW_WAIT_MIN_US, EC_FW_WAIT_MAX_US);\n\t}\n\n\tif (status) {\n\t\t/* Firmware's WEBC timeout path latches bit 6 in the status byte. */\n\t\tret = __ec_rb(ec, EC_FW_MAJ, EC_FW_STATUS, &status);\n\t\tif (ret)\n\t\t\treturn ret;\n\t\tret = __ec_wb(ec, EC_FW_MAJ, EC_FW_STATUS,\n\t\t\t      status | EC_FW_STATUS_TIMEOUT);\n\t\treturn ret ? ret : -ETIMEDOUT;\n\t}\n\n\tfor (i = 0; i < payload_len; i++) {\n\t\tret = __ec_wb(ec, EC_FW_MAJ, EC_FW_DATA_BASE + i, payload[i]);\n\t\tif (ret)\n\t\t\treturn ret;\n\t}\n\n\tret = __ec_wb(ec, EC_FW_MAJ, EC_FW_STATUS,\n\t\t      status | EC_FW_STATUS_START);\n\tif (ret)\n\t\treturn ret;\n\n\treturn __ec_wb(ec, EC_FW_MAJ, EC_FW_COMMAND, command);\n}\n\n'''
if helper not in s:
    if s.count(anchor) != 1:
        raise SystemExit(f'native WEBC helper: expected one source anchor, found {s.count(anchor)}')
    s = s.replace(anchor, helper + anchor, 1)

anchor = '''static int asus_ec_set_fan_mode(struct asus_ec *ec, u8 mode)\n'''
helper = '''static int asus_ec_set_native_fan_profile(struct asus_ec *ec, u8 marker)\n{\n\tint ret;\n\n\tmutex_lock(&ec->ec_lock);\n\tret = __ec_webc(ec, EC_FW_FAN_PROFILE_COMMAND, &marker, 1);\n\tmutex_unlock(&ec->ec_lock);\n\treturn ret;\n}\n\nstatic int asus_ec_native_profile_marker(enum asus_ec_profile profile, u8 *marker)\n{\n\tswitch (profile) {\n\tcase ASUS_EC_PROFILE_BALANCED:\n\t\t*marker = EC_FW_FAN_PROFILE_NORMAL;\n\t\treturn 0;\n\tcase ASUS_EC_PROFILE_QUIET:\n\t\t*marker = EC_FW_FAN_PROFILE_QUIET;\n\t\treturn 0;\n\tcase ASUS_EC_PROFILE_PERFORMANCE:\n\t\t*marker = EC_FW_FAN_PROFILE_TURBO;\n\t\treturn 0;\n\tcase ASUS_EC_PROFILE_FULL_SPEED:\n\t\t*marker = EC_FW_FAN_PROFILE_FULL_SPEED;\n\t\treturn 0;\n\tdefault:\n\t\treturn -EOPNOTSUPP;\n\t}\n}\n\n'''
if helper not in s:
    if s.count(anchor) != 1:
        raise SystemExit(f'native profile helper: expected one source anchor, found {s.count(anchor)}')
    s = s.replace(anchor, helper + anchor, 1)

once(
'''static int asus_ec_apply_profile_locked(struct asus_ec *ec,\n\t\t\t\t\tenum asus_ec_profile profile)\n{\n\tint ret;\n\n\tswitch (profile) {\n\tcase ASUS_EC_PROFILE_QUIET:\n\t\tret = asus_ec_leave_manual_locked(ec);\n\t\tif (ret)\n\t\t\treturn ret;\n\t\tasus_ec_freq_qos_set(ec, quiet_max_khz);\n\t\tbreak;\n\tcase ASUS_EC_PROFILE_BALANCED:\n\t\tret = asus_ec_leave_manual_locked(ec);\n\t\tif (ret)\n\t\t\treturn ret;\n\t\tasus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);\n\t\tbreak;\n\tcase ASUS_EC_PROFILE_PERFORMANCE:\n\t\tif (performance_pwm < EC_PWM_SPIN_FLOOR || performance_pwm > 255)\n\t\t\treturn -EINVAL;\n\t\tasus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);\n\t\tret = asus_ec_enter_manual_locked(ec, performance_pwm);\n\t\tif (ret)\n\t\t\treturn ret;\n\t\tbreak;\n\tdefault:\n\t\treturn -EOPNOTSUPP;\n\t}\n\n\tec->active_profile = profile;\n\tec->temp_failures = 0;\n\tif (ec->manual_active && !ec->shutting_down)\n\t\tmod_delayed_work(system_freezable_wq, &ec->safety_work,\n\t\t\t\t msecs_to_jiffies(PROFILE_SAFETY_PERIOD_MS));\n\telse\n\t\tcancel_delayed_work(&ec->safety_work);\n\treturn 0;\n}\n''',
'''static int asus_ec_apply_profile_locked(struct asus_ec *ec,\n\t\t\t\t\tenum asus_ec_profile profile)\n{\n\tu8 marker;\n\tint ret;\n\n\tret = asus_ec_native_profile_marker(profile, &marker);\n\tif (ret)\n\t\treturn ret;\n\n\t/* Native firmware profiles own the fan curve; manual PWM is separate. */\n\tret = asus_ec_force_auto_locked(ec);\n\tif (ret)\n\t\treturn ret;\n\tasus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);\n\n\tret = asus_ec_set_native_fan_profile(ec, marker);\n\tif (ret) {\n\t\tec->active_profile = ASUS_EC_PROFILE_CUSTOM;\n\t\treturn ret;\n\t}\n\n\tec->active_profile = profile;\n\tec->temp_failures = 0;\n\tcancel_delayed_work(&ec->safety_work);\n\treturn 0;\n}\n''',
    'native profile application',
)

once(
    '\t\tret = asus_ec_force_auto_locked(ec);\n'
    '\t\tif (!ret) {\n'
    '\t\t\tec->active_profile = ASUS_EC_PROFILE_BALANCED;\n'
    '\t\t\tasus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);\n'
    '\t\t\tsysfs_notify(&ec->dev->kobj, NULL, "profile");\n'
    '\t\t\tasus_ec_notify_profile(ec);\n'
    '\t\t\tgoto out;\n'
    '\t\t}\n',
    '\t\tret = asus_ec_force_auto_locked(ec);\n'
    '\t\tif (!ret)\n'
    '\t\t\tret = asus_ec_set_native_fan_profile(ec, EC_FW_FAN_PROFILE_NORMAL);\n'
    '\t\tif (!ret) {\n'
    '\t\t\tec->active_profile = ASUS_EC_PROFILE_BALANCED;\n'
    '\t\t\tasus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);\n'
    '\t\t\tsysfs_notify(&ec->dev->kobj, NULL, "profile");\n'
    '\t\t\tasus_ec_notify_profile(ec);\n'
    '\t\t\tgoto out;\n'
    '\t\t}\n'
    '\t\tec->active_profile = ASUS_EC_PROFILE_CUSTOM;\n',
    'manual safety fallback to native normal profile',
)

once(
    '\t\telse if (value == 2)\n\t\t\tret = asus_ec_force_auto_locked(ec);\n',
    '\t\telse if (value == 2)\n\t\t\tret = asus_ec_apply_profile_locked(ec, ASUS_EC_PROFILE_BALANCED);\n',
    'hwmon auto restores native normal profile',
)

once(
    '\tcase ASUS_EC_PROFILE_PERFORMANCE:\n\t\treturn "performance";\n\tdefault:\n',
    '\tcase ASUS_EC_PROFILE_PERFORMANCE:\n\t\treturn "performance";\n'
    '\tcase ASUS_EC_PROFILE_FULL_SPEED:\n\t\treturn "full-speed";\n\tdefault:\n',
    'full-speed profile name',
)

once(
    '\tif (sysfs_streq(buf, "performance"))\n\t\treturn ASUS_EC_PROFILE_PERFORMANCE;\n\treturn -EINVAL;\n',
    '\tif (sysfs_streq(buf, "performance"))\n\t\treturn ASUS_EC_PROFILE_PERFORMANCE;\n'
    '\tif (sysfs_streq(buf, "full-speed"))\n\t\treturn ASUS_EC_PROFILE_FULL_SPEED;\n\treturn -EINVAL;\n',
    'full-speed profile parser',
)

once(
    'return sysfs_emit(buf, "quiet balanced performance\\n");',
    'return sysfs_emit(buf, "quiet balanced performance full-speed\\n");',
    'full-speed profile choices',
)

once(
    '\tcase ASUS_EC_PROFILE_PERFORMANCE:\n\t\t*profile = PLATFORM_PROFILE_PERFORMANCE;\n\t\tbreak;\n\tcase ASUS_EC_PROFILE_CUSTOM:\n',
    '\tcase ASUS_EC_PROFILE_PERFORMANCE:\n'
    '\tcase ASUS_EC_PROFILE_FULL_SPEED:\n'
    '\t\t*profile = PLATFORM_PROFILE_PERFORMANCE;\n'
    '\t\tbreak;\n'
    '\tcase ASUS_EC_PROFILE_CUSTOM:\n',
    'platform_profile full-speed projection',
)

once(
    '\tret = asus_ec_freq_qos_init(ec);\n\tif (ret)\n\t\tgoto err_client;\n\n'
    '\tec->hwmon_dev = devm_hwmon_device_register_with_info(dev, DRV_NAME, ec,\n',
    '\tret = asus_ec_freq_qos_init(ec);\n\tif (ret)\n\t\tgoto err_client;\n\n'
    '\tmutex_lock(&ec->mode_lock);\n'
    '\tret = asus_ec_apply_profile_locked(ec, ASUS_EC_PROFILE_BALANCED);\n'
    '\tmutex_unlock(&ec->mode_lock);\n'
    '\tif (ret) {\n'
    '\t\tdev_err(dev, "failed to establish native balanced fan profile: %d\\n", ret);\n'
    '\t\tgoto err_qos;\n'
    '\t}\n\n'
    '\tec->hwmon_dev = devm_hwmon_device_register_with_info(dev, DRV_NAME, ec,\n',
    'deterministic native profile at probe',
)

p.write_text(s)
print('a14_native_fan_profile=applied')
