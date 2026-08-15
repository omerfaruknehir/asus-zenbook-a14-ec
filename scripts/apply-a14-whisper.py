#!/usr/bin/env python3
from pathlib import Path
import re

p = Path("asus_zenbook_a14_ec.c")
s = p.read_text()

if "A14_WHISPER_MODE" in s:
    print("a14_whisper=current")
    raise SystemExit(0)
if "A14_NATIVE_MODE_NAMES_HOTKEY" not in s:
    raise SystemExit("Whisper requires native ASUS mode layer first")

# Add Whisper below native Quiet in the private A14 profile enum.
s, n = re.subn(r"enum asus_ec_profile \{\n\tASUS_EC_PROFILE_QUIET,",
               "enum asus_ec_profile {\n\tASUS_EC_PROFILE_WHISPER,\n\tASUS_EC_PROFILE_QUIET,", s, count=1)
if n != 1:
    raise SystemExit("whisper enum anchor missing")

# Acoustic policy knobs. Native ASUS modes ignore all of these.
anchor = 'static uint performance_pwm = 220;\n'
params = '''#define A14_WHISPER_MODE 1\n\nstatic uint whisper_cpu_cool_percent = 60;\nmodule_param(whisper_cpu_cool_percent, uint, 0644);\nstatic uint whisper_cpu_warm_percent = 45;\nmodule_param(whisper_cpu_warm_percent, uint, 0644);\nstatic uint whisper_cpu_hot_percent = 30;\nmodule_param(whisper_cpu_hot_percent, uint, 0644);\nstatic uint whisper_warm_mc = 50000;\nmodule_param(whisper_warm_mc, uint, 0644);\nstatic uint whisper_hot_mc = 60000;\nmodule_param(whisper_hot_mc, uint, 0644);\nstatic uint whisper_fan_mc = 68000;\nmodule_param(whisper_fan_mc, uint, 0644);\nstatic uint whisper_recover_mc = 55000;\nmodule_param(whisper_recover_mc, uint, 0644);\nstatic uint whisper_period_ms = 1000;\nmodule_param(whisper_period_ms, uint, 0644);\n\n'''
if s.count(anchor) != 1:
    raise SystemExit("whisper param anchor missing")
s = s.replace(anchor, params + anchor, 1)

# State and per-policy native CPU maxima for percentage caps.
s = s.replace('\tstruct delayed_work safety_work;\n',
              '\tstruct delayed_work safety_work;\n\tstruct delayed_work whisper_work;\n\tbool whisper_fanless;\n\tunsigned int whisper_level;\n', 1)
s = s.replace('\tstruct freq_qos_request *freq_requests;\n\tunsigned int num_freq_requests;\n',
              '\tstruct freq_qos_request *freq_requests;\n\tu32 *freq_max_khz;\n\tunsigned int num_freq_requests;\n', 1)

old = '''\tec->freq_requests = devm_kcalloc(ec->dev, capacity,\n\t\t\t\t\t sizeof(*ec->freq_requests), GFP_KERNEL);\n\tif (!ec->freq_requests)\n\t\treturn -ENOMEM;\n'''
new = old + '''\tec->freq_max_khz = devm_kcalloc(ec->dev, capacity,\n\t\t\t\t\t sizeof(*ec->freq_max_khz), GFP_KERNEL);\n\tif (!ec->freq_max_khz)\n\t\treturn -ENOMEM;\n'''
if s.count(old) != 1:
    raise SystemExit("freq allocation anchor missing")
s = s.replace(old, new, 1)

old = '''\t\tret = freq_qos_add_request(&policy->constraints,\n\t\t\t\t\t   &ec->freq_requests[ec->num_freq_requests],\n\t\t\t\t\t   FREQ_QOS_MAX,\n\t\t\t\t\t   FREQ_QOS_MAX_DEFAULT_VALUE);\n\t\tcpufreq_cpu_put(policy);\n'''
new = '''\t\tret = freq_qos_add_request(&policy->constraints,\n\t\t\t\t\t   &ec->freq_requests[ec->num_freq_requests],\n\t\t\t\t\t   FREQ_QOS_MAX,\n\t\t\t\t\t   FREQ_QOS_MAX_DEFAULT_VALUE);\n\t\tif (ret >= 0)\n\t\t\tec->freq_max_khz[ec->num_freq_requests] = policy->cpuinfo.max_freq;\n\t\tcpufreq_cpu_put(policy);\n'''
if s.count(old) != 1:
    raise SystemExit("freq max capture anchor missing")
s = s.replace(old, new, 1)

# Percentage CPU cap helper.
anchor = 'static void asus_ec_freq_qos_remove(struct asus_ec *ec)\n'
helper = '''static void asus_ec_freq_qos_set_percent(struct asus_ec *ec, unsigned int percent)\n{\n\tunsigned int i;\n\n\tpercent = clamp_t(unsigned int, percent, 1, 100);\n\tfor (i = 0; i < ec->num_freq_requests; i++) {\n\t\ts32 cap = max_t(s32, 1, div_u64((u64)ec->freq_max_khz[i] * percent, 100));\n\t\t(void)freq_qos_update_request(&ec->freq_requests[i], cap);\n\t}\n}\n\n'''
if s.count(anchor) != 1:
    raise SystemExit("qos helper anchor missing")
s = s.replace(anchor, helper + anchor, 1)

# Special zero-PWM path. Generic manual control keeps its 75-PWM floor.
anchor = 'static int asus_ec_apply_profile_locked(struct asus_ec *ec,\n'
helper = '''static int asus_ec_whisper_fanless_locked(struct asus_ec *ec)\n{\n\tint ret;\n\n\tret = asus_ec_set_native_fan_profile(ec, EC_FW_FAN_PROFILE_QUIET);\n\tif (ret)\n\t\treturn ret;\n\tret = asus_ec_set_fan_mode(ec, EC_FAN_MODE_MANUAL);\n\tif (ret)\n\t\treturn ret;\n\tret = asus_ec_set_pwm_both(ec, 0);\n\tif (ret) {\n\t\t(void)asus_ec_force_auto_locked(ec);\n\t\t(void)asus_ec_set_native_fan_profile(ec, EC_FW_FAN_PROFILE_QUIET);\n\t\treturn ret;\n\t}\n\tec->manual_active = true;\n\tec->whisper_fanless = true;\n\treturn 0;\n}\n\nstatic int asus_ec_whisper_quiet_locked(struct asus_ec *ec)\n{\n\tint ret = asus_ec_force_auto_locked(ec);\n\tif (!ret)\n\t\tret = asus_ec_set_native_fan_profile(ec, EC_FW_FAN_PROFILE_QUIET);\n\tif (!ret) {\n\t\tec->manual_active = false;\n\t\tec->whisper_fanless = false;\n\t}\n\treturn ret;\n}\n\nstatic unsigned int asus_ec_whisper_level_for_temp(int temp)\n{\n\tif (temp < 0 || temp >= whisper_fan_mc)\n\t\treturn 3;\n\tif (temp >= whisper_hot_mc)\n\t\treturn 2;\n\tif (temp >= whisper_warm_mc)\n\t\treturn 1;\n\treturn 0;\n}\n\nstatic void asus_ec_whisper_set_qos(struct asus_ec *ec, unsigned int level)\n{\n\tunsigned int percent = whisper_cpu_hot_percent;\n\tif (level == 0)\n\t\tpercent = whisper_cpu_cool_percent;\n\telse if (level == 1)\n\t\tpercent = whisper_cpu_warm_percent;\n\tasus_ec_freq_qos_set_percent(ec, percent);\n}\n\n'''
if s.count(anchor) != 1:
    raise SystemExit("profile helper anchor missing")
s = s.replace(anchor, helper + anchor, 1)

# Replace native-only profile application with native modes + Whisper.
start = s.find('static int asus_ec_apply_profile_locked(struct asus_ec *ec,')
end = s.find('static void asus_ec_safety_work(struct work_struct *work)', start)
if start < 0 or end < 0:
    raise SystemExit("profile function boundaries missing")
replacement = '''static int asus_ec_apply_profile_locked(struct asus_ec *ec,\n\t\t\t\t\tenum asus_ec_profile profile)\n{\n\tu8 marker;\n\tint temp;\n\tint ret;\n\n\tcancel_delayed_work(&ec->whisper_work);\n\tif (profile == ASUS_EC_PROFILE_WHISPER) {\n\t\ttemp = asus_ec_max_temp_mc(ec);\n\t\tec->whisper_level = asus_ec_whisper_level_for_temp(temp);\n\t\tasus_ec_whisper_set_qos(ec, ec->whisper_level);\n\n\t\t/* No complete CPU QoS or no trustworthy temperature => native Quiet. */\n\t\tif (!ec->num_freq_requests || ec->whisper_level == 3)\n\t\t\tret = asus_ec_whisper_quiet_locked(ec);\n\t\telse\n\t\t\tret = asus_ec_whisper_fanless_locked(ec);\n\t\tif (ret)\n\t\t\treturn ret;\n\t\tec->active_profile = profile;\n\t\tec->temp_failures = 0;\n\t\tif (!ec->shutting_down)\n\t\t\tmod_delayed_work(system_freezable_wq, &ec->whisper_work,\n\t\t\t\t\t msecs_to_jiffies(whisper_period_ms));\n\t\treturn 0;\n\t}\n\n\t/* All ASUS named modes are unmodified native firmware modes. */\n\tret = asus_ec_native_profile_marker(profile, &marker);\n\tif (ret)\n\t\treturn ret;\n\tret = asus_ec_force_auto_locked(ec);\n\tif (ret)\n\t\treturn ret;\n\tasus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);\n\tret = asus_ec_set_native_fan_profile(ec, marker);\n\tif (ret)\n\t\treturn ret;\n\tec->whisper_fanless = false;\n\tec->whisper_level = 0;\n\tec->active_profile = profile;\n\tec->temp_failures = 0;\n\treturn 0;\n}\n\nstatic void asus_ec_whisper_work(struct work_struct *work)\n{\n\tstruct asus_ec *ec = container_of(to_delayed_work(work), struct asus_ec, whisper_work);\n\tunsigned int old_level;\n\tunsigned int level;\n\tint temp;\n\n\tmutex_lock(&ec->mode_lock);\n\tif (ec->active_profile != ASUS_EC_PROFILE_WHISPER || ec->shutting_down)\n\t\tgoto out;\n\n\ttemp = asus_ec_max_temp_mc(ec);\n\told_level = ec->whisper_level;\n\tlevel = asus_ec_whisper_level_for_temp(temp);\n\tec->whisper_level = level;\n\tasus_ec_whisper_set_qos(ec, level);\n\n\tif (temp < 0 || level == 3) {\n\t\tif (ec->whisper_fanless)\n\t\t\t(void)asus_ec_whisper_quiet_locked(ec);\n\t} else if (!ec->whisper_fanless && temp <= whisper_recover_mc && ec->num_freq_requests) {\n\t\t(void)asus_ec_whisper_fanless_locked(ec);\n\t}\n\n\tif (old_level != ec->whisper_level)\n\t\tsysfs_notify(&ec->dev->kobj, NULL, "whisper_level");\n\tmod_delayed_work(system_freezable_wq, &ec->whisper_work,\n\t\t\t msecs_to_jiffies(whisper_period_ms));\nout:\n\tmutex_unlock(&ec->mode_lock);\n}\n\n'''
s = s[:start] + replacement + s[end:]

# Names, parser, ordered choices.
s = s.replace('case ASUS_EC_PROFILE_QUIET:\n\t\treturn "quiet";',
              'case ASUS_EC_PROFILE_WHISPER:\n\t\treturn "whisper";\n\tcase ASUS_EC_PROFILE_QUIET:\n\t\treturn "quiet";', 1)
s = s.replace('if (sysfs_streq(buf, "quiet"))\n\t\treturn ASUS_EC_PROFILE_QUIET;',
              'if (sysfs_streq(buf, "whisper"))\n\t\treturn ASUS_EC_PROFILE_WHISPER;\n\tif (sysfs_streq(buf, "quiet"))\n\t\treturn ASUS_EC_PROFILE_QUIET;', 1)
s = s.replace('return sysfs_emit(buf, "quiet normal turbo full-speed\\n");',
              'return sysfs_emit(buf, "whisper quiet normal turbo full-speed\\n");', 1)

# Whisper status for GPU/userspace acoustic policy.
profile_anchor = 'static ssize_t profile_show(struct device *dev,\n'
show = '''static ssize_t whisper_level_show(struct device *dev,\n\t\t\t\t  struct device_attribute *attr, char *buf)\n{\n\tstruct asus_ec *ec = dev_get_drvdata(dev);\n\treturn sysfs_emit(buf, "%u\\n", ec->whisper_level);\n}\n\n'''
if s.count(profile_anchor) != 1:
    raise SystemExit("whisper sysfs anchor missing")
s = s.replace(profile_anchor, show + profile_anchor, 1)
s = s.replace('static DEVICE_ATTR_RW(profile);\nstatic DEVICE_ATTR_RO(profile_choices);',
              'static DEVICE_ATTR_RW(profile);\nstatic DEVICE_ATTR_RO(profile_choices);\nstatic DEVICE_ATTR_RO(whisper_level);', 1)
s = s.replace('\t&dev_attr_profile_choices.attr,\n\tNULL,',
              '\t&dev_attr_profile_choices.attr,\n\t&dev_attr_whisper_level.attr,\n\tNULL,', 1)

# Fn+F order: Whisper -> Quiet -> Normal -> Turbo -> Full Speed -> Whisper.
start = s.find('int asus_a14_cycle_native_profile(void)')
end = s.find('EXPORT_SYMBOL_GPL(asus_a14_cycle_native_profile);', start)
if start < 0 or end < 0:
    raise SystemExit("Fn+F cycle function missing")
end += len('EXPORT_SYMBOL_GPL(asus_a14_cycle_native_profile);')
cycle = '''int asus_a14_cycle_native_profile(void)\n{\n\tstruct asus_ec *ec;\n\tenum asus_ec_profile next;\n\tint ret;\n\n\tif (!asus_ec_pdev)\n\t\treturn -ENODEV;\n\tec = platform_get_drvdata(asus_ec_pdev);\n\tif (!ec)\n\t\treturn -ENODEV;\n\tmutex_lock(&ec->mode_lock);\n\tswitch (ec->active_profile) {\n\tcase ASUS_EC_PROFILE_WHISPER: next = ASUS_EC_PROFILE_QUIET; break;\n\tcase ASUS_EC_PROFILE_QUIET: next = ASUS_EC_PROFILE_BALANCED; break;\n\tcase ASUS_EC_PROFILE_BALANCED: next = ASUS_EC_PROFILE_PERFORMANCE; break;\n\tcase ASUS_EC_PROFILE_PERFORMANCE: next = ASUS_EC_PROFILE_FULL_SPEED; break;\n\tcase ASUS_EC_PROFILE_FULL_SPEED:\n\tdefault: next = ASUS_EC_PROFILE_WHISPER; break;\n\t}\n\tret = asus_ec_apply_profile_locked(ec, next);\n\tmutex_unlock(&ec->mode_lock);\n\tif (!ret) {\n\t\tsysfs_notify(&ec->dev->kobj, NULL, "profile");\n\t\tasus_ec_notify_profile(ec);\n\t}\n\treturn ret;\n}\nEXPORT_SYMBOL_GPL(asus_a14_cycle_native_profile);'''
s = s[:start] + cycle + s[end:]

# Initialize/cancel Whisper worker alongside existing safety worker.
s = s.replace('INIT_DELAYED_WORK(&ec->safety_work, asus_ec_safety_work);',
              'INIT_DELAYED_WORK(&ec->safety_work, asus_ec_safety_work);\n\tINIT_DELAYED_WORK(&ec->whisper_work, asus_ec_whisper_work);', 1)
s = s.replace('cancel_delayed_work_sync(&ec->safety_work);',
              'cancel_delayed_work_sync(&ec->safety_work);\n\tcancel_delayed_work_sync(&ec->whisper_work);', 1)

required = ("A14_WHISPER_MODE", "ASUS_EC_PROFILE_WHISPER", "whisper quiet normal turbo full-speed",
            "asus_ec_whisper_work", "asus_ec_set_pwm_both(ec, 0)", "DEVICE_ATTR_RO(whisper_level)",
            "whisper_cpu_hot_percent", "next = ASUS_EC_PROFILE_WHISPER")
missing = [x for x in required if x not in s]
if missing:
    raise SystemExit("Whisper transform incomplete: " + ", ".join(missing))

p.write_text(s)
print("a14_whisper=applied")
