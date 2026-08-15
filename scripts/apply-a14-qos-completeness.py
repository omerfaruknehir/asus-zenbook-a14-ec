#!/usr/bin/env python3
from pathlib import Path
import re

p = Path("asus_zenbook_a14_ec.c")
s = p.read_text()

if "A14_QOS_COMPLETE" in s:
    print("a14_qos_complete=current")
    raise SystemExit(0)

if "A14_THERMAL_SAFETY" not in s:
    raise SystemExit("complete QoS layer requires A14 thermal safety first")

# Keep the marker close to the final safety layer.
s = s.replace(
    "#define A14_THERMAL_SAFETY 1\n",
    "#define A14_THERMAL_SAFETY 1\n#define A14_QOS_COMPLETE 1\n",
    1,
)

start = s.find("static int asus_ec_freq_qos_retry_attach(struct asus_ec *ec)")
end = s.find("static void asus_ec_freq_qos_remove(struct asus_ec *ec)", start)
if start < 0 or end < 0:
    raise SystemExit("complete QoS: retry helper boundaries not found")

helper = r'''static unsigned int asus_ec_freq_qos_available_policies(void)
{
	struct cpufreq_policy *policy;
	unsigned int count = 0;
	unsigned int cpu;

	for_each_possible_cpu(cpu) {
		policy = cpufreq_cpu_get(cpu);
		if (!policy)
			continue;
		if (cpu == cpumask_first(policy->related_cpus))
			count++;
		cpufreq_cpu_put(policy);
	}
	return count;
}

static int asus_ec_freq_qos_retry_attach(struct asus_ec *ec)
{
	unsigned int expected = asus_ec_freq_qos_available_policies();
	unsigned int cpu;
	unsigned int i;
	int ret;

	if (expected && ec->num_freq_requests == expected)
		return 0;

	/* A partially populated request set is unsafe for fan-stop Quiet: one
	 * uncapped X Elite cluster can still create significant heat. Rebuild the
	 * whole set from the currently visible cpufreq policies. */
	for (i = 0; i < ec->num_freq_requests; i++)
		freq_qos_remove_request(&ec->freq_requests[i]);
	ec->num_freq_requests = 0;

	if (!expected)
		return -ENODEV;

	for_each_possible_cpu(cpu) {
		struct cpufreq_policy *policy = cpufreq_cpu_get(cpu);

		if (!policy)
			continue;
		if (cpu != cpumask_first(policy->related_cpus)) {
			cpufreq_cpu_put(policy);
			continue;
		}

		ret = freq_qos_add_request(&policy->constraints,
					   &ec->freq_requests[ec->num_freq_requests],
					   FREQ_QOS_MAX,
					   FREQ_QOS_MAX_DEFAULT_VALUE);
		if (ret >= 0)
			ec->freq_max_khz[ec->num_freq_requests] = policy->cpuinfo.max_freq;
		cpufreq_cpu_put(policy);

		if (ret < 0) {
			dev_warn(ec->dev, "late freq QoS attach failed for CPU%u: %d\n",
				 cpu, ret);
			continue;
		}
		ec->num_freq_requests++;
	}

	if (ec->num_freq_requests == expected) {
		dev_info(ec->dev,
			 "complete freq QoS coverage ready: %u/%u policies\n",
			 ec->num_freq_requests, expected);
		return 0;
	}

	dev_warn(ec->dev,
		 "incomplete freq QoS coverage: %u/%u policies; fan-stop Quiet disabled\n",
		 ec->num_freq_requests, expected);
	for (i = 0; i < ec->num_freq_requests; i++)
		freq_qos_remove_request(&ec->freq_requests[i]);
	ec->num_freq_requests = 0;
	return -ENODEV;
}

'''
s = s[:start] + helper + s[end:]

old_select = '''\tif ((profile == ASUS_EC_PROFILE_QUIET ||\n\t     profile == ASUS_EC_PROFILE_POWER_SAVER) &&\n\t    !ec->num_freq_requests)\n\t\t(void)asus_ec_freq_qos_retry_attach(ec);\n'''
new_select = '''\tif (profile == ASUS_EC_PROFILE_QUIET ||\n\t    profile == ASUS_EC_PROFILE_POWER_SAVER)\n\t\t(void)asus_ec_freq_qos_retry_attach(ec);\n'''
if s.count(old_select) != 1:
    raise SystemExit(f"complete QoS: profile-selection anchor count={s.count(old_select)}")
s = s.replace(old_select, new_select, 1)

required = (
    "A14_QOS_COMPLETE",
    "asus_ec_freq_qos_available_policies",
    "complete freq QoS coverage ready",
    "incomplete freq QoS coverage",
    "ec->num_freq_requests == expected",
    "profile == ASUS_EC_PROFILE_POWER_SAVER)\n\t\t(void)asus_ec_freq_qos_retry_attach(ec)",
)
missing = [token for token in required if token not in s]
if missing:
    raise SystemExit("complete QoS transform incomplete: " + ", ".join(missing))

p.write_text(s)
print("a14_qos_complete=applied")
