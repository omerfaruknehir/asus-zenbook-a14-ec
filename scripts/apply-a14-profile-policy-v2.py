#!/usr/bin/env python3
from pathlib import Path
import re

p = Path("asus_zenbook_a14_ec.c")
s = p.read_text()

if "A14_PROFILE_POLICY_V2" in s:
    print("a14_profile_policy_v2=current")
    raise SystemExit(0)


def replace_once(old: str, new: str, label: str) -> None:
    global s
    count = s.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one source anchor, found {count}")
    s = s.replace(old, new, 1)


def replace_between(start_pat: str, next_pat: str, new: str, label: str) -> None:
    global s
    pattern = re.compile(start_pat + r".*?(?=" + next_pat + r")", re.S)
    s2, count = pattern.subn(lambda _m: new, s, count=1)
    if count != 1:
        raise SystemExit(f"{label}: expected one function block, found {count}")
    s = s2


# Percentages are relative to each cpufreq policy's own native maximum, which
# keeps the policy meaningful on the heterogeneous X Elite clusters.
params = '''static uint manual_trip_mc = 85000;\nmodule_param(manual_trip_mc, uint, 0644);\nMODULE_PARM_DESC(manual_trip_mc, "Temperature that forces manual fan control back to automatic, in mC");\n'''
replace_once(
    params,
    params + '''\n#define A14_PROFILE_POLICY_V2 1\n\nstatic uint quiet_max_percent = 45;\nmodule_param(quiet_max_percent, uint, 0644);\nMODULE_PARM_DESC(quiet_max_percent, "Quiet CPU frequency ceiling as percent of each cpufreq policy maximum");\n\nstatic uint power_saver_max_percent = 70;\nmodule_param(power_saver_max_percent, uint, 0644);\nMODULE_PARM_DESC(power_saver_max_percent, "Power Saver CPU frequency ceiling as percent of each cpufreq policy maximum");\n\nstatic uint quiet_emergency_mc = 90000;\nmodule_param(quiet_emergency_mc, uint, 0644);\nMODULE_PARM_DESC(quiet_emergency_mc, "Temperature where Quiet temporarily requests Turbo cooling, in mC");\n\nstatic uint quiet_recover_mc = 75000;\nmodule_param(quiet_recover_mc, uint, 0644);\nMODULE_PARM_DESC(quiet_recover_mc, "Temperature where Quiet restores the native quiet curve, in mC");\n''',
    "policy parameters",
)

replace_once(
    '''enum asus_ec_profile {\n\tASUS_EC_PROFILE_QUIET,\n''',
    '''enum asus_ec_profile {\n\tASUS_EC_PROFILE_QUIET,\n\tASUS_EC_PROFILE_POWER_SAVER,\n''',
    "power-saver enum",
)

replace_once(
    '''\tstruct freq_qos_request *freq_requests;\n\tunsigned int num_freq_requests;\n''',
    '''\tstruct freq_qos_request *freq_requests;\n\tunsigned int *freq_max_khz;\n\tunsigned int num_freq_requests;\n\tbool quiet_emergency_active;\n''',
    "frequency/profile state",
)

# POWER_SAVER and BALANCED intentionally share firmware Normal (0x01); the OS
# frequency ceiling is what distinguishes them.
replace_once(
    '''\tcase ASUS_EC_PROFILE_BALANCED:\n\t\t*marker = EC_FW_FAN_PROFILE_NORMAL;\n\t\treturn 0;\n''',
    '''\tcase ASUS_EC_PROFILE_POWER_SAVER:\n\t\t*marker = EC_FW_FAN_PROFILE_NORMAL;\n\t\treturn 0;\n\tcase ASUS_EC_PROFILE_BALANCED:\n\t\t*marker = EC_FW_FAN_PROFILE_NORMAL;\n\t\treturn 0;\n''',
    "power-saver native marker",
)

replace_once(
    '''\tec->freq_requests = devm_kcalloc(ec->dev, capacity,\n\t\t\t\t\t sizeof(*ec->freq_requests), GFP_KERNEL);\n\tif (!ec->freq_requests)\n\t\treturn -ENOMEM;\n''',
    '''\tec->freq_requests = devm_kcalloc(ec->dev, capacity,\n\t\t\t\t\t sizeof(*ec->freq_requests), GFP_KERNEL);\n\tif (!ec->freq_requests)\n\t\treturn -ENOMEM;\n\tec->freq_max_khz = devm_kcalloc(ec->dev, capacity,\n\t\t\t\t\t sizeof(*ec->freq_max_khz), GFP_KERNEL);\n\tif (!ec->freq_max_khz)\n\t\treturn -ENOMEM;\n''',
    "frequency max allocation",
)

replace_once(
    '''\t\tret = freq_qos_add_request(&policy->constraints,\n\t\t\t\t\t   &ec->freq_requests[ec->num_freq_requests],\n\t\t\t\t\t   FREQ_QOS_MAX,\n\t\t\t\t\t   FREQ_QOS_MAX_DEFAULT_VALUE);\n\t\tcpufreq_cpu_put(policy);\n''',
    '''\t\tret = freq_qos_add_request(&policy->constraints,\n\t\t\t\t\t   &ec->freq_requests[ec->num_freq_requests],\n\t\t\t\t\t   FREQ_QOS_MAX,\n\t\t\t\t\t   FREQ_QOS_MAX_DEFAULT_VALUE);\n\t\tif (ret >= 0)\n\t\t\tec->freq_max_khz[ec->num_freq_requests] = policy->cpuinfo.max_freq;\n\t\tcpufreq_cpu_put(policy);\n''',
    "frequency max capture",
)

freq_remove_anchor = 'static void asus_ec_freq_qos_remove(struct asus_ec *ec)\n'
if s.count(freq_remove_anchor) != 1:
    raise SystemExit("frequency percentage helper: insertion anchor missing")
s = s.replace(
    freq_remove_anchor,
    '''static void asus_ec_freq_qos_set_percent(struct asus_ec *ec, unsigned int percent)\n{\n\tunsigned int i;\n\n\tpercent = clamp_t(unsigned int, percent, 1, 100);\n\tfor (i = 0; i < ec->num_freq_requests; i++) {\n\t\tu64 scaled;\n\t\ts32 cap;\n\t\tint ret;\n\n\t\tif (!ec->freq_max_khz[i])\n\t\t\tcontinue;\n\t\tscaled = (u64)ec->freq_max_khz[i] * percent;\n\t\tcap = DIV_ROUND_CLOSEST_ULL(scaled, 100);\n\t\tret = freq_qos_update_request(&ec->freq_requests[i], cap);\n\t\tif (ret < 0)\n\t\t\tdev_warn_ratelimited(ec->dev,\n\t\t\t\t"cannot update percent freq QoS request %u: %d\\n", i, ret);\n\t}\n}\n\n''' + freq_remove_anchor,
    1,
)

new_apply = '''static int asus_ec_apply_profile_locked(struct asus_ec *ec,\n\t\t\t\t\tenum asus_ec_profile profile)\n{\n\tenum asus_ec_profile previous = ec->active_profile;\n\tu8 previous_marker = 0;\n\tu8 marker;\n\tint ret;\n\n\tret = asus_ec_native_profile_marker(profile, &marker);\n\tif (ret)\n\t\treturn ret;\n\t(void)asus_ec_native_profile_marker(previous, &previous_marker);\n\n\t/* Every named policy starts from firmware-owned AUTO. Full Speed takes\n\t * fan ownership back only after the recovered native 0x10 policy lands. */\n\tret = asus_ec_force_auto_locked(ec);\n\tif (ret)\n\t\treturn ret;\n\tret = asus_ec_set_native_fan_profile(ec, marker);\n\tif (ret)\n\t\treturn ret;\n\n\tec->quiet_emergency_active = false;\n\tswitch (profile) {\n\tcase ASUS_EC_PROFILE_QUIET:\n\t\tasus_ec_freq_qos_set_percent(ec, quiet_max_percent);\n\t\tbreak;\n\tcase ASUS_EC_PROFILE_POWER_SAVER:\n\t\tasus_ec_freq_qos_set_percent(ec, power_saver_max_percent);\n\t\tbreak;\n\tcase ASUS_EC_PROFILE_BALANCED:\n\tcase ASUS_EC_PROFILE_PERFORMANCE:\n\t\tasus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);\n\t\tbreak;\n\tcase ASUS_EC_PROFILE_FULL_SPEED:\n\t\tasus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);\n\t\tret = asus_ec_enter_manual_locked(ec, 255);\n\t\tif (ret) {\n\t\t\t(void)asus_ec_force_auto_locked(ec);\n\t\t\tif (previous != ASUS_EC_PROFILE_CUSTOM && previous_marker)\n\t\t\t\t(void)asus_ec_set_native_fan_profile(ec, previous_marker);\n\t\t\treturn ret;\n\t\t}\n\t\tbreak;\n\tdefault:\n\t\treturn -EOPNOTSUPP;\n\t}\n\n\tec->active_profile = profile;\n\tec->temp_failures = 0;\n\tif (profile == ASUS_EC_PROFILE_QUIET && !ec->shutting_down)\n\t\tmod_delayed_work(system_freezable_wq, &ec->safety_work,\n\t\t\t\t msecs_to_jiffies(PROFILE_SAFETY_PERIOD_MS));\n\telse\n\t\tcancel_delayed_work(&ec->safety_work);\n\treturn 0;\n}\n\n'''
replace_between(
    r'static int asus_ec_apply_profile_locked\(struct asus_ec \*ec,',
    r'static void asus_ec_safety_work',
    new_apply,
    "profile application v2",
)

new_safety = '''static void asus_ec_safety_work(struct work_struct *work)\n{\n\tstruct asus_ec *ec = container_of(to_delayed_work(work),\n\t\t\t\t\t  struct asus_ec, safety_work);\n\tbool fallback = false;\n\tint temp;\n\n\tmutex_lock(&ec->mode_lock);\n\tif (ec->shutting_down)\n\t\tgoto out;\n\n\ttemp = asus_ec_max_temp_mc(ec);\n\tif (temp < 0)\n\t\tec->temp_failures++;\n\telse\n\t\tec->temp_failures = 0;\n\n\tif (ec->active_profile == ASUS_EC_PROFILE_QUIET) {\n\t\tint ret = 0;\n\n\t\tif (!ec->quiet_emergency_active &&\n\t\t    ((temp >= 0 && temp >= quiet_emergency_mc) ||\n\t\t     ec->temp_failures >= PROFILE_MAX_TEMP_FAILURES)) {\n\t\t\tret = asus_ec_set_native_fan_profile(ec, EC_FW_FAN_PROFILE_TURBO);\n\t\t\tif (!ret) {\n\t\t\t\tec->quiet_emergency_active = true;\n\t\t\t\tdev_warn(ec->dev,\n\t\t\t\t\t "Quiet emergency cooling engaged (temp=%d, read failures=%u); CPU cap retained\\n",\n\t\t\t\t\t temp, ec->temp_failures);\n\t\t\t}\n\t\t} else if (ec->quiet_emergency_active && temp >= 0 &&\n\t\t\t   temp <= quiet_recover_mc) {\n\t\t\tret = asus_ec_set_native_fan_profile(ec, EC_FW_FAN_PROFILE_QUIET);\n\t\t\tif (!ret) {\n\t\t\t\tec->quiet_emergency_active = false;\n\t\t\t\tdev_info(ec->dev,\n\t\t\t\t\t "Quiet emergency cooling cleared at %d mC\\n", temp);\n\t\t\t}\n\t\t}\n\n\t\tif (ret)\n\t\t\tdev_err_ratelimited(ec->dev,\n\t\t\t\t"Quiet emergency cooling update failed: %d\\n", ret);\n\t\tmod_delayed_work(system_freezable_wq, &ec->safety_work,\n\t\t\t\t msecs_to_jiffies(PROFILE_SAFETY_PERIOD_MS));\n\t\tgoto out;\n\t}\n\n\tif (!ec->manual_active || ec->active_profile == ASUS_EC_PROFILE_FULL_SPEED)\n\t\tgoto out;\n\n\tif (temp < 0)\n\t\tfallback = ec->temp_failures >= PROFILE_MAX_TEMP_FAILURES;\n\telse\n\t\tfallback = temp >= manual_trip_mc;\n\n\tif (fallback) {\n\t\tint ret;\n\n\t\tdev_warn(ec->dev,\n\t\t\t "custom manual fan safety fallback (temp=%d, read failures=%u)\\n",\n\t\t\t temp, ec->temp_failures);\n\t\tret = asus_ec_force_auto_locked(ec);\n\t\tif (!ret)\n\t\t\tret = asus_ec_set_native_fan_profile(ec, EC_FW_FAN_PROFILE_NORMAL);\n\t\tif (!ret) {\n\t\t\tec->active_profile = ASUS_EC_PROFILE_BALANCED;\n\t\t\tasus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);\n\t\t\tsysfs_notify(&ec->dev->kobj, NULL, "profile");\n\t\t\tasus_ec_notify_profile(ec);\n\t\t\tgoto out;\n\t\t}\n\n\t\tec->active_profile = ASUS_EC_PROFILE_CUSTOM;\n\t\tdev_err(ec->dev,\n\t\t\t"failed to restore automatic fan mode during safety fallback: %d\\n", ret);\n\t}\n\n\tif (ec->manual_active && !ec->shutting_down)\n\t\tmod_delayed_work(system_freezable_wq, &ec->safety_work,\n\t\t\t\t msecs_to_jiffies(PROFILE_SAFETY_PERIOD_MS));\nout:\n\tmutex_unlock(&ec->mode_lock);\n}\n\n'''
replace_between(
    r'static void asus_ec_safety_work\(struct work_struct \*work\)',
    r'static const char \*asus_ec_profile_name',
    new_safety,
    "safety policy v2",
)

replace_once(
    '''\tcase ASUS_EC_PROFILE_QUIET:\n\t\treturn "quiet";\n''',
    '''\tcase ASUS_EC_PROFILE_QUIET:\n\t\treturn "quiet";\n\tcase ASUS_EC_PROFILE_POWER_SAVER:\n\t\treturn "power-saver";\n''',
    "power-saver profile name",
)
replace_once(
    '''\tif (sysfs_streq(buf, "quiet"))\n\t\treturn ASUS_EC_PROFILE_QUIET;\n''',
    '''\tif (sysfs_streq(buf, "quiet"))\n\t\treturn ASUS_EC_PROFILE_QUIET;\n\tif (sysfs_streq(buf, "power-saver") || sysfs_streq(buf, "low-power"))\n\t\treturn ASUS_EC_PROFILE_POWER_SAVER;\n''',
    "power-saver profile parser",
)
replace_once(
    'return sysfs_emit(buf, "quiet balanced performance full-speed\\n");',
    'return sysfs_emit(buf, "quiet power-saver balanced performance full-speed\\n");',
    "profile choices v2",
)

replace_once(
    '''static int asus_ec_pp_probe(void *drvdata, unsigned long *choices)\n{\n''',
    '''static int asus_ec_pp_probe(void *drvdata, unsigned long *choices)\n{\n\tset_bit(PLATFORM_PROFILE_LOW_POWER, choices);\n''',
    "platform low-power choice",
)
replace_once(
    '''\tswitch (ec->active_profile) {\n''',
    '''\tswitch (ec->active_profile) {\n\tcase ASUS_EC_PROFILE_POWER_SAVER:\n\t\t*profile = PLATFORM_PROFILE_LOW_POWER;\n\t\tbreak;\n''',
    "platform low-power getter",
)
replace_once(
    '''\tswitch (profile) {\n''',
    '''\tswitch (profile) {\n\tcase PLATFORM_PROFILE_LOW_POWER:\n\t\tmapped = ASUS_EC_PROFILE_POWER_SAVER;\n\t\tbreak;\n''',
    "platform low-power setter",
)

# Hardening originally restored only PERFORMANCE after a failed mailbox
# quiesce. With five named policies, every non-CUSTOM profile must be replayed.
old_suspend_restore = '''\t\tif (profile == ASUS_EC_PROFILE_PERFORMANCE)\n\t\t\trestore_ret = asus_ec_apply_profile_locked(ec, profile);\n\t\telse if (profile == ASUS_EC_PROFILE_CUSTOM) {\n'''
if old_suspend_restore in s:
    s = s.replace(
        old_suspend_restore,
        '''\t\tif (profile != ASUS_EC_PROFILE_CUSTOM)\n\t\t\trestore_ret = asus_ec_apply_profile_locked(ec, profile);\n\t\telse {\n''',
        1,
    )

# The generated banner from the native transform is stale; make QoS
# registration visible so hardware tests can prove throttling is active.
s = s.replace(
    '"ready: EC temp=%u C, profiles=quiet/balanced/performance/full-speed, fans=2\\n",\n\t\t temp);',
    '"ready: EC temp=%u C, profiles=quiet/power-saver/balanced/performance/full-speed, fans=2, freq_qos_policies=%u\\n",\n\t\t temp, ec->num_freq_requests);',
    1,
)

required = (
    "A14_PROFILE_POLICY_V2",
    "ASUS_EC_PROFILE_POWER_SAVER",
    "PLATFORM_PROFILE_LOW_POWER",
    "quiet_max_percent",
    "power_saver_max_percent",
    "quiet_emergency_active",
    "asus_ec_enter_manual_locked(ec, 255)",
)
missing = [token for token in required if token not in s]
if missing:
    raise SystemExit("policy v2 incomplete: " + ", ".join(missing))

p.write_text(s)
print("a14_profile_policy_v2=applied")
