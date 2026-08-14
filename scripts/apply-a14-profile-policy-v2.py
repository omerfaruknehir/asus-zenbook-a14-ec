#!/usr/bin/env python3
from pathlib import Path
import re

p = Path("asus_zenbook_a14_ec.c")
s = p.read_text()

if "A14_PROFILE_POLICY_V2" in s:
    print("a14_profile_policy_v2=current")
    raise SystemExit(0)


def sub1(pattern: str, repl: str, label: str, flags: int = 0) -> None:
    global s
    new, n = re.subn(pattern, repl, s, count=1, flags=flags)
    if n != 1:
        raise SystemExit(f"{label}: expected one source match, found {n}")
    s = new


# Policy parameters. Percentages are relative to each cpufreq policy's own
# cpuinfo.max_freq so heterogeneous X Elite clusters are capped proportionally.
anchor = (
    'static uint manual_trip_mc = 85000;\n'
    'module_param(manual_trip_mc, uint, 0644);\n'
    'MODULE_PARM_DESC(manual_trip_mc, "Temperature that forces manual fan control back to automatic, in mC");\n'
)
if anchor not in s:
    raise SystemExit("policy parameters: source anchor missing")
s = s.replace(
    anchor,
    anchor
    + '\n#define A14_PROFILE_POLICY_V2 1\n'
    + 'static uint quiet_max_percent = 45;\n'
    + 'module_param(quiet_max_percent, uint, 0644);\n'
    + 'MODULE_PARM_DESC(quiet_max_percent, "Quiet-mode CPU frequency ceiling as percent of each policy maximum");\n\n'
    + 'static uint power_saver_max_percent = 70;\n'
    + 'module_param(power_saver_max_percent, uint, 0644);\n'
    + 'MODULE_PARM_DESC(power_saver_max_percent, "Power-saver CPU frequency ceiling as percent of each policy maximum");\n\n'
    + 'static uint quiet_emergency_mc = 90000;\n'
    + 'module_param(quiet_emergency_mc, uint, 0644);\n'
    + 'MODULE_PARM_DESC(quiet_emergency_mc, "Temperature where Quiet temporarily requests Turbo cooling, in mC");\n\n'
    + 'static uint quiet_recover_mc = 75000;\n'
    + 'module_param(quiet_recover_mc, uint, 0644);\n'
    + 'MODULE_PARM_DESC(quiet_recover_mc, "Temperature where Quiet restores the native quiet curve after emergency cooling, in mC");\n',
    1,
)

# Add the distinct OS power-saver policy without changing the recovered native
# firmware modes.
sub1(
    r'enum asus_ec_profile \{\n\tASUS_EC_PROFILE_QUIET,\n',
    'enum asus_ec_profile {\n\tASUS_EC_PROFILE_QUIET,\n\tASUS_EC_PROFILE_POWER_SAVER,\n',
    "power-saver enum",
)

# Track each registered cpufreq policy's native maximum and Quiet emergency
# state.
sub1(
    r'\tstruct freq_qos_request \*freq_requests;\n\tunsigned int num_freq_requests;\n',
    '\tstruct freq_qos_request *freq_requests;\n\tunsigned int *freq_max_khz;\n\tunsigned int num_freq_requests;\n\tbool quiet_emergency_active;\n',
    "profile state fields",
)

# Power Saver shares the native Normal marker with Balanced; its difference is
# the OS frequency ceiling.
sub1(
    r'(\tcase ASUS_EC_PROFILE_BALANCED:\n\t\t\*marker = EC_FW_FAN_PROFILE_NORMAL;\n)',
    '\tcase ASUS_EC_PROFILE_POWER_SAVER:\n\t\t*marker = EC_FW_FAN_PROFILE_NORMAL;\n\t\treturn 0;\n\\1',
    "power-saver native marker",
)

# Extend freq-QoS setup with each policy's maximum frequency.
sub1(
    r'(\tec->freq_requests = devm_kcalloc\(ec->dev, capacity,\n\t\t\t\t\t sizeof\(\*ec->freq_requests\), GFP_KERNEL\);\n\tif \(!ec->freq_requests\)\n\t\treturn -ENOMEM;\n)',
    '\\1\n\tec->freq_max_khz = devm_kcalloc(ec->dev, capacity,\n\t\t\t\t\t sizeof(*ec->freq_max_khz), GFP_KERNEL);\n\tif (!ec->freq_max_khz)\n\t\treturn -ENOMEM;\n',
    "freq max allocation",
)

sub1(
    r'(\t\tret = freq_qos_add_request\(&policy->constraints,\n\t\t\t\t\t   &ec->freq_requests\[ec->num_freq_requests\],\n\t\t\t\t\t   FREQ_QOS_MAX,\n\t\t\t\t\t   FREQ_QOS_MAX_DEFAULT_VALUE\);\n)(\t\tcpufreq_cpu_put\(policy\);)',
    '\\1\t\tif (ret >= 0)\n\t\t\tec->freq_max_khz[ec->num_freq_requests] = policy->cpuinfo.max_freq;\n\\2',
    "freq max capture",
)

# Add a percentage helper next to the existing absolute QoS helper.
marker = 'static void asus_ec_freq_qos_remove(struct asus_ec *ec)\n'
if marker not in s:
    raise SystemExit("freq percent helper: insertion anchor missing")
helper = '''static void asus_ec_freq_qos_set_percent(struct asus_ec *ec, unsigned int percent)\n{\n\tunsigned int i;\n\n\tpercent = clamp_t(unsigned int, percent, 1, 100);\n\tfor (i = 0; i < ec->num_freq_requests; i++) {\n\t\tu64 scaled = (u64)ec->freq_max_khz[i] * percent;\n\t\ts32 cap = DIV_ROUND_CLOSEST_ULL(scaled, 100);\n\t\tint ret;\n\n\t\tif (!ec->freq_max_khz[i])\n\t\t\tcontinue;\n\t\tret = freq_qos_update_request(&ec->freq_requests[i], cap);\n\t\tif (ret < 0)\n\t\t\tdev_warn_ratelimited(ec->dev,\n\t\t\t\t"cannot update percent freq QoS request %u: %d\\n", i, ret);\n\t}\n}\n\n'''
s = s.replace(marker, helper + marker, 1)

# Replace the composed native-policy application with the final Linux-facing
# semantics. Full Speed deliberately takes manual fan ownership only after the
# recovered native full-speed thermal policy has been selected.
new_apply = '''static int asus_ec_apply_profile_locked(struct asus_ec *ec,\n\t\t\t\t\tenum asus_ec_profile profile)\n{\n\tenum asus_ec_profile previous = ec->active_profile;\n\tu8 previous_marker = 0;\n\tu8 marker;\n\tint ret;\n\n\tret = asus_ec_native_profile_marker(profile, &marker);\n\tif (ret)\n\t\treturn ret;\n\n\t(void)asus_ec_native_profile_marker(previous, &previous_marker);\n\n\t/* Every named policy starts by returning low-level fan ownership to\n\t * firmware. Full Speed takes it back only after selecting native 0x10. */\n\tret = asus_ec_force_auto_locked(ec);\n\tif (ret)\n\t\treturn ret;\n\n\tret = asus_ec_set_native_fan_profile(ec, marker);\n\tif (ret)\n\t\treturn ret;\n\n\tec->quiet_emergency_active = false;\n\tswitch (profile) {\n\tcase ASUS_EC_PROFILE_QUIET:\n\t\tasus_ec_freq_qos_set_percent(ec, quiet_max_percent);\n\t\tbreak;\n\tcase ASUS_EC_PROFILE_POWER_SAVER:\n\t\tasus_ec_freq_qos_set_percent(ec, power_saver_max_percent);\n\t\tbreak;\n\tcase ASUS_EC_PROFILE_BALANCED:\n\tcase ASUS_EC_PROFILE_PERFORMANCE:\n\t\tasus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);\n\t\tbreak;\n\tcase ASUS_EC_PROFILE_FULL_SPEED:\n\t\tasus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);\n\t\tret = asus_ec_enter_manual_locked(ec, 255);\n\t\tif (ret) {\n\t\t\t/* Do not leave the firmware profile changed if literal maximum\n\t\t\t * fan ownership could not be established. */\n\t\t\t(void)asus_ec_force_auto_locked(ec);\n\t\t\tif (previous != ASUS_EC_PROFILE_CUSTOM && previous_marker)\n\t\t\t\t(void)asus_ec_set_native_fan_profile(ec, previous_marker);\n\t\t\treturn ret;\n\t\t}\n\t\tbreak;\n\tdefault:\n\t\treturn -EOPNOTSUPP;\n\t}\n\n\tec->active_profile = profile;\n\tec->temp_failures = 0;\n\tif (profile == ASUS_EC_PROFILE_QUIET && !ec->shutting_down)\n\t\tmod_delayed_work(system_freezable_wq, &ec->safety_work,\n\t\t\t\t msecs_to_jiffies(PROFILE_SAFETY_PERIOD_MS));\n\telse\n\t\tcancel_delayed_work(&ec->safety_work);\n\treturn 0;\n}\n\n'''
sub1(
    r'static int asus_ec_apply_profile_locked\(struct asus_ec \*ec,.*?\n}\n\n(?=static void asus_ec_safety_work)',
    new_apply,
    "profile application v2",
    re.S,
)

# Quiet is throttle-first. It keeps the strong CPU cap at all times; only the
# firmware cooling curve is temporarily promoted to Turbo after a genuinely
# high temperature or repeated inability to read temperatures. Hysteresis
# avoids fan/profile flapping. Custom manual PWM retains the existing safety
# fallback. Full Speed does not need a high-temperature fallback because it is
# already commanding maximum cooling.
new_safety = '''static void asus_ec_safety_work(struct work_struct *work)\n{\n\tstruct asus_ec *ec = container_of(to_delayed_work(work),\n\t\t\t\t\t  struct asus_ec, safety_work);\n\tbool fallback = false;\n\tint temp;\n\n\tmutex_lock(&ec->mode_lock);\n\tif (ec->shutting_down)\n\t\tgoto out;\n\n\ttemp = asus_ec_max_temp_mc(ec);\n\tif (temp < 0)\n\t\tec->temp_failures++;\n\telse\n\t\tec->temp_failures = 0;\n\n\tif (ec->active_profile == ASUS_EC_PROFILE_QUIET) {\n\t\tint ret = 0;\n\n\t\tif (!ec->quiet_emergency_active &&\n\t\t    ((temp >= 0 && temp >= quiet_emergency_mc) ||\n\t\t     ec->temp_failures >= PROFILE_MAX_TEMP_FAILURES)) {\n\t\t\tret = asus_ec_set_native_fan_profile(ec, EC_FW_FAN_PROFILE_TURBO);\n\t\t\tif (!ret) {\n\t\t\t\tec->quiet_emergency_active = true;\n\t\t\t\tdev_warn(ec->dev,\n\t\t\t\t\t "Quiet emergency cooling engaged (temp=%d, read failures=%u); CPU cap retained\\n",\n\t\t\t\t\t temp, ec->temp_failures);\n\t\t\t}\n\t\t} else if (ec->quiet_emergency_active && temp >= 0 &&\n\t\t\t   temp <= quiet_recover_mc) {\n\t\t\tret = asus_ec_set_native_fan_profile(ec, EC_FW_FAN_PROFILE_QUIET);\n\t\t\tif (!ret) {\n\t\t\t\tec->quiet_emergency_active = false;\n\t\t\t\tdev_info(ec->dev,\n\t\t\t\t\t "Quiet emergency cooling cleared at %d mC\\n", temp);\n\t\t\t}\n\t\t}\n\n\t\tif (ret)\n\t\t\tdev_err_ratelimited(ec->dev,\n\t\t\t\t"Quiet emergency cooling update failed: %d\\n", ret);\n\t\tmod_delayed_work(system_freezable_wq, &ec->safety_work,\n\t\t\t\t msecs_to_jiffies(PROFILE_SAFETY_PERIOD_MS));\n\t\tgoto out;\n\t}\n\n\tif (!ec->manual_active || ec->active_profile == ASUS_EC_PROFILE_FULL_SPEED)\n\t\tgoto out;\n\n\tif (temp < 0)\n\t\tfallback = ec->temp_failures >= PROFILE_MAX_TEMP_FAILURES;\n\telse\n\t\tfallback = temp >= manual_trip_mc;\n\n\tif (fallback) {\n\t\tint ret;\n\n\t\tdev_warn(ec->dev,\n\t\t\t "custom manual fan safety fallback (temp=%d, read failures=%u)\\n",\n\t\t\t temp, ec->temp_failures);\n\t\tret = asus_ec_force_auto_locked(ec);\n\t\tif (!ret)\n\t\t\tret = asus_ec_set_native_fan_profile(ec, EC_FW_FAN_PROFILE_NORMAL);\n\t\tif (!ret) {\n\t\t\tec->active_profile = ASUS_EC_PROFILE_BALANCED;\n\t\t\tasus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);\n\t\t\tsysfs_notify(&ec->dev->kobj, NULL, "profile");\n\t\t\tasus_ec_notify_profile(ec);\n\t\t\tgoto out;\n\t\t}\n\n\t\tec->active_profile = ASUS_EC_PROFILE_CUSTOM;\n\t\tdev_err(ec->dev,\n\t\t\t"failed to restore automatic fan mode during safety fallback: %d\\n",\n\t\t\tret);\n\t}\n\n\tif (ec->manual_active && !ec->shutting_down)\n\t\tmod_delayed_work(system_freezable_wq, &ec->safety_work,\n\t\t\t\t msecs_to_jiffies(PROFILE_SAFETY_PERIOD_MS));\nout:\n\tmutex_unlock(&ec->mode_lock);\n}\n\n'''
sub1(
    r'static void asus_ec_safety_work\(struct work_struct \*work\).*?\n}\n\n(?=static const char \*asus_ec_profile_name)',
    new_safety,
    "safety policy v2",
    re.S,
)

# Private sysfs exposes all five named policies plus CUSTOM via hwmon manual
# control.
sub1(
    r'\tcase ASUS_EC_PROFILE_QUIET:\n\t\treturn "quiet";\n',
    '\tcase ASUS_EC_PROFILE_QUIET:\n\t\treturn "quiet";\n\tcase ASUS_EC_PROFILE_POWER_SAVER:\n\t\treturn "power-saver";\n',
    "power-saver profile name",
)
sub1(
    r'(\tif \(sysfs_streq\(buf, "quiet"\)\)\n\t\treturn ASUS_EC_PROFILE_QUIET;\n)',
    '\\1\tif (sysfs_streq(buf, "power-saver") || sysfs_streq(buf, "low-power"))\n\t\treturn ASUS_EC_PROFILE_POWER_SAVER;\n',
    "power-saver profile parser",
)
sub1(
    r'return sysfs_emit\(buf, "quiet balanced performance full-speed\\n"\);',
    'return sysfs_emit(buf, "quiet power-saver balanced performance full-speed\\n");',
    "profile choices v2",
)

# Standard Linux platform_profile gains both LOW_POWER and QUIET. This is
# important for power-profiles-daemon: when low-power exists, GNOME Power Saver
# maps to it instead of hijacking the separate acoustic Quiet mode.
sub1(
    r'(static int asus_ec_pp_probe\(void \*drvdata, unsigned long \*choices\)\n\{\n)',
    '\\1\tset_bit(PLATFORM_PROFILE_LOW_POWER, choices);\n',
    "platform low-power choice",
)
sub1(
    r'(\tswitch \(ec->active_profile\) \{\n)',
    '\\1\tcase ASUS_EC_PROFILE_POWER_SAVER:\n\t\t*profile = PLATFORM_PROFILE_LOW_POWER;\n\t\tbreak;\n',
    "platform low-power getter",
)
sub1(
    r'(\tswitch \(profile\) \{\n)',
    '\\1\tcase PLATFORM_PROFILE_LOW_POWER:\n\t\tmapped = ASUS_EC_PROFILE_POWER_SAVER;\n\t\tbreak;\n',
    "platform low-power setter",
)

# An aborted suspend must restore every named policy, not only Performance.
# CUSTOM is intentionally converted to Balanced instead of replaying arbitrary
# manual PWM after a failed sleep transition.
s = s.replace(
    'if (profile == ASUS_EC_PROFILE_PERFORMANCE)\n\t\t\trestore_ret = asus_ec_apply_profile_locked(ec, profile);\n\t\telse if (profile == ASUS_EC_PROFILE_CUSTOM) {',
    'if (profile != ASUS_EC_PROFILE_CUSTOM)\n\t\t\trestore_ret = asus_ec_apply_profile_locked(ec, profile);\n\t\telse {',
    1,
)

# Make the runtime banner useful for validating QoS registration.
s = s.replace(
    '"ready: EC temp=%u C, profiles=quiet/balanced/performance/full-speed, fans=2\\n",\n\t\t temp);',
    '"ready: EC temp=%u C, profiles=quiet/power-saver/balanced/performance/full-speed, fans=2, freq_qos_policies=%u\\n",\n\t\t temp, ec->num_freq_requests);',
    1,
)

# Final structural checks.
required = (
    'ASUS_EC_PROFILE_POWER_SAVER',
    'PLATFORM_PROFILE_LOW_POWER',
    'quiet_max_percent',
    'power_saver_max_percent',
    'quiet_emergency_active',
    'asus_ec_enter_manual_locked(ec, 255)',
    'EC_FW_FAN_PROFILE_TURBO',
)
missing = [token for token in required if token not in s]
if missing:
    raise SystemExit(f"policy v2 incomplete, missing: {', '.join(missing)}")

p.write_text(s)
print("a14_profile_policy_v2=applied")
