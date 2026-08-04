#!/usr/bin/env python3
"""Apply ASUS firmware Fn-lock and microphone-mute LED support idempotently."""
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
    "\tstruct work_struct backlight_work;\n\tatomic_t desired_brightness;\n\tbool suspended;\n\tbool led_registered;",
    "\tstruct work_struct backlight_work;\n\tstruct work_struct fnlock_work;\n\tstruct led_classdev micmute_led;\n\tatomic_t desired_brightness;\n\tatomic_t desired_fn_lock;\n\tbool fn_lock;\n\tbool suspended;\n\tbool led_registered;\n\tbool micmute_led_registered;",
    "Fn-lock and microphone LED state",
)

old_init = r'''static int asus_hid_initialise(struct asus_hid_data *data)
{
	u8 command[A14_EC_REPORT_SIZE] = {
		A14_EC_REPORT_ID, 0xd0, 0x8f, 0x01,
	};

	return asus_hid_raw_request(data, command, HID_REQ_SET_REPORT);
}
'''
new_init = r'''static int asus_hid_initialise(struct asus_hid_data *data)
{
	/*
	 * Qualcomm ASUS keyboards require the full firmware/session handshake
	 * before vendor commands such as Fn Lock are acted upon.  Keep the
	 * device-native 64-byte feature-report length for every stage.
	 */
	u8 session[A14_EC_REPORT_SIZE] = {
		A14_EC_REPORT_ID, 0x05, 0x20, 0x31, 0x00, 0x08,
	};
	u8 enable[A14_EC_REPORT_SIZE] = {
		A14_EC_REPORT_ID, 0xd0, 0x8f, 0x01,
	};
	int ret;

	ret = asus_hid_raw_request(data, session, HID_REQ_SET_REPORT);
	if (ret) {
		dev_warn(&data->hdev->dev,
			 "firmware session initialization failed: %d\n", ret);
		return ret;
	}
	msleep(20);

	ret = asus_hid_raw_request(data, enable, HID_REQ_SET_REPORT);
	if (ret)
		dev_warn(&data->hdev->dev,
			 "firmware command enable failed: %d\n", ret);
	return ret;
}

static int asus_hid_set_vendor_state(struct asus_hid_data *data, u8 command,
				     bool enabled)
{
	u8 buffer[A14_EC_REPORT_SIZE] = {
		A14_EC_REPORT_ID, 0xd0, command, enabled ? 1 : 0,
	};

	return asus_hid_raw_request(data, buffer, HID_REQ_SET_REPORT);
}

static int asus_hid_set_fn_lock_hw(struct asus_hid_data *data, bool enabled)
{
	return asus_hid_set_vendor_state(data, 0x4e, enabled);
}

static int asus_hid_set_micmute_hw(struct asus_hid_data *data, bool enabled)
{
	return asus_hid_set_vendor_state(data, 0x7c, enabled);
}
'''
text = replace_once(text, old_init, new_init, "complete firmware initialization")

feature_support = r'''
static int asus_micmute_brightness_set(struct led_classdev *led,
				       enum led_brightness brightness)
{
	struct asus_hid_data *data = container_of(led, struct asus_hid_data,
						  micmute_led);

	return asus_hid_set_micmute_hw(data, brightness != LED_OFF);
}

static void asus_fnlock_work(struct work_struct *work)
{
	struct asus_hid_data *data = container_of(work, struct asus_hid_data,
						  fnlock_work);
	bool requested = atomic_read(&data->desired_fn_lock);
	int ret;

	if (READ_ONCE(data->suspended))
		return;

	/* Re-establish the firmware command session before changing Fn mode. */
	ret = asus_hid_initialise(data);
	if (ret)
		return;

	ret = asus_hid_set_fn_lock_hw(data, requested);
	if (ret) {
		dev_warn(&data->hdev->dev,
			 "firmware Fn-lock command failed: %d\n", ret);
		atomic_set(&data->desired_fn_lock, data->fn_lock);
		return;
	}

	data->fn_lock = requested;
	dev_info(&data->hdev->dev, "firmware Fn-lock command sent: %s\n",
		 data->fn_lock ? "enabled" : "disabled");
}

'''
text = replace_once(
    text,
    "static void asus_emit_key(struct input_dev *input, unsigned int key)\n",
    feature_support + "static void asus_emit_key(struct input_dev *input, unsigned int key)\n",
    "firmware Fn-lock and microphone LED callbacks",
)

text = replace_once(
    text,
    "\tcase A14_EC_EVT_KEY_FN_ESC:\n\t\tasus_emit_key(data->hotkeys, KEY_FN_ESC);\n\t\treturn 1;",
    "\tcase A14_EC_EVT_KEY_FN_ESC:\n\t\tatomic_set(&data->desired_fn_lock,\n\t\t\t   !atomic_read(&data->desired_fn_lock));\n\t\tschedule_work(&data->fnlock_work);\n\t\tasus_emit_key(data->hotkeys, KEY_FN_ESC);\n\t\treturn 1;",
    "Fn+Esc firmware toggle",
)

text = replace_once(
    text,
    "\tWRITE_ONCE(data->suspended, true);\n\tcancel_work_sync(&data->backlight_work);",
    "\tWRITE_ONCE(data->suspended, true);\n\tcancel_work_sync(&data->backlight_work);\n\tcancel_work_sync(&data->fnlock_work);",
    "Fn-lock suspend cancellation",
)

text = replace_once(
    text,
    "\tif (ret)\n\t\treturn ret;\n\treturn asus_hid_set_backlight_hw(data, level);\n}",
    "\tif (ret)\n\t\treturn ret;\n\tret = asus_hid_set_backlight_hw(data, level);\n\tif (ret)\n\t\treturn ret;\n\tret = asus_hid_set_fn_lock_hw(data,\n\t\t\t\t      atomic_read(&data->desired_fn_lock));\n\tif (!ret)\n\t\tdata->fn_lock = atomic_read(&data->desired_fn_lock);\n\treturn ret;\n}",
    "Fn-lock resume restoration",
)

text = replace_once(
    text,
    "\tINIT_WORK(&data->backlight_work, asus_backlight_work);\n\tatomic_set(&data->desired_brightness,",
    "\tINIT_WORK(&data->backlight_work, asus_backlight_work);\n\tINIT_WORK(&data->fnlock_work, asus_fnlock_work);\n\tdata->fn_lock = false;\n\tatomic_set(&data->desired_fn_lock, 0);\n\tatomic_set(&data->desired_brightness,",
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
print("64-byte firmware Fn-lock handshake and microphone LED support applied")
