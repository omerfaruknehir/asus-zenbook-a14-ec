#!/usr/bin/env python3
from pathlib import Path
import re

p = Path("asus_zenbook_a14_ec.c")
s = p.read_text()

if "A14_PROFILE_TRANSACTIONAL" in s:
    print("a14_profile_transactional=current")
    raise SystemExit(0)

if "A14_PROFILE_EMERGENCY_NOTIFY" not in s:
    raise SystemExit("transactional profile layer requires emergency-notification layer first")

s = s.replace(
    '#define A14_PROFILE_EMERGENCY_NOTIFY 1\n',
    '#define A14_PROFILE_EMERGENCY_NOTIFY 1\n#define A14_PROFILE_TRANSACTIONAL 1\n',
    1,
)

start = s.find('static int asus_ec_apply_profile_locked(struct asus_ec *ec,')
end = s.find('static void asus_ec_safety_work(struct work_struct *work)', start)
if start < 0 or end < 0:
    raise SystemExit("transactional profile application: function boundaries not found")

replacement = r'''static void asus_ec_set_qos_for_profile(struct asus_ec *ec,
					 enum asus_ec_profile profile)
{
	switch (profile) {
	case ASUS_EC_PROFILE_QUIET:
		asus_ec_freq_qos_set_percent(ec, quiet_max_percent);
		break;
	case ASUS_EC_PROFILE_POWER_SAVER:
		asus_ec_freq_qos_set_percent(ec, power_saver_max_percent);
		break;
	default:
		asus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);
		break;
	}
}

/* Caller holds mode_lock and has already returned low-level fan ownership to
 * firmware AUTO. Restore the complete previous policy after a failed profile
 * transition. CUSTOM cannot be reconstructed because arbitrary per-fan PWM is
 * not retained; in that one case fail safe to Balanced/Normal. */
static int asus_ec_restore_profile_locked(struct asus_ec *ec,
					  enum asus_ec_profile previous,
					  bool previous_quiet_emergency)
{
	u8 marker;
	int ret;

	if (previous == ASUS_EC_PROFILE_CUSTOM) {
		ret = asus_ec_set_native_fan_profile(ec, EC_FW_FAN_PROFILE_NORMAL);
		asus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);
		ec->quiet_emergency_active = false;
		ec->active_profile = ASUS_EC_PROFILE_BALANCED;
		sysfs_notify(&ec->dev->kobj, NULL, "profile");
		asus_ec_notify_profile(ec);
		return ret;
	}

	if (previous == ASUS_EC_PROFILE_QUIET && previous_quiet_emergency)
		marker = EC_FW_FAN_PROFILE_TURBO;
	else {
		ret = asus_ec_native_profile_marker(previous, &marker);
		if (ret)
			return ret;
	}

	ret = asus_ec_set_native_fan_profile(ec, marker);
	if (ret)
		return ret;
	asus_ec_set_qos_for_profile(ec, previous);

	if (previous == ASUS_EC_PROFILE_FULL_SPEED) {
		ret = asus_ec_enter_manual_locked(ec, 255);
		if (ret) {
			(void)asus_ec_force_auto_locked(ec);
			(void)asus_ec_set_native_fan_profile(ec, EC_FW_FAN_PROFILE_NORMAL);
			asus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);
			ec->quiet_emergency_active = false;
			ec->active_profile = ASUS_EC_PROFILE_BALANCED;
			sysfs_notify(&ec->dev->kobj, NULL, "profile");
			asus_ec_notify_profile(ec);
			return ret;
		}
	}

	ec->active_profile = previous;
	ec->quiet_emergency_active = previous_quiet_emergency;
	return 0;
}

static int asus_ec_apply_profile_locked(struct asus_ec *ec,
					enum asus_ec_profile profile)
{
	enum asus_ec_profile previous = ec->active_profile;
	bool previous_quiet_emergency = ec->quiet_emergency_active;
	u8 marker;
	int restore_ret;
	int ret;

	/* Repeated writes from desktop tools are common. Keep them idempotent,
	 * especially while Quiet emergency Turbo cooling is active. */
	if (profile == previous && profile != ASUS_EC_PROFILE_CUSTOM) {
		if (profile == ASUS_EC_PROFILE_FULL_SPEED) {
			asus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);
			if (ec->manual_active)
				return asus_ec_set_pwm_both(ec, 255);
		} else {
			asus_ec_set_qos_for_profile(ec, profile);
			return 0;
		}
	}

	ret = asus_ec_native_profile_marker(profile, &marker);
	if (ret)
		return ret;

	ret = asus_ec_force_auto_locked(ec);
	if (ret)
		return ret;

	ret = asus_ec_set_native_fan_profile(ec, marker);
	if (ret) {
		restore_ret = asus_ec_restore_profile_locked(ec, previous,
							 previous_quiet_emergency);
		if (restore_ret)
			dev_err(ec->dev,
				"profile switch failed (%d) and previous policy restore failed (%d)\n",
				ret, restore_ret);
		return ret;
	}

	asus_ec_set_qos_for_profile(ec, profile);

	if (profile == ASUS_EC_PROFILE_FULL_SPEED) {
		ret = asus_ec_enter_manual_locked(ec, 255);
		if (ret) {
			(void)asus_ec_force_auto_locked(ec);
			restore_ret = asus_ec_restore_profile_locked(ec, previous,
								 previous_quiet_emergency);
			if (restore_ret)
				dev_err(ec->dev,
					"Full Speed setup failed (%d) and previous policy restore failed (%d)\n",
					ret, restore_ret);
			return ret;
		}
	}

	if (previous == ASUS_EC_PROFILE_QUIET && previous_quiet_emergency &&
	    profile != ASUS_EC_PROFILE_QUIET) {
		ec->quiet_emergency_active = false;
		asus_ec_emit_quiet_emergency(ec, false, asus_ec_max_temp_mc(ec));
	} else {
		ec->quiet_emergency_active = false;
	}

	ec->active_profile = profile;
	ec->temp_failures = 0;
	if (profile == ASUS_EC_PROFILE_QUIET && !ec->shutting_down)
		mod_delayed_work(system_freezable_wq, &ec->safety_work,
				 msecs_to_jiffies(PROFILE_SAFETY_PERIOD_MS));
	else
		cancel_delayed_work(&ec->safety_work);
	return 0;
}

'''

s = s[:start] + replacement + s[end:]

required = (
    'A14_PROFILE_TRANSACTIONAL',
    'asus_ec_restore_profile_locked',
    'asus_ec_set_qos_for_profile',
    'previous_quiet_emergency',
    'asus_ec_set_pwm_both(ec, 255)',
    'profile switch failed',
)
missing = [token for token in required if token not in s]
if missing:
    raise SystemExit('transactional profile transform incomplete: ' + ', '.join(missing))

p.write_text(s)
print('a14_profile_transactional=applied')
