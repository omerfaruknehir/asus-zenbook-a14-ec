#!/usr/bin/env python3
from pathlib import Path

p = Path("asus_zenbook_a14_ec.c")
s = p.read_text()


def once(old: str, new: str, label: str, accepted=()) -> None:
    global s
    if new in s or any(variant in s for variant in accepted):
        return
    count = s.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one source anchor, found {count}")
    s = s.replace(old, new, 1)


once(
    "#define EC_XFER_RETRIES                 3\n",
    "#define EC_XFER_RETRIES                 3\n"
    "#define EC_QUIESCE_RETRIES              3\n"
    "#define EC_QUIESCE_RETRY_MS             40\n",
    "quiesce constants",
)

once(
    '''static void asus_ec_mailbox_quiesce(struct asus_ec *ec)\n{\n\tmutex_lock(&ec->ec_lock);\n\t(void)__ec_wb(ec, 0xc4, EC_CC_DATA, 0);\n\t(void)__ec_wb(ec, 0xc4, EC_CC_BUSY, 0);\n\tmutex_unlock(&ec->ec_lock);\n}\n''',
    '''static int asus_ec_mailbox_quiesce(struct asus_ec *ec)\n{\n\tint attempt;\n\tint ret = -EIO;\n\n\tmutex_lock(&ec->ec_lock);\n\tfor (attempt = 0; attempt < EC_QUIESCE_RETRIES; attempt++) {\n\t\tret = __ec_wb(ec, 0xc4, EC_CC_DATA, 0);\n\t\tif (!ret)\n\t\t\tret = __ec_wb(ec, 0xc4, EC_CC_BUSY, 0);\n\t\tif (!ret)\n\t\t\tbreak;\n\t\tif (attempt + 1 < EC_QUIESCE_RETRIES)\n\t\t\tmsleep(EC_QUIESCE_RETRY_MS);\n\t}\n\tmutex_unlock(&ec->ec_lock);\n\n\treturn ret;\n}\n''',
    "mailbox quiesce",
)

anchor = '''static int asus_ec_leave_manual_locked(struct asus_ec *ec)\n'''
helper = '''static int asus_ec_force_auto_locked(struct asus_ec *ec)\n{\n\tu8 mode = 0xff;\n\tint attempt;\n\tint ret = -EIO;\n\n\tfor (attempt = 0; attempt < EC_XFER_RETRIES; attempt++) {\n\t\tret = asus_ec_set_fan_mode(ec, EC_FAN_MODE_AUTO);\n\t\tif (!ret)\n\t\t\tret = asus_ec_read_reg(ec, EC_REG_FAN_MODE_MAJ,\n\t\t\t\t\t       EC_REG_FAN_MODE_RMIN, &mode);\n\t\tif (!ret && mode == EC_FAN_MODE_AUTO) {\n\t\t\tec->manual_active = false;\n\t\t\treturn 0;\n\t\t}\n\t\tif (!ret)\n\t\t\tret = -EIO;\n\t\tif (attempt + 1 < EC_XFER_RETRIES)\n\t\t\tmsleep(EC_QUIESCE_RETRY_MS);\n\t}\n\n\treturn ret;\n}\n\n'''
if helper not in s:
    if s.count(anchor) != 1:
        raise SystemExit(f"force-auto helper: expected one source anchor, found {s.count(anchor)}")
    s = s.replace(anchor, helper + anchor, 1)

once(
    '''static int asus_ec_leave_manual_locked(struct asus_ec *ec)\n{\n\tint ret;\n\n\tif (!ec->manual_active)\n\t\treturn 0;\n\tret = asus_ec_set_fan_mode(ec, EC_FAN_MODE_AUTO);\n\tif (!ret)\n\t\tec->manual_active = false;\n\treturn ret;\n}\n''',
    '''static int asus_ec_leave_manual_locked(struct asus_ec *ec)\n{\n\tif (!ec->manual_active)\n\t\treturn 0;\n\n\treturn asus_ec_force_auto_locked(ec);\n}\n''',
    "leave manual",
)

once(
    '''\tret = asus_ec_set_pwm_both(ec, pwm);\n\tif (ret) {\n\t\t(void)asus_ec_set_fan_mode(ec, EC_FAN_MODE_AUTO);\n\t\tec->manual_active = false;\n\t}\n\treturn ret;\n}\n''',
    '''\tret = asus_ec_set_pwm_both(ec, pwm);\n\tif (ret) {\n\t\tint restore_ret = asus_ec_force_auto_locked(ec);\n\n\t\tif (restore_ret) {\n\t\t\tdev_err(ec->dev,\n\t\t\t\t"manual fan setup failed and automatic restore failed: %d\\n",\n\t\t\t\trestore_ret);\n\t\t\tif (!ec->shutting_down)\n\t\t\t\tmod_delayed_work(system_freezable_wq, &ec->safety_work,\n\t\t\t\t\t\t msecs_to_jiffies(500));\n\t\t}\n\t}\n\treturn ret;\n}\n''',
    "manual entry rollback",
)

native_safety_fallback = '''\t\tret = asus_ec_force_auto_locked(ec);\n\t\tif (!ret)\n\t\t\tret = asus_ec_set_native_fan_profile(ec, EC_FW_FAN_PROFILE_NORMAL);\n\t\tif (!ret) {\n\t\t\tec->active_profile = ASUS_EC_PROFILE_BALANCED;\n\t\t\tasus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);\n\t\t\tsysfs_notify(&ec->dev->kobj, NULL, "profile");\n\t\t\tasus_ec_notify_profile(ec);\n\t\t\tgoto out;\n\t\t}\n\t\tec->active_profile = ASUS_EC_PROFILE_CUSTOM;\n'''

once(
    '''\tif (fallback) {\n\t\tdev_warn(ec->dev,\n\t\t\t "manual fan mode safety fallback (temp=%d, read failures=%u)\\n",\n\t\t\t temp, ec->temp_failures);\n\t\tif (!asus_ec_leave_manual_locked(ec)) {\n\t\t\tec->active_profile = ASUS_EC_PROFILE_BALANCED;\n\t\t\tasus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);\n\t\t\tsysfs_notify(&ec->dev->kobj, NULL, "profile");\n\t\t\tasus_ec_notify_profile(ec);\n\t\t}\n\t\tgoto out;\n\t}\n''',
    '''\tif (fallback) {\n\t\tint ret;\n\n\t\tdev_warn(ec->dev,\n\t\t\t "manual fan mode safety fallback (temp=%d, read failures=%u)\\n",\n\t\t\t temp, ec->temp_failures);\n\t\tret = asus_ec_force_auto_locked(ec);\n\t\tif (!ret) {\n\t\t\tec->active_profile = ASUS_EC_PROFILE_BALANCED;\n\t\t\tasus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);\n\t\t\tsysfs_notify(&ec->dev->kobj, NULL, "profile");\n\t\t\tasus_ec_notify_profile(ec);\n\t\t\tgoto out;\n\t\t}\n\n\t\tdev_err(ec->dev,\n\t\t\t"failed to restore automatic fan mode during safety fallback: %d\\n",\n\t\t\tret);\n\t\tif (!ec->shutting_down)\n\t\t\tmod_delayed_work(system_freezable_wq, &ec->safety_work,\n\t\t\t\t\t msecs_to_jiffies(500));\n\t\tgoto out;\n\t}\n''',
    "safety fallback retry",
    accepted=(native_safety_fallback,),
)

native_hwmon_auto = '''\t\telse if (value == 2)\n\t\t\tret = asus_ec_apply_profile_locked(ec, ASUS_EC_PROFILE_BALANCED);\n'''

once(
    '''\t\telse if (value == 2)\n\t\t\tret = asus_ec_leave_manual_locked(ec);\n''',
    '''\t\telse if (value == 2)\n\t\t\tret = asus_ec_force_auto_locked(ec);\n''',
    "hwmon force auto",
    accepted=(native_hwmon_auto,),
)

once(
    '''\tif (!ret && ec->manual_active)\n\t\tmod_delayed_work(system_freezable_wq, &ec->safety_work,\n\t\t\t\t msecs_to_jiffies(PROFILE_SAFETY_PERIOD_MS));\n\tmutex_unlock(&ec->mode_lock);\n\treturn ret;\n}\n''',
    '''\tif (!ret && ec->manual_active)\n\t\tmod_delayed_work(system_freezable_wq, &ec->safety_work,\n\t\t\t\t msecs_to_jiffies(PROFILE_SAFETY_PERIOD_MS));\n\tmutex_unlock(&ec->mode_lock);\n\n\tif (!ret && (attr == hwmon_pwm_enable || attr == hwmon_pwm_input)) {\n\t\tsysfs_notify(&ec->dev->kobj, NULL, "profile");\n\t\tasus_ec_notify_profile(ec);\n\t}\n\treturn ret;\n}\n''',
    "hwmon profile notification",
)

once(
    '''static void asus_ec_quiesce(struct asus_ec *ec)\n{\n\tcancel_delayed_work_sync(&ec->safety_work);\n\tmutex_lock(&ec->mode_lock);\n\tec->shutting_down = true;\n\t(void)asus_ec_set_fan_mode(ec, EC_FAN_MODE_AUTO);\n\tec->manual_active = false;\n\tasus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);\n\tmutex_unlock(&ec->mode_lock);\n\tasus_ec_mailbox_quiesce(ec);\n}\n''',
    '''static void asus_ec_quiesce(struct asus_ec *ec)\n{\n\tint ret;\n\n\tcancel_delayed_work_sync(&ec->safety_work);\n\tmutex_lock(&ec->mode_lock);\n\tec->shutting_down = true;\n\tret = asus_ec_force_auto_locked(ec);\n\tif (ret)\n\t\tdev_err(ec->dev,\n\t\t\t"failed to verify automatic fan mode while quiescing: %d\\n", ret);\n\tasus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);\n\tmutex_unlock(&ec->mode_lock);\n\n\tret = asus_ec_mailbox_quiesce(ec);\n\tif (ret)\n\t\tdev_err(ec->dev, "failed to quiesce EC mailbox: %d\\n", ret);\n}\n''',
    "shutdown quiesce",
)

once(
    '''\tif (mode == EC_FAN_MODE_MANUAL) {\n\t\tdev_warn(dev, "EC was left in manual mode; restoring automatic control\\n");\n\t\tret = asus_ec_set_fan_mode(ec, EC_FAN_MODE_AUTO);\n\t\tif (ret)\n\t\t\tgoto err_client;\n\t}\n''',
    '''\tif (mode == EC_FAN_MODE_MANUAL) {\n\t\tdev_warn(dev, "EC was left in manual mode; restoring automatic control\\n");\n\t\tmutex_lock(&ec->mode_lock);\n\t\tec->manual_active = true;\n\t\tret = asus_ec_force_auto_locked(ec);\n\t\tmutex_unlock(&ec->mode_lock);\n\t\tif (ret)\n\t\t\tgoto err_client;\n\t}\n''',
    "probe recovery",
)

once(
    '''static int asus_ec_suspend(struct device *dev)\n{\n\tstruct asus_ec *ec = dev_get_drvdata(dev);\n\n\tcancel_delayed_work_sync(&ec->safety_work);\n\tmutex_lock(&ec->mode_lock);\n\t(void)asus_ec_leave_manual_locked(ec);\n\tmutex_unlock(&ec->mode_lock);\n\tasus_ec_mailbox_quiesce(ec);\n\treturn 0;\n}\n''',
    '''static int asus_ec_suspend(struct device *dev)\n{\n\tstruct asus_ec *ec = dev_get_drvdata(dev);\n\tenum asus_ec_profile profile = ec->active_profile;\n\tint ret;\n\n\tcancel_delayed_work_sync(&ec->safety_work);\n\tmutex_lock(&ec->mode_lock);\n\tret = asus_ec_leave_manual_locked(ec);\n\tif (ret && ec->manual_active)\n\t\tmod_delayed_work(system_freezable_wq, &ec->safety_work,\n\t\t\t\t msecs_to_jiffies(500));\n\tmutex_unlock(&ec->mode_lock);\n\tif (ret) {\n\t\tdev_err(ec->dev,\n\t\t\t"refusing suspend: automatic fan mode restore failed: %d\\n", ret);\n\t\treturn ret;\n\t}\n\n\tret = asus_ec_mailbox_quiesce(ec);\n\tif (ret) {\n\t\tint restore_ret = 0;\n\n\t\tdev_err(ec->dev, "refusing suspend: EC mailbox quiesce failed: %d\\n", ret);\n\t\tmutex_lock(&ec->mode_lock);\n\t\tif (profile == ASUS_EC_PROFILE_PERFORMANCE)\n\t\t\trestore_ret = asus_ec_apply_profile_locked(ec, profile);\n\t\telse if (profile == ASUS_EC_PROFILE_CUSTOM) {\n\t\t\tec->active_profile = ASUS_EC_PROFILE_BALANCED;\n\t\t\tasus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);\n\t\t\tsysfs_notify(&ec->dev->kobj, NULL, "profile");\n\t\t\tasus_ec_notify_profile(ec);\n\t\t}\n\t\tmutex_unlock(&ec->mode_lock);\n\t\tif (restore_ret)\n\t\t\tdev_err(ec->dev,\n\t\t\t\t"failed to restore pre-suspend performance profile: %d\\n",\n\t\t\t\trestore_ret);\n\t\treturn ret;\n\t}\n\n\treturn 0;\n}\n''',
    "suspend fail closed",
)

p.write_text(s)
print("a14_ec_hardening=applied")
