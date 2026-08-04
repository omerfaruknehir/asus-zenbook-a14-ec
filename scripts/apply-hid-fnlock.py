#!/usr/bin/env python3
"""Apply ASUS Fn-lock and microphone-mute LED support idempotently."""
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"Cannot apply {label}: expected source block not found")
    return text.replace(old, new, 1)


path = Path("hid_asus_ec.c")
text = path.read_text()

text = replace_once(
    text,
    "#define A14_EC_REPORT_SIZE              64\n#define A14_EC_MAX_BACKLIGHT            3",
    "#define A14_EC_REPORT_SIZE              64\n#define A14_EC_FEATURE_REPORT_SIZE      16\n#define A14_EC_MAX_BACKLIGHT            3",
    "ASUS feature-report size",
)

text = replace_once(
    text,
    "\tstruct work_struct backlight_work;\n\tatomic_t desired_brightness;\n\tbool suspended;\n\tbool led_registered;",
    "\tstruct work_struct backlight_work;\n\tstruct work_struct fnlock_work;\n\tstruct led_classdev micmute_led;\n\tatomic_t desired_brightness;\n\tbool fn_lock;\n\tbool suspended;\n\tbool led_registered;\n\tbool micmute_led_registered;",
    "Fn-lock and microphone LED state",
)

feature_support = r'''
static int asus_short_feature_set(struct asus_hid_data *data, u8 command,
				  bool enabled)
{
	u8 buffer[A14_EC_FEATURE_REPORT_SIZE] = {
		A14_EC_REPORT_ID, 0xd0, command, enabled ? 1 : 0,
	};
	int ret;

	mutex_lock(&data->io_lock);
	ret = hid_hw_raw_request(data->hdev, A14_EC_REPORT_ID, buffer,
				 A14_EC_FEATURE_REPORT_SIZE, HID_FEATURE_REPORT,
				 HID_REQ_SET_REPORT);
	mutex_unlock(&data->io_lock);
	return ret < 0 ? ret : 0;
}

static int asus_micmute_brightness_set(struct led_classdev *led,
				       enum led_brightness brightness)
{
	struct asus_hid_data *data = container_of(led, struct asus_hid_data,
						  micmute_led);

	return asus_short_feature_set(data, 0x7c, brightness != LED_OFF);
}

static void asus_fnlock_work(struct work_struct *work)
{
	struct asus_hid_data *data = container_of(work, struct asus_hid_data,
						  fnlock_work);
	int ret;

	if (READ_ONCE(data->suspended))
		return;

	ret = asus_short_feature_set(data, 0x4e, data->fn_lock);
	if (ret)
		dev_warn(&data->hdev->dev, "failed to send Fn-lock report: %d\n", ret);
	else
		dev_info(&data->hdev->dev, "Fn-lock report sent: %s\n",
			 data->fn_lock ? "enabled" : "disabled");
}

'''
text = replace_once(
    text,
    "static void asus_emit_key(struct input_dev *input, unsigned int key)\n",
    feature_support + "static void asus_emit_key(struct input_dev *input, unsigned int key)\n",
    "Fn-lock and microphone LED feature support",
)

text = replace_once(
    text,
    "\tcase A14_EC_EVT_KEY_FN_ESC:\n\t\tasus_emit_key(data->hotkeys, KEY_FN_ESC);\n\t\treturn 1;",
    "\tcase A14_EC_EVT_KEY_FN_ESC:\n\t\tdata->fn_lock = !data->fn_lock;\n\t\tschedule_work(&data->fnlock_work);\n\t\tasus_emit_key(data->hotkeys, KEY_FN_ESC);\n\t\treturn 1;",
    "Fn+Esc toggle",
)

text = replace_once(
    text,
    "\tWRITE_ONCE(data->suspended, true);\n\tcancel_work_sync(&data->backlight_work);",
    "\tWRITE_ONCE(data->suspended, true);\n\tcancel_work_sync(&data->backlight_work);\n\tcancel_work_sync(&data->fnlock_work);",
    "Fn-lock suspend cancellation",
)

text = replace_once(
    text,
    "\tINIT_WORK(&data->backlight_work, asus_backlight_work);\n\tatomic_set(&data->desired_brightness,",
    "\tINIT_WORK(&data->backlight_work, asus_backlight_work);\n\tINIT_WORK(&data->fnlock_work, asus_fnlock_work);\n\tdata->fn_lock = false;\n\tatomic_set(&data->desired_brightness,",
    "Fn-lock worker initialization",
)

text = replace_once(
    text,
    "\tdata->led_registered = true;\n\n\tret = asus_hid_initialise(data);",
    "\tdata->led_registered = true;\n\n\tdata->micmute_led.name = \"platform::micmute\";\n\tdata->micmute_led.default_trigger = \"audio-micmute\";\n\tdata->micmute_led.max_brightness = 1;\n\tdata->micmute_led.brightness_set_blocking = asus_micmute_brightness_set;\n\tdata->micmute_led.flags = LED_CORE_SUSPENDRESUME | LED_HW_PLUGGABLE;\n\tret = led_classdev_register(&hdev->dev, &data->micmute_led);\n\tif (ret)\n\t\tgoto err_led;\n\tdata->micmute_led_registered = true;\n\n\tret = asus_hid_initialise(data);",
    "microphone-mute LED registration",
)

text = replace_once(
    text,
    "err_led:\n\tled_classdev_unregister(&data->keyboard_led);",
    "err_led:\n\tif (data->micmute_led_registered) {\n\t\tled_classdev_unregister(&data->micmute_led);\n\t\tdata->micmute_led_registered = false;\n\t}\n\tled_classdev_unregister(&data->keyboard_led);",
    "microphone LED probe cleanup",
)

text = replace_once(
    text,
    "\tcancel_work_sync(&data->backlight_work);\n\tif (data->led_registered)",
    "\tcancel_work_sync(&data->backlight_work);\n\tcancel_work_sync(&data->fnlock_work);\n\tif (data->micmute_led_registered)\n\t\tled_classdev_unregister(&data->micmute_led);\n\tif (data->led_registered)",
    "Fn-lock and microphone LED remove cleanup",
)

path.write_text(text)
print("Fn-lock 16-byte reports and microphone LED support applied")
