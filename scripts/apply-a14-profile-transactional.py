#!/usr/bin/env python3
from pathlib import Path

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

state_anchor = '\tbool quiet_emergency_active;\n'
if s.count(state_anchor) != 1:
    raise SystemExit("quiet QoS fail-safe state anchor missing")
s = s.replace(
    state_anchor,
    state_anchor + '\tbool quiet_qos_unavailable;\n',
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
					  bool previous_quiet_emergency,
					  bool previous_quiet_qos_unavailable)
{
	u8 marker;
	int ret;

	if (previous == ASUS_EC_PROFILE_CUSTOM) {
		ret = asus_ec_set_native_fan_profile(ec, EC_FW_FAN_PROFILE_NORMAL);
		asus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);
		ec->quiet_emergency_active = false;
		ec->quiet_qos_unavailable = false;
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
			ec->quiet_qos_unavailable = false;
			ec->active_profile = ASUS_EC_PROFILE_BALANCED;
			sysfs_notify(&ec->dev->kobj, NULL, "profile");
			asus_ec_notify_profile(ec);
			return ret;
		}
	}

	ec->active_profile = previous;
	ec->quiet_emergency_active = previous_quiet_emergency;
	ec->quiet_qos_unavailable = previous_quiet_qos_unavailable;
	return 0;
}

static int asus_ec_apply_profile_locked(struct asus_ec *ec,
					enum asus_ec_profile profile)
{
	enum asus_ec_profile previous = ec->active_profile;
	bool previous_quiet_emergency = ec->quiet_emergency_active;
	bool previous_quiet_qos_unavailable = ec->quiet_qos_unavailable;
	bool target_quiet_qos_unavailable;
	u8 marker;
	int restore_ret;
	int ret;

	target_quiet_qos_unavailable =
		profile == ASUS_EC_PROFILE_QUIET && !ec->num_freq_requests;

	/* A Quiet emergency is part of the effective firmware policy. Reassert
	 * Turbo on repeated writes and after resume rather than briefly dropping
	 * to native Quiet. If cpufreq QoS is unavailable, Quiet cannot honor its
	 * throttle-first contract at all, so start directly in emergency Turbo. */
	if (profile == ASUS_EC_PROFILE_QUIET &&
	    ((previous == ASUS_EC_PROFILE_QUIET && previous_quiet_emergency) ||
	     target_quiet_qos_unavailable)) {
		marker = EC_FW_FAN_PROFILE_TURBO;
	} else {
		ret = asus_ec_native_profile_marker(profile, &marker);
		if (ret)
			return ret;
	}

	ret = asus_ec_force_auto_locked(ec);
	if (ret)
		return ret;

	ret = asus_ec_set_native_fan_profile(ec, marker);
	if (ret) {
		restore_ret = asus_ec_restore_profile_locked(ec, previous,
							 previous_quiet_emergency,
							 previous_quiet_qos_unavailable);
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
								 previous_quiet_emergency,
								 previous_quiet_qos_unavailable);
			if (restore_ret)
				dev_err(ec->dev,
					"Full Speed setup failed (%d) and previous policy restore failed (%d)\n",
					ret, restore_ret);
			return ret;
		}
	}

	if (previous == ASUS_EC_PROFILE_QUIET && previous_quiet_emergency &&
	    profile != ASUS_EC_PROFILE_QUIET)
		asus_ec_emit_quiet_emergency(ec, false, asus_ec_max_temp_mc(ec),
					     "profile-change");

	ec->active_profile = profile;
	ec->quiet_qos_unavailable = target_quiet_qos_unavailable;
	ec->quiet_emergency_active =
		profile == ASUS_EC_PROFILE_QUIET &&
		((previous == ASUS_EC_PROFILE_QUIET && previous_quiet_emergency) ||
		 target_quiet_qos_unavailable);
	ec->temp_failures = 0;

	if (target_quiet_qos_unavailable &&
	    !(previous == ASUS_EC_PROFILE_QUIET &&
	      previous_quiet_emergency && previous_quiet_qos_unavailable)) {
		int temp = asus_ec_max_temp_mc(ec);

		dev_warn(ec->dev,
			 "Quiet CPU QoS unavailable; forcing Turbo cooling while Quiet remains selected\n");
		asus_ec_emit_quiet_emergency(ec, true, temp, "qos-unavailable");
	}

	/* A QoS-unavailable Quiet emergency cannot recover by temperature; there
	 * is no throttle-first mechanism to restore. Keep Turbo until the user
	 * leaves Quiet. Normal thermal emergencies retain hysteresis monitoring. */
	if (profile == ASUS_EC_PROFILE_QUIET &&
	    !ec->quiet_qos_unavailable && !ec->shutting_down)
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
    'quiet_qos_unavailable',
    'qos-unavailable',
    'asus_ec_set_pwm_both(ec, 255)',
    'profile switch failed',
)
missing = [token for token in required if token not in s]
if missing:
    raise SystemExit('transactional profile transform incomplete: ' + ', '.join(missing))

p.write_text(s)
print('a14_profile_transactional=applied')
