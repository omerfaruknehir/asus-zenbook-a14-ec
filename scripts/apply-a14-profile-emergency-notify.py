#!/usr/bin/env python3
from pathlib import Path

p = Path("asus_zenbook_a14_ec.c")
s = p.read_text()

if "A14_PROFILE_EMERGENCY_NOTIFY" in s:
    print("a14_profile_emergency_notify=current")
    raise SystemExit(0)


def once(old: str, new: str, label: str) -> None:
    global s
    count = s.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one source anchor, found {count}")
    s = s.replace(old, new, 1)


once(
    '#include <linux/kernel.h>\n',
    '#include <linux/kernel.h>\n#include <linux/kobject.h>\n',
    'kobject include',
)

once(
    '#define A14_PROFILE_POLICY_V2 1\n',
    '#define A14_PROFILE_POLICY_V2 1\n#define A14_PROFILE_EMERGENCY_NOTIFY 1\n',
    'emergency feature marker',
)

# Emit both a pollable sysfs notification and a normal KOBJ_CHANGE uevent.
# Include a reason so userspace never claims CPU throttling is active if the
# emergency was caused by unavailable cpufreq QoS rather than temperature.
anchor = '''static int asus_ec_apply_profile_locked(struct asus_ec *ec,\n'''
helper = '''static void asus_ec_emit_quiet_emergency(struct asus_ec *ec,\n\t\t\t\t\t bool active, int temp_mc,\n\t\t\t\t\t const char *reason)\n{\n\tchar state_env[32];\n\tchar temp_env[32];\n\tchar reason_env[64];\n\tchar *envp[] = { state_env, temp_env, reason_env, "A14_PROFILE=quiet", NULL };\n\n\tsnprintf(state_env, sizeof(state_env), "A14_QUIET_EMERGENCY=%u", active ? 1 : 0);\n\tsnprintf(temp_env, sizeof(temp_env), "A14_TEMP_MC=%d", temp_mc);\n\tsnprintf(reason_env, sizeof(reason_env), "A14_EMERGENCY_REASON=%s", reason ?: "unknown");\n\tsysfs_notify(&ec->dev->kobj, NULL, "quiet_emergency");\n\tkobject_uevent_env(&ec->dev->kobj, KOBJ_CHANGE, envp);\n}\n\n'''
if s.count(anchor) != 1:
    raise SystemExit("emergency helper: insertion anchor missing")
s = s.replace(anchor, helper + anchor, 1)

# This temporary idempotence guard is superseded by the final transactional
# layer. It is still useful if the transforms are inspected individually.
once(
    '''\tret = asus_ec_native_profile_marker(profile, &marker);\n\tif (ret)\n\t\treturn ret;\n\t(void)asus_ec_native_profile_marker(previous, &previous_marker);\n\n\t/* Every named policy starts from firmware-owned AUTO. Full Speed takes\n''',
    '''\tif (profile == ASUS_EC_PROFILE_QUIET &&\n\t    previous == ASUS_EC_PROFILE_QUIET &&\n\t    ec->quiet_emergency_active) {\n\t\tasus_ec_freq_qos_set_percent(ec, quiet_max_percent);\n\t\treturn 0;\n\t}\n\n\tret = asus_ec_native_profile_marker(profile, &marker);\n\tif (ret)\n\t\treturn ret;\n\t(void)asus_ec_native_profile_marker(previous, &previous_marker);\n\n\t/* Every named policy starts from firmware-owned AUTO. Full Speed takes\n''',
    'idempotent repeated Quiet write',
)

once(
    '''\tec->quiet_emergency_active = false;\n\tswitch (profile) {\n''',
    '''\tif (ec->quiet_emergency_active && profile != ASUS_EC_PROFILE_QUIET)\n\t\tasus_ec_emit_quiet_emergency(ec, false, asus_ec_max_temp_mc(ec),\n\t\t\t\t\t     "profile-change");\n\tec->quiet_emergency_active = false;\n\tswitch (profile) {\n''',
    'profile-switch emergency clear',
)

once(
    '''\t\t\tif (!ret) {\n\t\t\t\tec->quiet_emergency_active = true;\n\t\t\t\tdev_warn(ec->dev,\n''',
    '''\t\t\tif (!ret) {\n\t\t\t\tec->quiet_emergency_active = true;\n\t\t\t\tasus_ec_emit_quiet_emergency(ec, true, temp, "thermal");\n\t\t\t\tdev_warn(ec->dev,\n''',
    'emergency engaged event',
)

once(
    '''\t\t\tif (!ret) {\n\t\t\t\tec->quiet_emergency_active = false;\n\t\t\t\tdev_info(ec->dev,\n''',
    '''\t\t\tif (!ret) {\n\t\t\t\tec->quiet_emergency_active = false;\n\t\t\t\tasus_ec_emit_quiet_emergency(ec, false, temp, "recovered");\n\t\t\t\tdev_info(ec->dev,\n''',
    'emergency cleared event',
)

profile_show_anchor = '''static ssize_t profile_show(struct device *dev,\n'''
emergency_show = '''static ssize_t quiet_emergency_show(struct device *dev,\n\t\t\t\t    struct device_attribute *attr, char *buf)\n{\n\tstruct asus_ec *ec = dev_get_drvdata(dev);\n\n\treturn sysfs_emit(buf, "%u\\n", ec->quiet_emergency_active ? 1 : 0);\n}\n\n'''
if s.count(profile_show_anchor) != 1:
    raise SystemExit("quiet_emergency sysfs show: insertion anchor missing")
s = s.replace(profile_show_anchor, emergency_show + profile_show_anchor, 1)

once(
    '''static DEVICE_ATTR_RW(profile);\nstatic DEVICE_ATTR_RO(profile_choices);\n''',
    '''static DEVICE_ATTR_RW(profile);\nstatic DEVICE_ATTR_RO(profile_choices);\nstatic DEVICE_ATTR_RO(quiet_emergency);\n''',
    'quiet_emergency attribute declaration',
)

once(
    '''\t&dev_attr_profile.attr,\n\t&dev_attr_profile_choices.attr,\n\tNULL,\n''',
    '''\t&dev_attr_profile.attr,\n\t&dev_attr_profile_choices.attr,\n\t&dev_attr_quiet_emergency.attr,\n\tNULL,\n''',
    'quiet_emergency attribute group',
)

required = (
    'A14_PROFILE_EMERGENCY_NOTIFY',
    'kobject_uevent_env',
    'A14_QUIET_EMERGENCY=',
    'A14_EMERGENCY_REASON=',
    'DEVICE_ATTR_RO(quiet_emergency)',
    'asus_ec_emit_quiet_emergency(ec, true, temp, "thermal")',
    'asus_ec_emit_quiet_emergency(ec, false, temp, "recovered")',
)
missing = [token for token in required if token not in s]
if missing:
    raise SystemExit('emergency notification transform incomplete: ' + ', '.join(missing))

p.write_text(s)
print('a14_profile_emergency_notify=applied')
