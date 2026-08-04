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
    'static int asus_ec_probe(struct platform_device *pdev)\n{\n\t/* Avoid touching the EC during early boot, when warm-boot firmware state\n\t * can leave the shared I2C controller unavailable. */\n\tif (system_state < SYSTEM_RUNNING)\n\t\treturn -EPROBE_DEFER;',
    "late probe guard",
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
ec_path.write_text(ec)

hid_path = Path("hid_asus_ec.c")
hid = hid_path.read_text()
hid = replace_once(
    hid,
    '\tif (message.event == PM_EVENT_SUSPEND || message.event == PM_EVENT_HIBERNATE) {\n\t\tasus_kbd_set_brightness(&data->kbd_led_cdev, LED_OFF);',
    '\tif (message.event == PM_EVENT_SUSPEND || message.event == PM_EVENT_HIBERNATE) {\n\t\tenum led_brightness saved = data->saved_brightness;\n\t\tasus_kbd_set_brightness(&data->kbd_led_cdev, LED_OFF);\n\t\tdata->saved_brightness = saved;',
    "keyboard backlight suspend preservation",
)
hid_path.write_text(hid)
print("Safety fixes applied")
