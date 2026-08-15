#!/usr/bin/env python3
from pathlib import Path

p = Path("asus_zenbook_a14_ec.c")
s = p.read_text()

if "A14_QUIET_FANLESS" in s:
    print("a14_quiet_fanless=current")
    raise SystemExit(0)

if "A14_PROFILE_TRANSACTIONAL" not in s:
    raise SystemExit("quiet fanless layer requires transactional profile layer first")


def once(old: str, new: str, label: str) -> None:
    global s
    if new in s:
        return
    count = s.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one source anchor, found {count}")
    s = s.replace(old, new, 1)


once(
    "#define A14_PROFILE_TRANSACTIONAL 1\n",
    "#define A14_PROFILE_TRANSACTIONAL 1\n#define A14_QUIET_FANLESS 1\n",
    "quiet fanless marker",
)

once(
    '''MODULE_PARM_DESC(quiet_max_percent, "Quiet CPU frequency ceiling as percent of each cpufreq policy maximum");\n''',
    '''MODULE_PARM_DESC(quiet_max_percent, "Quiet CPU frequency ceiling as percent of each cpufreq policy maximum");\n\nstatic uint quiet_fan_pwm;\nmodule_param(quiet_fan_pwm, uint, 0644);\nMODULE_PARM_DESC(quiet_fan_pwm, "Quiet manual fan PWM: 0 stops fans, otherwise 75-255");\n''',
    "quiet fan PWM parameter",
)

# Keep the normal anti-stall floor for arbitrary manual control, but permit the
# explicit stopped-fan value 0 used by Quiet. Values 1..74 remain rejected.
once(
    '''\tif (pwm < EC_PWM_SPIN_FLOOR)\n\t\treturn -EINVAL;\n''',
    '''\tif (pwm && pwm < EC_PWM_SPIN_FLOOR)\n\t\treturn -EINVAL;\n''',
    "allow deliberate fan stop",
)

# The cpufreq provider can appear after this EC platform driver probes on the
# DT-booted X1E system. Retry attachment when a throttled profile is selected,
# instead of permanently declaring Quiet incapable of CPU QoS.
remove_anchor = '''static void asus_ec_freq_qos_remove(struct asus_ec *ec)\n'''
retry_helper = '''static int asus_ec_freq_qos_retry_attach(struct asus_ec *ec)\n{\n\tunsigned int cpu;\n\tint ret;\n\n\tif (ec->num_freq_requests)\n\t\treturn 0;\n\n\tfor_each_possible_cpu(cpu) {\n\t\tstruct cpufreq_policy *policy = cpufreq_cpu_get(cpu);\n\n\t\tif (!policy)\n\t\t\tcontinue;\n\t\tif (cpu != cpumask_first(policy->related_cpus)) {\n\t\t\tcpufreq_cpu_put(policy);\n\t\t\tcontinue;\n\t\t}\n\n\t\tret = freq_qos_add_request(&policy->constraints,\n\t\t\t\t\t   &ec->freq_requests[ec->num_freq_requests],\n\t\t\t\t\t   FREQ_QOS_MAX,\n\t\t\t\t\t   FREQ_QOS_MAX_DEFAULT_VALUE);\n\t\tif (ret >= 0)\n\t\t\tec->freq_max_khz[ec->num_freq_requests] = policy->cpuinfo.max_freq;\n\t\tcpufreq_cpu_put(policy);\n\n\t\tif (ret < 0) {\n\t\t\tdev_warn(ec->dev, "late freq QoS attach failed for CPU%u: %d\\n",\n\t\t\t\t cpu, ret);\n\t\t\tcontinue;\n\t\t}\n\t\tec->num_freq_requests++;\n\t}\n\n\tif (ec->num_freq_requests) {\n\t\tdev_info(ec->dev, "late freq QoS attach succeeded: %u policies\\n",\n\t\t\t ec->num_freq_requests);\n\t\treturn 0;\n\t}\n\n\treturn -ENODEV;\n}\n\n'''
if retry_helper not in s:
    if s.count(remove_anchor) != 1:
        raise SystemExit("late freq QoS helper: insertion anchor missing")
    s = s.replace(remove_anchor, retry_helper + remove_anchor, 1)

once(
    '''\ttarget_quiet_qos_unavailable =\n\t\tprofile == ASUS_EC_PROFILE_QUIET && !ec->num_freq_requests;\n''',
    '''\tif ((profile == ASUS_EC_PROFILE_QUIET ||\n\t     profile == ASUS_EC_PROFILE_POWER_SAVER) &&\n\t    !ec->num_freq_requests)\n\t\t(void)asus_ec_freq_qos_retry_attach(ec);\n\n\ttarget_quiet_qos_unavailable =\n\t\tprofile == ASUS_EC_PROFILE_QUIET && !ec->num_freq_requests;\n''',
    "late QoS retry on throttled profiles",
)

# Restore Quiet as a complete policy after a failed transition: native Quiet,
# frequency cap, then deliberate fan stop. Emergency/QoS-unavailable Quiet is
# firmware-owned Turbo and therefore must remain in AUTO.
once(
    '''\tret = asus_ec_set_native_fan_profile(ec, marker);\n\tif (ret)\n\t\treturn ret;\n\tasus_ec_set_qos_for_profile(ec, previous);\n\n\tif (previous == ASUS_EC_PROFILE_FULL_SPEED) {\n''',
    '''\tret = asus_ec_set_native_fan_profile(ec, marker);\n\tif (ret)\n\t\treturn ret;\n\tasus_ec_set_qos_for_profile(ec, previous);\n\n\tif (previous == ASUS_EC_PROFILE_QUIET &&\n\t    !previous_quiet_emergency && !previous_quiet_qos_unavailable) {\n\t\tret = asus_ec_enter_manual_locked(ec, quiet_fan_pwm);\n\t\tif (ret) {\n\t\t\t(void)asus_ec_force_auto_locked(ec);\n\t\t\t(void)asus_ec_set_native_fan_profile(ec, EC_FW_FAN_PROFILE_NORMAL);\n\t\t\tasus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);\n\t\t\tec->quiet_emergency_active = false;\n\t\t\tec->quiet_qos_unavailable = false;\n\t\t\tec->active_profile = ASUS_EC_PROFILE_BALANCED;\n\t\t\tsysfs_notify(&ec->dev->kobj, NULL, "profile");\n\t\t\tasus_ec_notify_profile(ec);\n\t\t\treturn ret;\n\t\t}\n\t}\n\n\tif (previous == ASUS_EC_PROFILE_FULL_SPEED) {\n''',
    "transactional Quiet restore",
)

# Once native Quiet is selected and the CPU cap is active, take low-level fan
# ownership and stop both fans. If that fails, roll back to the prior complete
# profile rather than leaving a half-applied Quiet state.
once(
    '''\tasus_ec_set_qos_for_profile(ec, profile);\n\n\tif (profile == ASUS_EC_PROFILE_FULL_SPEED) {\n''',
    '''\tasus_ec_set_qos_for_profile(ec, profile);\n\n\tif (profile == ASUS_EC_PROFILE_QUIET && !target_quiet_qos_unavailable) {\n\t\tif (quiet_fan_pwm > 255 ||\n\t\t    (quiet_fan_pwm && quiet_fan_pwm < EC_PWM_SPIN_FLOOR))\n\t\t\treturn -EINVAL;\n\n\t\tret = asus_ec_enter_manual_locked(ec, quiet_fan_pwm);\n\t\tif (ret) {\n\t\t\t(void)asus_ec_force_auto_locked(ec);\n\t\t\trestore_ret = asus_ec_restore_profile_locked(ec, previous,\n\t\t\t\t\t\t\t\t previous_quiet_emergency,\n\t\t\t\t\t\t\t\t previous_quiet_qos_unavailable);\n\t\t\tif (restore_ret)\n\t\t\t\tdev_err(ec->dev,\n\t\t\t\t\t"Quiet fan-stop setup failed (%d) and previous policy restore failed (%d)\\n",\n\t\t\t\t\tret, restore_ret);\n\t\t\treturn ret;\n\t\t}\n\t}\n\n\tif (profile == ASUS_EC_PROFILE_FULL_SPEED) {\n''',
    "Quiet fan stop application",
)

# Emergency escalation must relinquish manual fan ownership before asking the
# firmware Turbo curve to cool the machine. Otherwise Turbo is selected while
# the EC is still held in manual PWM mode and cannot control the fans.
once(
    '''\t\t\tret = asus_ec_set_native_fan_profile(ec, EC_FW_FAN_PROFILE_TURBO);\n\t\t\tif (!ret) {\n\t\t\t\tec->quiet_emergency_active = true;\n''',
    '''\t\t\tret = asus_ec_force_auto_locked(ec);\n\t\t\tif (!ret)\n\t\t\t\tret = asus_ec_set_native_fan_profile(ec, EC_FW_FAN_PROFILE_TURBO);\n\t\t\tif (!ret) {\n\t\t\t\tec->quiet_emergency_active = true;\n''',
    "Quiet emergency AUTO handoff",
)

# Recovery returns to native Quiet and then re-establishes the deliberate fan
# stop. If fan-stop setup fails, remain in firmware AUTO rather than claiming a
# silent state that was not actually established.
once(
    '''\t\t\tret = asus_ec_set_native_fan_profile(ec, EC_FW_FAN_PROFILE_QUIET);\n\t\t\tif (!ret) {\n\t\t\t\tec->quiet_emergency_active = false;\n''',
    '''\t\t\tret = asus_ec_set_native_fan_profile(ec, EC_FW_FAN_PROFILE_QUIET);\n\t\t\tif (!ret)\n\t\t\t\tret = asus_ec_enter_manual_locked(ec, quiet_fan_pwm);\n\t\t\tif (!ret) {\n\t\t\t\tec->quiet_emergency_active = false;\n''',
    "Quiet emergency fan-stop recovery",
)

required = (
    "A14_QUIET_FANLESS",
    "quiet_fan_pwm",
    "asus_ec_freq_qos_retry_attach",
    "asus_ec_enter_manual_locked(ec, quiet_fan_pwm)",
    "Quiet fan-stop setup failed",
    "late freq QoS attach succeeded",
    "asus_ec_force_auto_locked(ec);\n\t\t\tif (!ret)\n\t\t\t\tret = asus_ec_set_native_fan_profile(ec, EC_FW_FAN_PROFILE_TURBO)",
)
missing = [token for token in required if token not in s]
if missing:
    raise SystemExit("quiet fanless transform incomplete: " + ", ".join(missing))

p.write_text(s)
print("a14_quiet_fanless=applied")
