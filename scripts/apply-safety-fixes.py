#!/usr/bin/env python3
"""Apply idempotent safety fixes before building the out-of-tree modules."""
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"Cannot apply {label}: expected source block not found")
    return text.replace(old, new, 1)


ec_path = Path("asus_zenbook_a14_ec.c")
ec = ec_path.read_text()

ec = replace_once(
    ec,
    '#define DRV_NAME\t\t"asus_zenbook_a14_ec"',
    '''#define DRV_NAME\t\t"asus_zenbook_a14_ec"

/* Delay EC access after manual module loading. A warm-boot firmware state can
 * leave the shared I2C controller temporarily unavailable. */
static unsigned int probe_delay_ms = 5000;
module_param(probe_delay_ms, uint, 0644);
MODULE_PARM_DESC(probe_delay_ms,
                 "Delay before first EC access in milliseconds (default 5000)");''',
    "configurable delayed probe",
)
ec = replace_once(
    ec,
    '#define PP_MAX_FREQ_KHZ\t\t3417600\t/* uncapped (full boost) */',
    '#define PP_MAX_FREQ_KHZ\t\tFREQ_QOS_MAX_DEFAULT_VALUE',
    "dynamic maximum CPU frequency",
)
ec = replace_once(
    ec,
    '#define PP_QUIET_PWM\t0\t/* fans off — passive cooling at capped freq */',
    '#define PP_QUIET_PWM\t80\t/* low, spinning airflow; avoids unsafe fan-off operation */',
    "safe quiet fan floor",
)
ec = replace_once(
    ec,
    'static int asus_ec_probe(struct platform_device *pdev)\n{',
    '''static int asus_ec_probe(struct platform_device *pdev)
{
	/* Avoid touching the EC during early boot, when warm-boot firmware state
	 * can leave the shared I2C controller unavailable. */
	if (system_state < SYSTEM_RUNNING)
		return -EPROBE_DEFER;

	if (probe_delay_ms)
		msleep(probe_delay_ms);''',
    "late and delayed probe guard",
)
ec = replace_once(
    ec,
    '\tu8 temp, mode;',
    '\tu8 temp = 0xff, mode = 0xff;',
    "initialised probe values",
)
ec = replace_once(
    ec,
    '\t\tu8 tach0, tach1, pwm0, pwm1;',
    '\t\tu8 tach0 = 0xff, tach1 = 0xff, pwm0 = 0xff, pwm1 = 0xff;',
    "initialised fan probe values",
)
ec = replace_once(
    ec,
    '''		(void)asus_ec_read_reg(ec, EC_REG_TEMP_MAJ, EC_REG_TEMP_MIN, &temp);
		(void)asus_ec_read_reg(ec, EC_REG_FAN_MODE_MAJ,
				       EC_REG_FAN_MODE_RMIN, &mode);

		dev_info(dev,''',
    '''		(void)asus_ec_read_reg(ec, EC_REG_TEMP_MAJ, EC_REG_TEMP_MIN, &temp);
		ret = asus_ec_read_reg(ec, EC_REG_FAN_MODE_MAJ,
				       EC_REG_FAN_MODE_RMIN, &mode);
		if (ret) {
			dev_err(dev, "probe sanity read of fan mode failed: %d\\n", ret);
			i2c_unregister_device(ec->ec_client);
			i2c_put_adapter(ec->adapter);
			return ret;
		}
		if (mode != EC_FAN_MODE_AUTO && mode != EC_FAN_MODE_MANUAL) {
			dev_err(dev, "probe found unknown fan mode 0x%02x; refusing to bind\\n",
				mode);
			i2c_unregister_device(ec->ec_client);
			i2c_put_adapter(ec->adapter);
			return -EIO;
		}

		dev_info(dev,''',
    "mandatory probe mode validation",
)

shutdown_fn = r'''
static void asus_ec_shutdown(struct platform_device *pdev)
{
	struct asus_ec *ec = platform_get_drvdata(pdev);

	if (!ec)
		return;

	/* Leave firmware in a conservative, known state for warm reboot. */
	mutex_lock(&ec->mode_lock);
	(void)asus_ec_set_fan_mode(ec, EC_FAN_MODE_AUTO);
	ec->manual_active = false;
	mutex_unlock(&ec->mode_lock);
	asus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);
}

'''
ec = replace_once(
    ec,
    'static struct platform_driver asus_ec_driver = {',
    shutdown_fn + 'static struct platform_driver asus_ec_driver = {',
    "shutdown handler",
)
ec = replace_once(
    ec,
    '\t.probe\t= asus_ec_probe,\n\t.remove\t= asus_ec_remove,',
    '\t.probe\t= asus_ec_probe,\n\t.remove\t= asus_ec_remove,\n\t.shutdown = asus_ec_shutdown,',
    "shutdown registration",
)
ec = replace_once(
    ec,
    '''	/*
	 * Force fan off during suspend: switch to manual mode and set
	 * PWM to 0 on BOTH fans. The EC on A14 has no suspend signaling
	 * (0x23/0x76 doesn't exist), so it would otherwise keep the fans
	 * spinning at whatever auto-mode decided pre-suspend.
	 */
	ret = asus_ec_set_fan_mode(ec, EC_FAN_MODE_MANUAL);
	if (ret)
		dev_warn(dev, "suspend: set manual failed: %d\\n", ret);

	ret = asus_ec_set_pwm_both(ec, 0);
	if (ret)
		dev_warn(dev, "suspend: set pwm 0 (both fans) failed: %d\\n", ret);''',
    '''	/* Never leave the EC in manual/fan-off state across suspend. Firmware
	 * auto mode is the safest hand-off while the OS is asleep. */
	ret = asus_ec_set_fan_mode(ec, EC_FAN_MODE_AUTO);
	if (ret)
		dev_warn(dev, "suspend: restore auto failed: %d\\n", ret);
	else
		ec->manual_active = false;

	asus_ec_freq_qos_set(ec, FREQ_QOS_MAX_DEFAULT_VALUE);''',
    "safe suspend handoff",
)
ec_path.write_text(ec)

hid_path = Path("hid_asus_ec.c")
hid = hid_path.read_text()
hid = replace_once(
    hid,
    '\tif (message.event == PM_EVENT_SUSPEND || message.event == PM_EVENT_HIBERNATE) {\n\t\tasus_kbd_set_brightness(&data->kbd_led_cdev, LED_OFF);',
    '\tif (message.event == PM_EVENT_SUSPEND || message.event == PM_EVENT_HIBERNATE) {\n\t\tenum led_brightness saved = data->saved_brightness;\n\t\tasus_kbd_set_brightness(&data->kbd_led_cdev, LED_OFF);\n\t\tdata->saved_brightness = saved;',
    "keyboard backlight suspend preservation",
)
hid = hid.replace(
    "ASUS EC HID driver for Zenbook A14 (UX3407QA)",
    "ASUS EC HID driver for Zenbook A14 (UX3407RA/UX3407QA)",
)
hid = hid.replace(
    "Tested on ASUS Zenbook A14 (UX3407QA) only.",
    "Tested on ASUS Zenbook A14 UX3407RA and UX3407QA.",
)
hid_path.write_text(hid)
print("Safety fixes applied")
