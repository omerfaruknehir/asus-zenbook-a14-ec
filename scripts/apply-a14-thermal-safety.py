#!/usr/bin/env python3
from pathlib import Path

p = Path("asus_zenbook_a14_ec.c")
s = p.read_text()

if "A14_THERMAL_SAFETY" in s:
    print("a14_thermal_safety=current")
    raise SystemExit(0)

if "A14_QUIET_FANLESS" not in s:
    raise SystemExit("A14 thermal safety layer requires Quiet fanless layer first")

old = '''static const char * const asus_ec_thermal_zone_names[] = {\n\t"cpu0-thermal",\n\t"cpu1-thermal",\n\t"cpu2-thermal",\n\t"soc-thermal",\n\t"skin-thermal",\n};\n'''

# These names were recovered from the UX3407RA's actual /sys/class/thermal
# inventory. Keep underscore aliases as well because older Qualcomm DT/thermal
# drivers have exposed the same zones with underscores on adjacent builds.
names = []
for cluster in range(3):
    for core in range(4):
        for side in ("top", "btm"):
            names.append(f'cpu{cluster}-{core}-{side}-thermal')
            names.append(f'cpu{cluster}_{core}_{side}_thermal')
    for side in ("top", "btm"):
        names.append(f'cpuss{cluster}-{side}-thermal')
        names.append(f'cpuss{cluster}_{side}_thermal')

# Retain older generic/fallback names too; missing zones are harmless because
# thermal_zone_get_zone_by_name() simply returns an error pointer.
names += ["cpu0-thermal", "cpu1-thermal", "cpu2-thermal", "soc-thermal", "skin-thermal"]

body = '#define A14_THERMAL_SAFETY 1\n\nstatic const char * const asus_ec_thermal_zone_names[] = {\n'
body += ''.join(f'\t"{name}",\n' for name in names)
body += '};\n'

if s.count(old) != 1:
    raise SystemExit(f"A14 thermal zone table: expected one source anchor, found {s.count(old)}")
s = s.replace(old, body, 1)

old_find = '''\tfor (i = 0; i < ARRAY_SIZE(asus_ec_thermal_zone_names); i++) {\n\t\tzone = thermal_zone_get_zone_by_name(asus_ec_thermal_zone_names[i]);\n\t\tif (!IS_ERR(zone))\n\t\t\tec->zones[ec->num_zones++] = zone;\n\t}\n\treturn 0;\n}\n'''
new_find = '''\tfor (i = 0; i < ARRAY_SIZE(asus_ec_thermal_zone_names); i++) {\n\t\tzone = thermal_zone_get_zone_by_name(asus_ec_thermal_zone_names[i]);\n\t\tif (!IS_ERR(zone))\n\t\t\tec->zones[ec->num_zones++] = zone;\n\t}\n\n\tif (!ec->num_zones)\n\t\tdev_warn(ec->dev,\n\t\t\t "no A14 CPU thermal zones were found; Quiet fan-stop is disabled by fail-safe\\n");\n\telse\n\t\tdev_info(ec->dev, "monitoring %u A14 CPU thermal zones\\n",\n\t\t\t ec->num_zones);\n\treturn 0;\n}\n'''
if s.count(old_find) != 1:
    raise SystemExit(f"A14 thermal discovery diagnostics: expected one source anchor, found {s.count(old_find)}")
s = s.replace(old_find, new_find, 1)

# Fan-stop Quiet requires BOTH cpufreq QoS and at least one real CPU thermal
# zone. If either prerequisite is absent, remain in firmware-owned Turbo and
# report an emergency rather than making the machine silent blindly.
old_target = '''\ttarget_quiet_qos_unavailable =\n\t\tprofile == ASUS_EC_PROFILE_QUIET && !ec->num_freq_requests;\n'''
new_target = '''\ttarget_quiet_qos_unavailable =\n\t\tprofile == ASUS_EC_PROFILE_QUIET &&\n\t\t(!ec->num_freq_requests || !ec->num_zones);\n'''
if s.count(old_target) != 1:
    raise SystemExit(f"Quiet safety prerequisite: expected one source anchor, found {s.count(old_target)}")
s = s.replace(old_target, new_target, 1)

# The late-QoS recovery path must remain fail-closed when the temperature
# prerequisite is absent. A successful QoS retry alone is not enough to permit
# zero fan PWM.
old_recovery = '''\t\tif (ec->quiet_qos_unavailable) {\n\t\t\tret = asus_ec_freq_qos_retry_attach(ec);\n\t\t\tif (!ret) {\n'''
new_recovery = '''\t\tif (ec->quiet_qos_unavailable) {\n\t\t\tret = ec->num_zones ? asus_ec_freq_qos_retry_attach(ec) : -ENODEV;\n\t\t\tif (!ret) {\n'''
if s.count(old_recovery) != 1:
    raise SystemExit(f"Quiet late-recovery safety: expected one source anchor, found {s.count(old_recovery)}")
s = s.replace(old_recovery, new_recovery, 1)

# Make the diagnostic reason truthful if the CPU-temperature safety sensor is
# what is missing.
old_warn = '''\t\tdev_warn(ec->dev,\n\t\t\t "Quiet CPU QoS unavailable; forcing Turbo cooling while Quiet remains selected\\n");\n\t\tasus_ec_emit_quiet_emergency(ec, true, temp, "qos-unavailable");\n'''
new_warn = '''\t\tif (!ec->num_freq_requests)\n\t\t\tdev_warn(ec->dev,\n\t\t\t\t "Quiet CPU QoS unavailable; forcing Turbo cooling while Quiet remains selected\\n");\n\t\telse\n\t\t\tdev_warn(ec->dev,\n\t\t\t\t "Quiet CPU thermal safety zones unavailable; forcing Turbo cooling while Quiet remains selected\\n");\n\t\tasus_ec_emit_quiet_emergency(ec, true, temp,\n\t\t\t\t\t     ec->num_freq_requests ? "thermal-sensor-unavailable" :\n\t\t\t\t\t     "qos-unavailable");\n'''
if s.count(old_warn) != 1:
    raise SystemExit(f"Quiet safety prerequisite notification: expected one source anchor, found {s.count(old_warn)}")
s = s.replace(old_warn, new_warn, 1)

required = (
    "A14_THERMAL_SAFETY",
    '"cpu0-0-top-thermal"',
    '"cpu1-3-btm-thermal"',
    '"cpu2-3-btm-thermal"',
    '"cpuss0-top-thermal"',
    '"cpuss1-btm-thermal"',
    '"cpuss2-top-thermal"',
    "monitoring %u A14 CPU thermal zones",
    "!ec->num_freq_requests || !ec->num_zones",
    "ret = ec->num_zones ? asus_ec_freq_qos_retry_attach(ec) : -ENODEV",
    "thermal-sensor-unavailable",
)
missing = [token for token in required if token not in s]
if missing:
    raise SystemExit("A14 thermal safety transform incomplete: " + ", ".join(missing))

p.write_text(s)
print("a14_thermal_safety=applied")
