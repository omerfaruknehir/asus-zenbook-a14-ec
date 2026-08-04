// SPDX-License-Identifier: GPL-2.0-only
/*
 * ASUS Zenbook A14 embedded-controller driver
 *
 * Supports the UX3407RA/UX3407QA family EC at address 0x5b.
 * Exposes dual-fan hwmon controls and quiet/balanced/performance profiles.
 */

#include <linux/cpufreq.h>
#include <linux/delay.h>
#include <linux/device.h>
#include <linux/hwmon.h>
#include <linux/i2c.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/kmod.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/platform_profile.h>
#include <linux/pm.h>
#include <linux/pm_qos.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/thermal.h>
#include <linux/version.h>
#include <linux/workqueue.h>

#define DRV_NAME                       "asus_zenbook_a14_ec"
#define EC_I2C_ADDR                    0x5b

#define EC_OP_ADDR                     0x10
#define EC_OP_DATA                     0x11
#define EC_CC_BUSY                     0x30
#define EC_CC_REGSEL                   0x31
#define EC_CC_DATA                     0x32

#define EC_SETTLE_INTERVAL_US           20000
#define EC_SETTLE_TIMEOUT_MS            1500
#define EC_XFER_RETRIES                 3

#define EC_REG_FAN_MODE_MAJ             0x01
#define EC_REG_FAN_MODE_RMIN            0x02
#define EC_REG_FAN_MODE_WMIN            0x82
#define EC_REG_FAN_TACH_MAJ             0x01
#define EC_REG_FAN_TACH_MIN             0x09
#define EC_REG_PWM_MAJ                  0x01
#define EC_REG_PWM_RMIN                 0x0a
#define EC_REG_PWM_WMIN                 0x8a
#define EC_REG_FAN_SEL_WMIN             0x8c
#define EC_REG_TEMP_MAJ                 0x05
#define EC_REG_TEMP_MIN                 0x02

#define EC_NUM_FANS                     2
#define EC_TACH_RPM_MULT                88
#define EC_PWM_SPIN_FLOOR               75
#define EC_FAN_MODE_AUTO                0
#define EC_FAN_MODE_MANUAL              2

#define PROFILE_SAFETY_PERIOD_MS        2000
#define PROFILE_MAX_TEMP_FAILURES       3
#define ASUS_EC_NEW_PLATFORM_PROFILE     (LINUX_VERSION_CODE >= KERNEL_VERSION(6, 14, 0))

enum asus_ec_profile {
	ASUS_EC_PROFILE_QUIET,
	ASUS_EC_PROFILE_BALANCED,
	ASUS_EC_PROFILE_PERFORMANCE,
	ASUS_EC_PROFILE_CUSTOM,
};

static char *adapter_name = "b94000.i2c";
module_param(adapter_name, charp, 0444);
MODULE_PARM_DESC(adapter_name, "Platform-device name of the EC I2C adapter");

static bool force;
module_param(force, bool, 0444);
MODULE_PARM_DESC(force, "Allow loading on an unrecognised device-tree model");

static uint probe_delay_ms = 1000;
module_param(probe_delay_ms, uint, 0644);
MODULE_PARM_DESC(probe_delay_ms, "Delay before the first EC transaction (0-10000 ms)");

static uint quiet_max_khz = 1440000;
module_param(quiet_max_khz, uint, 0644);
MODULE_PARM_DESC(quiet_max_khz, "Maximum CPU frequency used by quiet profile");

static uint performance_pwm = 220;
module_param(performance_pwm, uint, 0644);
MODULE_PARM_DESC(performance_pwm, "Fixed dual-fan PWM used by performance profile (75-255)");

static uint manual_trip_mc = 85000;
module_param(manual_trip_mc, uint, 0644);
MODULE_PARM_DESC(manual_trip_mc, "Temperature that forces manual fan control back to automatic, in mC");

struct asus_ec {
	struct device *dev;
	struct i2c_adapter *adapter;
	struct i2c_client *ec_client;
	struct device *hwmon_dev;
	struct mutex ec_lock;
	struct mutex mode_lock;
	struct delayed_work safety_work;
	bool manual_active;
	bool shutting_down;
	unsigned int temp_failures;
	enum asus_ec_profile active_profile;

	struct thermal_zone_device **zones;
	unsigned int num_zones;

	struct freq_qos_request *freq_requests;
	unsigned int num_freq_requests;

#if ASUS_EC_NEW_PLATFORM_PROFILE
	struct device *ppdev;
	struct device *(*pp_register)(struct device *, const char *, void *,
				       const struct platform_profile_ops *);
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 15, 0)
	void (*pp_remove)(struct device *);
#else
	int (*pp_remove)(struct device *);
#endif
	void (*pp_notify)(struct device *);
#endif

	u8 tx[3];
	u8 rx[1];
};

static struct platform_device *asus_ec_pdev;
static void asus_ec_notify_profile(struct asus_ec *ec);

static bool asus_a14_supported_machine(void)
{
	const char *model;

	if (force)
		return true;
	if (!of_root || of_property_read_string(of_root, "model", &model))
		return false;

	return strnstr(model, "ASUS Zenbook A14", strlen(model)) &&
	       (strnstr(model, "UX3407RA", strlen(model)) ||
		strnstr(model, "UX3407QA", strlen(model)));
}

static int asus_ec_i2c_transfer(struct asus_ec *ec, struct i2c_msg *msgs,
				int num)
{
	int ret = -EIO;
	int attempt;

	for (attempt = 0; attempt < EC_XFER_RETRIES; attempt++) {
		ret = i2c_transfer(ec->adapter, msgs, num);
		if (ret == num)
			return 0;
		if (ret >= 0)
			ret = -EIO;
		if (ret != -EAGAIN && ret != -EREMOTEIO && ret != -ENXIO &&
		    ret != -ETIMEDOUT)
			break;
		usleep_range(20000U << attempt, 30000U << attempt);
	}

	return ret;
}

/* Caller holds ec_lock. */
static int __ec_rb(struct asus_ec *ec, u8 major, u8 minor, u8 *value)
{
	static const u8 data_opcode = EC_OP_DATA;
	struct i2c_msg msgs[3];
	int ret;

	ec->tx[0] = EC_OP_ADDR;
	ec->tx[1] = major;
	ec->tx[2] = minor;

	msgs[0] = (struct i2c_msg) {
		.addr = EC_I2C_ADDR, .len = 3, .buf = ec->tx,
	};
	msgs[1] = (struct i2c_msg) {
		.addr = EC_I2C_ADDR, .len = 1, .buf = (u8 *)&data_opcode,
	};
	msgs[2] = (struct i2c_msg) {
		.addr = EC_I2C_ADDR, .flags = I2C_M_RD, .len = 1, .buf = ec->rx,
	};

	ret = asus_ec_i2c_transfer(ec, msgs, ARRAY_SIZE(msgs));
	if (!ret)
		*value = ec->rx[0];
	return ret;
}

/* Caller holds ec_lock. */
static int __ec_wb(struct asus_ec *ec, u8 major, u8 minor, u8 value)
{
	u8 data[2] = { EC_OP_DATA, value };
	struct i2c_msg msgs[2];

	ec->tx[0] = EC_OP_ADDR;
	ec->tx[1] = major;
	ec->tx[2] = minor;

	msgs[0] = (struct i2c_msg) {
		.addr = EC_I2C_ADDR, .len = 3, .buf = ec->tx,
	};
	msgs[1] = (struct i2c_msg) {
		.addr = EC_I2C_ADDR, .len = 2, .buf = data,
	};

	return asus_ec_i2c_transfer(ec, msgs, ARRAY_SIZE(msgs));
}

/* Caller holds ec_lock. */
static int __ec_settle(struct asus_ec *ec)
{
	unsigned long deadline = jiffies + msecs_to_jiffies(EC_SETTLE_TIMEOUT_MS);
	u8 busy;
	int ret;

	do {
		ret = __ec_rb(ec, 0xc4, EC_CC_BUSY, &busy);
		if (ret)
			return ret;
		if (!busy)
			return 0;
		usleep_range(EC_SETTLE_INTERVAL_US, EC_SETTLE_INTERVAL_US + 5000);
	} while (time_before(jiffies, deadline));

	return -ETIMEDOUT;
}

/* Caller holds ec_lock. */
static int __ec_cr(struct asus_ec *ec, u8 major, u8 minor, u8 *value)
{
	int ret;

	if (minor >= 0x80)
		return -EINVAL;
	ret = __ec_settle(ec);
	if (ret)
		return ret;
	ret = __ec_wb(ec, 0xc4, EC_CC_REGSEL, minor);
	if (ret)
		return ret;
	ret = __ec_wb(ec, 0xc4, EC_CC_BUSY, major);
	if (ret)
		return ret;
	ret = __ec_settle(ec);
	if (ret)
		return ret;
	ret = __ec_rb(ec, 0xc4, EC_CC_DATA, value);
	if (ret)
		return ret;
	return __ec_wb(ec, 0xc4, EC_CC_DATA, 0);
}

/* Caller holds ec_lock. */
static int __ec_cw(struct asus_ec *ec, u8 major, u8 minor, u8 value)
{
	int ret;

	ret = __ec_settle(ec);
	if (ret)
		return ret;
	ret = __ec_wb(ec, 0xc4, EC_CC_REGSEL, minor);
	if (ret)
		return ret;
	ret = __ec_wb(ec, 0xc4, EC_CC_DATA, value);
	if (ret)
		return ret;
	ret = __ec_wb(ec, 0xc4, EC_CC_BUSY, major);
	if (ret)
		return ret;
	return __ec_settle(ec);
}

static int asus_ec_read_reg(struct asus_ec *ec, u8 major, u8 minor, u8 *value)
{
	int ret;

	mutex_lock(&ec->ec_lock);
	ret = __ec_cr(ec, major, minor, value);
	mutex_unlock(&ec->ec_lock);
	return ret;
}

static int asus_ec_write_reg(struct asus_ec *ec, u8 major, u8 minor, u8 value)
{
	int ret;

	mutex_lock(&ec->ec_lock);
	ret = __ec_cw(ec, major, minor, value);
	mutex_unlock(&ec->ec_lock);
	return ret;
}

static int asus_ec_set_fan_mode(struct asus_ec *ec, u8 mode)
{
	return asus_ec_write_reg(ec, EC_REG_FAN_MODE_MAJ,
				 EC_REG_FAN_MODE_WMIN, mode);
}

static int asus_ec_set_pwm(struct asus_ec *ec, unsigned int fan, u8 pwm)
{
	int ret;

	if (fan >= EC_NUM_FANS)
		return -EINVAL;

	mutex_lock(&ec->ec_lock);
	ret = __ec_cw(ec, EC_REG_PWM_MAJ, EC_REG_FAN_SEL_WMIN, fan);
	if (!ret)
		ret = __ec_cw(ec, EC_REG_PWM_MAJ, EC_REG_PWM_WMIN, pwm);
	mutex_unlock(&ec->ec_lock);
	return ret;
}

static int asus_ec_set_pwm_both(struct asus_ec *ec, u8 pwm)
{
	int ret;

	ret = asus_ec_set_pwm(ec, 0, pwm);
	if (ret)
		return ret;
	return asus_ec_set_pwm(ec, 1, pwm);
}

static int asus_ec_read_fan_reg(struct asus_ec *ec, unsigned int fan,
				u8 minor, u8 *value)
{
	int ret;

	if (fan >= EC_NUM_FANS)
		return -EINVAL;

	mutex_lock(&ec->ec_lock);
	ret = __ec_cw(ec, EC_REG_PWM_MAJ, EC_REG_FAN_SEL_WMIN, fan);
	if (!ret)
		ret = __ec_cr(ec, EC_REG_FAN_TACH_MAJ, minor, value);
	mutex_unlock(&ec->ec_lock);
	return ret;
}

static void asus_ec_mailbox_quiesce(struct asus_ec *ec)
{
	mutex_lock(&ec->ec_lock);
	(void)__ec_wb(ec, 0xc4, EC_CC_DATA, 0);
	(void)__ec_wb(ec, 0xc4, EC_CC_BUSY, 0);
	mutex_unlock(&ec->ec_lock);
}

static const char * const asus_ec_thermal_zone_names[] = {
	"cpu0-0-top-thermal",
	"cpu1-0-top-thermal",
	"cpu2-0-top-thermal",
	"gpuss-0-thermal",
	"cpu0-thermal",
	"cpu1-thermal",
	"cpu2-thermal",
	"soc-thermal",
	"skin-thermal",
};

static int asus_ec_find_thermal_zones(struct asus_ec *ec)
{
	struct thermal_zone_device *zone;
	unsigned int i;

	ec->zones = devm_kcalloc(ec->dev, ARRAY_SIZE(asus_ec_thermal_zone_names),
				 sizeof(*ec->zones), GFP_KERNEL);
	if (!ec->zones)
		return -ENOMEM;

	for (i = 0; i < ARRAY_SIZE(asus_ec_thermal_zone_names); i++) {
		zone = thermal_zone_get_zone_by_name(asus_ec_thermal_zone_names[i]);
		if (!IS_ERR(zone))
			ec->zones[ec->num_zones++] = zone;
	}
	return 0;
}

static int asus_ec_max_temp_mc(struct asus_ec *ec)
{
	int maximum = INT_MIN;
	unsigned int i;
	u8 ec_temp;

	for (i = 0; i < ec->num_zones; i++) {
		int temp;

		if (!thermal_zone_get_temp(ec->zones[i], &temp))
			maximum = max(maximum, temp);
	}

	if (!asus_ec_read_reg(ec, EC_REG_TEMP_MAJ, EC_REG_TEMP_MIN, &ec_temp))
		maximum = max(maximum, (int)ec_temp * 1000);

	return maximum == INT_MIN ? -ENODATA : maximum;
}

static int asus_ec_freq_qos_init(struct asus_ec *ec)
{
	unsigned int capacity = num_possible_cpus();
	struct cpufreq_policy *policy;
	unsigned int cpu;
	int ret;

	ec->freq_requests = devm_kcalloc(ec->dev, capacity,
					 sizeof(*ec->freq_requests), GFP_KERNEL);
	if (!ec->freq_requests)
		return -ENOMEM;

	for_each_possible_cpu(cpu) {
		policy = cpufreq_cpu_get(cpu);
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
		cpufreq_cpu_put(policy);
		if (ret < 0) {
			dev_warn(ec->dev, "cannot register freq QoS for CPU%u: %d\n",
				 cpu, ret);
			continue;
		}
		ec->num_freq_requests++;
	}

	return 0;
}

static void asus_ec_freq_qos_set(struct asus_ec *ec, s32 max_khz)
{
	unsigned int i;

	for (i = 0; i < ec->num_freq_requests; i++) {
		int ret = freq_qos_update_request(&ec->freq_requests[i], max_khz);

		if (ret < 0)
			dev_warn_ratelimited(ec->dev,
				"cannot update freq QoS request %u: %d\n", i, ret);
	}
}

static void asus_ec_freq_qos_remove(struct asus_ec *ec)
{
	unsigned int i;

	for (i = 0; i < ec->num_freq_requests; i++)
		freq_qos_remove_request(&ec->freq_requests[i]);
	ec->num_freq_requests = 0;
}

static int asus_ec_leave_manual_locked(struct asus_ec *ec)
{
	int ret;

	if (!ec->manual_active)
		return 0;
	ret = asus_ec_set_fan_mode(ec, EC_FAN_MODE_AUTO);
	if (!ret)
		ec->manual_active = false;
	return ret;
}

static int asus_ec_enter_manual_locked(struct asus_ec *ec, u8 pwm)
{
	int ret;

	if (pwm < EC_PWM_SPIN_FLOOR)
		return -EINVAL;
	ret = asus_ec_set_fan_mode(ec, EC_FAN_MODE_MANUAL);
	if (ret)
		return ret;
	ec->manual_active = true;
	ret = asus_ec_set_pwm_both(ec, pwm);
	if (ret) {
		(void)asus_ec_set_fan_mode(ec, EC_FAN_MODE_AUTO);
		ec->manual_active = false;
	}
	return ret;
}

static int asus_ec_apply_profile_locked(struct asus_ec *ec,
					enum asus_ec_profile profile)
{
	int ret;

	switch (profile) {
	case ASUS_EC_PROFILE_QUIET:
		ret = asus_ec_leave_manual_locked(ec);
		if (ret)
			return ret;
		asus_ec_freq_qos_set(ec, quiet_max_khz);
		break;
	case ASUS_EC_PROFILE_BALANCED:
		ret = asus_ec_leave_manual_locked(ec);
		if (ret)
			return ret;
		asus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);
		break;
	case ASUS_EC_PROFILE_PERFORMANCE:
		if (performance_pwm < EC_PWM_SPIN_FLOOR || performance_pwm > 255)
			return -EINVAL;
		asus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);
		ret = asus_ec_enter_manual_locked(ec, performance_pwm);
		if (ret)
			return ret;
		break;
	default:
		return -EOPNOTSUPP;
	}

	ec->active_profile = profile;
	ec->temp_failures = 0;
	if (ec->manual_active && !ec->shutting_down)
		mod_delayed_work(system_freezable_wq, &ec->safety_work,
				 msecs_to_jiffies(PROFILE_SAFETY_PERIOD_MS));
	else
		cancel_delayed_work(&ec->safety_work);
	return 0;
}

static void asus_ec_safety_work(struct work_struct *work)
{
	struct asus_ec *ec = container_of(to_delayed_work(work),
					  struct asus_ec, safety_work);
	bool fallback = false;
	int temp;

	mutex_lock(&ec->mode_lock);
	if (!ec->manual_active || ec->shutting_down)
		goto out;

	temp = asus_ec_max_temp_mc(ec);
	if (temp < 0) {
		ec->temp_failures++;
		fallback = ec->temp_failures >= PROFILE_MAX_TEMP_FAILURES;
	} else {
		ec->temp_failures = 0;
		fallback = temp >= manual_trip_mc;
	}

	if (fallback) {
		dev_warn(ec->dev,
			 "manual fan mode safety fallback (temp=%d, read failures=%u)\n",
			 temp, ec->temp_failures);
		if (!asus_ec_leave_manual_locked(ec)) {
			ec->active_profile = ASUS_EC_PROFILE_BALANCED;
			asus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);
			sysfs_notify(&ec->dev->kobj, NULL, "profile");
			asus_ec_notify_profile(ec);
		}
		goto out;
	}

	mod_delayed_work(system_freezable_wq, &ec->safety_work,
			 msecs_to_jiffies(PROFILE_SAFETY_PERIOD_MS));
out:
	mutex_unlock(&ec->mode_lock);
}

static const char *asus_ec_profile_name(enum asus_ec_profile profile)
{
	switch (profile) {
	case ASUS_EC_PROFILE_QUIET:
		return "quiet";
	case ASUS_EC_PROFILE_BALANCED:
		return "balanced";
	case ASUS_EC_PROFILE_PERFORMANCE:
		return "performance";
	default:
		return "custom";
	}
}

static int asus_ec_profile_parse(const char *buf)
{
	if (sysfs_streq(buf, "quiet"))
		return ASUS_EC_PROFILE_QUIET;
	if (sysfs_streq(buf, "balanced"))
		return ASUS_EC_PROFILE_BALANCED;
	if (sysfs_streq(buf, "performance"))
		return ASUS_EC_PROFILE_PERFORMANCE;
	return -EINVAL;
}

static ssize_t profile_show(struct device *dev,
			    struct device_attribute *attr, char *buf)
{
	struct asus_ec *ec = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%s\n", asus_ec_profile_name(ec->active_profile));
}

static ssize_t profile_store(struct device *dev,
			     struct device_attribute *attr,
			     const char *buf, size_t count)
{
	struct asus_ec *ec = dev_get_drvdata(dev);
	int profile = asus_ec_profile_parse(buf);
	int ret;

	if (profile < 0)
		return profile;
	mutex_lock(&ec->mode_lock);
	ret = asus_ec_apply_profile_locked(ec, profile);
	mutex_unlock(&ec->mode_lock);
	if (ret)
		return ret;
	asus_ec_notify_profile(ec);
	return count;
}

static ssize_t profile_choices_show(struct device *dev,
				    struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "quiet balanced performance\n");
}

static DEVICE_ATTR_RW(profile);
static DEVICE_ATTR_RO(profile_choices);

static struct attribute *asus_ec_attrs[] = {
	&dev_attr_profile.attr,
	&dev_attr_profile_choices.attr,
	NULL,
};

static const struct attribute_group asus_ec_attr_group = {
	.attrs = asus_ec_attrs,
};

#if ASUS_EC_NEW_PLATFORM_PROFILE
static int asus_ec_pp_probe(void *drvdata, unsigned long *choices)
{
	set_bit(PLATFORM_PROFILE_QUIET, choices);
	set_bit(PLATFORM_PROFILE_BALANCED, choices);
	set_bit(PLATFORM_PROFILE_PERFORMANCE, choices);
	return 0;
}

static int asus_ec_pp_get(struct device *dev,
			  enum platform_profile_option *profile)
{
	struct asus_ec *ec = dev_get_drvdata(dev);

	switch (ec->active_profile) {
	case ASUS_EC_PROFILE_QUIET:
		*profile = PLATFORM_PROFILE_QUIET;
		break;
	case ASUS_EC_PROFILE_PERFORMANCE:
		*profile = PLATFORM_PROFILE_PERFORMANCE;
		break;
	case ASUS_EC_PROFILE_CUSTOM:
		*profile = PLATFORM_PROFILE_CUSTOM;
		break;
	default:
		*profile = PLATFORM_PROFILE_BALANCED;
		break;
	}
	return 0;
}

static int asus_ec_pp_set(struct device *dev,
			  enum platform_profile_option profile)
{
	struct asus_ec *ec = dev_get_drvdata(dev);
	enum asus_ec_profile mapped;
	int ret;

	switch (profile) {
	case PLATFORM_PROFILE_QUIET:
		mapped = ASUS_EC_PROFILE_QUIET;
		break;
	case PLATFORM_PROFILE_BALANCED:
		mapped = ASUS_EC_PROFILE_BALANCED;
		break;
	case PLATFORM_PROFILE_PERFORMANCE:
		mapped = ASUS_EC_PROFILE_PERFORMANCE;
		break;
	default:
		return -EOPNOTSUPP;
	}

	mutex_lock(&ec->mode_lock);
	ret = asus_ec_apply_profile_locked(ec, mapped);
	mutex_unlock(&ec->mode_lock);
	if (!ret)
		sysfs_notify(&ec->dev->kobj, NULL, "profile");
	return ret;
}

static const struct platform_profile_ops asus_ec_pp_ops = {
	.probe = asus_ec_pp_probe,
	.profile_get = asus_ec_pp_get,
	.profile_set = asus_ec_pp_set,
};

static void asus_ec_notify_profile(struct asus_ec *ec)
{
	if (ec->ppdev && ec->pp_notify)
		ec->pp_notify(ec->ppdev);
}

static void asus_ec_platform_profile_unregister(struct asus_ec *ec)
{
	if (ec->ppdev && ec->pp_remove) {
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 15, 0)
		ec->pp_remove(ec->ppdev);
#else
		(void)ec->pp_remove(ec->ppdev);
#endif
	}
	ec->ppdev = NULL;
	if (ec->pp_notify)
		symbol_put(platform_profile_notify);
	if (ec->pp_remove)
		symbol_put(platform_profile_remove);
	if (ec->pp_register)
		symbol_put(platform_profile_register);
	ec->pp_notify = NULL;
	ec->pp_remove = NULL;
	ec->pp_register = NULL;
}

static void asus_ec_platform_profile_register(struct asus_ec *ec)
{
	request_module("platform_profile");
	ec->pp_register = symbol_get(platform_profile_register);
	ec->pp_remove = symbol_get(platform_profile_remove);
	ec->pp_notify = symbol_get(platform_profile_notify);
	if (!ec->pp_register || !ec->pp_remove) {
		dev_info(ec->dev,
			 "platform_profile unavailable; using device profile sysfs only\n");
		asus_ec_platform_profile_unregister(ec);
		return;
	}

	ec->ppdev = ec->pp_register(ec->dev, "asus-zenbook-a14-ec", ec,
				    &asus_ec_pp_ops);
	if (IS_ERR(ec->ppdev)) {
		dev_info(ec->dev,
			 "platform_profile registration unavailable: %ld\n",
			 PTR_ERR(ec->ppdev));
		ec->ppdev = NULL;
		asus_ec_platform_profile_unregister(ec);
	}
}
#else
static void asus_ec_notify_profile(struct asus_ec *ec) { }
static void asus_ec_platform_profile_unregister(struct asus_ec *ec) { }
static void asus_ec_platform_profile_register(struct asus_ec *ec)
{
	dev_info(ec->dev,
		 "kernel platform_profile API is too old; using device profile sysfs only\n");
}
#endif

static umode_t asus_ec_hwmon_is_visible(const void *data,
					enum hwmon_sensor_types type,
					u32 attr, int channel)
{
	switch (type) {
	case hwmon_fan:
		if (channel < EC_NUM_FANS &&
		    (attr == hwmon_fan_input || attr == hwmon_fan_label))
			return 0444;
		break;
	case hwmon_pwm:
		if (channel >= EC_NUM_FANS)
			break;
		if (attr == hwmon_pwm_input)
			return 0644;
		if (attr == hwmon_pwm_enable && channel == 0)
			return 0644;
		break;
	case hwmon_temp:
		if (channel == 0 &&
		    (attr == hwmon_temp_input || attr == hwmon_temp_label))
			return 0444;
		break;
	default:
		break;
	}
	return 0;
}

static int asus_ec_hwmon_read(struct device *dev,
			      enum hwmon_sensor_types type,
			      u32 attr, int channel, long *value)
{
	struct asus_ec *ec = dev_get_drvdata(dev);
	u8 raw;
	int ret;

	switch (type) {
	case hwmon_fan:
		if (attr != hwmon_fan_input || channel >= EC_NUM_FANS)
			return -EOPNOTSUPP;
		ret = asus_ec_read_fan_reg(ec, channel, EC_REG_FAN_TACH_MIN, &raw);
		if (!ret)
			*value = (long)raw * EC_TACH_RPM_MULT;
		return ret;
	case hwmon_pwm:
		if (attr == hwmon_pwm_input && channel < EC_NUM_FANS) {
			ret = asus_ec_read_fan_reg(ec, channel, EC_REG_PWM_RMIN, &raw);
			if (!ret)
				*value = raw;
			return ret;
		}
		if (attr == hwmon_pwm_enable && channel == 0) {
			ret = asus_ec_read_reg(ec, EC_REG_FAN_MODE_MAJ,
					       EC_REG_FAN_MODE_RMIN, &raw);
			if (ret)
				return ret;
			*value = raw == EC_FAN_MODE_MANUAL ? 1 :
				 raw == EC_FAN_MODE_AUTO ? 2 : 0;
			return 0;
		}
		break;
	case hwmon_temp:
		if (attr != hwmon_temp_input || channel != 0)
			return -EOPNOTSUPP;
		ret = asus_ec_read_reg(ec, EC_REG_TEMP_MAJ, EC_REG_TEMP_MIN, &raw);
		if (!ret)
			*value = (long)raw * 1000;
		return ret;
	default:
		break;
	}
	return -EOPNOTSUPP;
}

static int asus_ec_hwmon_write(struct device *dev,
			       enum hwmon_sensor_types type,
			       u32 attr, int channel, long value)
{
	struct asus_ec *ec = dev_get_drvdata(dev);
	int ret = -EOPNOTSUPP;

	if (type != hwmon_pwm || channel >= EC_NUM_FANS)
		return -EOPNOTSUPP;

	mutex_lock(&ec->mode_lock);
	if (attr == hwmon_pwm_enable && channel == 0) {
		if (value == 1)
			ret = asus_ec_enter_manual_locked(ec,
					clamp_t(uint, performance_pwm,
						EC_PWM_SPIN_FLOOR, 255));
		else if (value == 2)
			ret = asus_ec_leave_manual_locked(ec);
		else
			ret = -EINVAL;
	} else if (attr == hwmon_pwm_input) {
		if (value < 0 || value > 255)
			ret = -EINVAL;
		else if (!ec->manual_active)
			ret = -EBUSY;
		else if (value < EC_PWM_SPIN_FLOOR)
			ret = -EINVAL;
		else
			ret = asus_ec_set_pwm(ec, channel, value);
	}
	if (!ret && attr == hwmon_pwm_enable) {
		/* Direct hwmon control is independent of the quiet profile. */
		asus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);
		ec->active_profile = value == 2 ? ASUS_EC_PROFILE_BALANCED :
					       ASUS_EC_PROFILE_CUSTOM;
	} else if (!ret && attr == hwmon_pwm_input) {
		asus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);
		ec->active_profile = ASUS_EC_PROFILE_CUSTOM;
	}
	if (!ret && ec->manual_active)
		mod_delayed_work(system_freezable_wq, &ec->safety_work,
				 msecs_to_jiffies(PROFILE_SAFETY_PERIOD_MS));
	mutex_unlock(&ec->mode_lock);
	return ret;
}

static int asus_ec_hwmon_read_string(struct device *dev,
				     enum hwmon_sensor_types type,
				     u32 attr, int channel,
				     const char **str)
{
	static const char * const fan_labels[] = { "left", "right" };

	if (type == hwmon_fan && attr == hwmon_fan_label &&
	    channel < EC_NUM_FANS) {
		*str = fan_labels[channel];
		return 0;
	}
	if (type == hwmon_temp && attr == hwmon_temp_label && channel == 0) {
		*str = "ec";
		return 0;
	}
	return -EOPNOTSUPP;
}

static const struct hwmon_ops asus_ec_hwmon_ops = {
	.is_visible = asus_ec_hwmon_is_visible,
	.read = asus_ec_hwmon_read,
	.write = asus_ec_hwmon_write,
	.read_string = asus_ec_hwmon_read_string,
};

static const struct hwmon_channel_info * const asus_ec_hwmon_info[] = {
	HWMON_CHANNEL_INFO(fan,
		HWMON_F_INPUT | HWMON_F_LABEL,
		HWMON_F_INPUT | HWMON_F_LABEL),
	HWMON_CHANNEL_INFO(pwm,
		HWMON_PWM_INPUT | HWMON_PWM_ENABLE,
		HWMON_PWM_INPUT),
	HWMON_CHANNEL_INFO(temp,
		HWMON_T_INPUT | HWMON_T_LABEL),
	NULL,
};

static const struct hwmon_chip_info asus_ec_hwmon_chip_info = {
	.ops = &asus_ec_hwmon_ops,
	.info = asus_ec_hwmon_info,
};

static struct i2c_adapter *asus_ec_find_adapter(struct device *dev)
{
	struct device *controller;
	struct i2c_adapter *adapter;

	controller = bus_find_device_by_name(&platform_bus_type, NULL, adapter_name);
	if (!controller)
		return NULL;
	if (!controller->of_node) {
		put_device(controller);
		return NULL;
	}
	adapter = of_find_i2c_adapter_by_node(controller->of_node);
	put_device(controller);
	return adapter;
}

static void asus_ec_quiesce(struct asus_ec *ec)
{
	cancel_delayed_work_sync(&ec->safety_work);
	mutex_lock(&ec->mode_lock);
	ec->shutting_down = true;
	(void)asus_ec_set_fan_mode(ec, EC_FAN_MODE_AUTO);
	ec->manual_active = false;
	asus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);
	mutex_unlock(&ec->mode_lock);
	asus_ec_mailbox_quiesce(ec);
}

static int asus_ec_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct i2c_board_info info = {
		I2C_BOARD_INFO(DRV_NAME, EC_I2C_ADDR),
	};
	struct asus_ec *ec;
	u8 mode, temp;
	int ret;

	ec = devm_kzalloc(dev, sizeof(*ec), GFP_KERNEL);
	if (!ec)
		return -ENOMEM;
	ec->dev = dev;
	mutex_init(&ec->ec_lock);
	mutex_init(&ec->mode_lock);
	INIT_DELAYED_WORK(&ec->safety_work, asus_ec_safety_work);
	ec->active_profile = ASUS_EC_PROFILE_BALANCED;
	platform_set_drvdata(pdev, ec);

	ec->adapter = asus_ec_find_adapter(dev);
	if (!ec->adapter)
		return -EPROBE_DEFER;

	ec->ec_client = i2c_new_client_device(ec->adapter, &info);
	if (IS_ERR(ec->ec_client)) {
		ret = PTR_ERR(ec->ec_client);
		i2c_put_adapter(ec->adapter);
		return ret;
	}

	msleep(min(probe_delay_ms, 10000U));
	ret = asus_ec_read_reg(ec, EC_REG_FAN_MODE_MAJ,
			       EC_REG_FAN_MODE_RMIN, &mode);
	if (ret) {
		dev_err(dev, "EC readiness check failed: %d\n", ret);
		goto err_client;
	}
	ret = asus_ec_read_reg(ec, EC_REG_TEMP_MAJ, EC_REG_TEMP_MIN, &temp);
	if (ret) {
		dev_err(dev, "EC temperature read failed: %d\n", ret);
		goto err_client;
	}

	if (mode == EC_FAN_MODE_MANUAL) {
		dev_warn(dev, "EC was left in manual mode; restoring automatic control\n");
		ret = asus_ec_set_fan_mode(ec, EC_FAN_MODE_AUTO);
		if (ret)
			goto err_client;
	}

	ret = asus_ec_find_thermal_zones(ec);
	if (ret)
		goto err_client;
	ret = asus_ec_freq_qos_init(ec);
	if (ret)
		goto err_client;

	ec->hwmon_dev = devm_hwmon_device_register_with_info(dev, DRV_NAME, ec,
						     &asus_ec_hwmon_chip_info,
						     NULL);
	if (IS_ERR(ec->hwmon_dev)) {
		ret = PTR_ERR(ec->hwmon_dev);
		goto err_qos;
	}

	ret = devm_device_add_group(dev, &asus_ec_attr_group);
	if (ret)
		goto err_qos;

	asus_ec_platform_profile_register(ec);
	dev_info(dev,
		 "ready: EC temp=%u C, profiles=quiet/balanced/performance, fans=2\n",
		 temp);
	return 0;

err_qos:
	asus_ec_freq_qos_remove(ec);
err_client:
	i2c_unregister_device(ec->ec_client);
	i2c_put_adapter(ec->adapter);
	return ret;
}

static void asus_ec_remove(struct platform_device *pdev)
{
	struct asus_ec *ec = platform_get_drvdata(pdev);

	if (!ec)
		return;
	asus_ec_quiesce(ec);
	asus_ec_platform_profile_unregister(ec);
	asus_ec_freq_qos_remove(ec);
	i2c_unregister_device(ec->ec_client);
	i2c_put_adapter(ec->adapter);
}

static void asus_ec_shutdown(struct platform_device *pdev)
{
	struct asus_ec *ec = platform_get_drvdata(pdev);

	if (ec)
		asus_ec_quiesce(ec);
}

static int asus_ec_suspend(struct device *dev)
{
	struct asus_ec *ec = dev_get_drvdata(dev);

	cancel_delayed_work_sync(&ec->safety_work);
	mutex_lock(&ec->mode_lock);
	(void)asus_ec_leave_manual_locked(ec);
	mutex_unlock(&ec->mode_lock);
	asus_ec_mailbox_quiesce(ec);
	return 0;
}

static int asus_ec_resume(struct device *dev)
{
	struct asus_ec *ec = dev_get_drvdata(dev);
	enum asus_ec_profile profile = ec->active_profile;
	int ret;

	/* A custom manual PWM is intentionally not replayed after sleep. */
	if (profile == ASUS_EC_PROFILE_CUSTOM)
		profile = ASUS_EC_PROFILE_BALANCED;

	msleep(250);
	mutex_lock(&ec->mode_lock);
	ret = asus_ec_apply_profile_locked(ec, profile);
	mutex_unlock(&ec->mode_lock);
	return ret;
}

static DEFINE_SIMPLE_DEV_PM_OPS(asus_ec_pm_ops, asus_ec_suspend, asus_ec_resume);

static struct platform_driver asus_ec_driver = {
	.driver = {
		.name = DRV_NAME,
		.pm = pm_sleep_ptr(&asus_ec_pm_ops),
	},
	.probe = asus_ec_probe,
	.remove = asus_ec_remove,
	.shutdown = asus_ec_shutdown,
};

static int __init asus_ec_init(void)
{
	int ret;

	if (!asus_a14_supported_machine()) {
		pr_err(DRV_NAME ": unsupported device-tree model; use force=1 only for development\n");
		return -ENODEV;
	}

	ret = platform_driver_register(&asus_ec_driver);
	if (ret)
		return ret;
	asus_ec_pdev = platform_device_register_simple(DRV_NAME, -1, NULL, 0);
	if (IS_ERR(asus_ec_pdev)) {
		ret = PTR_ERR(asus_ec_pdev);
		platform_driver_unregister(&asus_ec_driver);
		return ret;
	}
	return 0;
}

static void __exit asus_ec_exit(void)
{
	platform_device_unregister(asus_ec_pdev);
	platform_driver_unregister(&asus_ec_driver);
}

module_init(asus_ec_init);
module_exit(asus_ec_exit);

MODULE_AUTHOR("Sombre-Osmoze <sombre@osmoze.xyz>");
MODULE_AUTHOR("Ömer Faruk Nehir <omerfaruknehir@gmail.com>");
MODULE_DESCRIPTION("ASUS Zenbook A14 dual-fan EC and power-profile driver");
MODULE_LICENSE("GPL v2");
MODULE_ALIAS("platform:" DRV_NAME);
