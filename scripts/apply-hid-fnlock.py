#!/usr/bin/env python3
"""Apply ASUS-WMI Fn-lock and microphone-mute LED support idempotently."""
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
    "#include <linux/module.h>\n",
    "#include <linux/module.h>\n#include <linux/platform_data/x86/asus-wmi.h>\n",
    "ASUS-WMI helper include",
)

text = replace_once(
    text,
    "#define A14_EC_MAX_BACKLIGHT            3\n",
    """#define A14_EC_MAX_BACKLIGHT            3

/* This is bit 0 of the DSTS value for ASUS_WMI_DEVID_FNLOCK. */
#define ASUS_WMI_FNLOCK_BIOS_DISABLED    0x00000001
""",
    "ASUS Fn-lock policy constant",
)

text = replace_once(
    text,
    "\tstruct work_struct backlight_work;\n\tatomic_t desired_brightness;\n\tbool suspended;\n\tbool led_registered;",
    """\tstruct work_struct backlight_work;
\tstruct work_struct fnlock_work;
\tstruct led_classdev micmute_led;
\tatomic_t desired_brightness;
\tatomic_t desired_fn_lock;
\tbool fn_lock;
\tbool fnlock_wmi_available;
\tbool fnlock_bios_disabled;
\tbool suspended;
\tbool led_registered;
\tbool micmute_led_registered;""",
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
	u8 session[A14_EC_REPORT_SIZE] = {
		A14_EC_REPORT_ID, 0x05, 0x20, 0x31, 0x00, 0x08,
	};
	u8 enable[A14_EC_REPORT_SIZE] = {
		A14_EC_REPORT_ID, 0xd0, 0x8f, 0x01,
	};
	int ret;

	ret = asus_hid_raw_request(data, session, HID_REQ_SET_REPORT);
	if (ret)
		return ret;
	msleep(20);
	return asus_hid_raw_request(data, enable, HID_REQ_SET_REPORT);
}

static int asus_hid_set_micmute_hw(struct asus_hid_data *data, bool enabled)
{
	u8 buffer[A14_EC_REPORT_SIZE] = {
		A14_EC_REPORT_ID, 0xd0, 0x7c, enabled ? 1 : 0,
	};

	return asus_hid_raw_request(data, buffer, HID_REQ_SET_REPORT);
}

/*
 * Linux 7.0 removed the legacy global WMI helpers.  Use the exported ASUS-WMI
 * helper API instead.  On kernels/configurations where ASUS_WMI is not
 * reachable (for example a DT-only ARM64 kernel), the header provides safe
 * inline stubs that return -ENODEV, so this module still builds and reports the
 * real limitation instead of failing DKMS compilation.
 */
static int asus_fnlock_detect_wmi(struct asus_hid_data *data)
{
	u32 state = 0;
	int ret;

	data->fnlock_wmi_available = false;
	data->fnlock_bios_disabled = false;

	ret = asus_wmi_get_devstate_dsts(ASUS_WMI_DEVID_FNLOCK, &state);
	if (ret)
		return ret;
	if (!(state & ASUS_WMI_DSTS_PRESENCE_BIT))
		return -ENODEV;

	data->fnlock_bios_disabled =
		!!(state & ASUS_WMI_FNLOCK_BIOS_DISABLED);
	if (data->fnlock_bios_disabled)
		return -EPERM;

	data->fnlock_wmi_available = true;
	return 0;
}

static int asus_fnlock_set_wmi(struct asus_hid_data *data, bool enabled)
{
	int ret;

	if (!data->fnlock_wmi_available) {
		ret = asus_fnlock_detect_wmi(data);
		if (ret)
			return ret;
	}

	ret = asus_wmi_set_devstate(ASUS_WMI_DEVID_FNLOCK, enabled, NULL);
	if (ret)
		data->fnlock_wmi_available = false;
	return ret;
}
'''
text = replace_once(text, old_init, new_init, "Linux 7.0 ASUS-WMI Fn-lock backend")

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

	ret = asus_fnlock_set_wmi(data, requested);
	if (ret) {
		atomic_set(&data->desired_fn_lock, data->fn_lock);
		if (ret == -EPERM)
			dev_warn(&data->hdev->dev,
				 "Fn Lock is disabled by BIOS/firmware policy\n");
		else if (ret == -ENODEV)
			dev_warn(&data->hdev->dev,
				 "ASUS WMI Fn-lock interface is unavailable\n");
		else
			dev_warn(&data->hdev->dev,
				 "ASUS WMI Fn-lock command failed: %d\n", ret);
		return;
	}

	data->fn_lock = requested;
	dev_info(&data->hdev->dev, "ASUS WMI Fn Lock %s\n",
		 data->fn_lock ? "enabled" : "disabled");
}

'''
text = replace_once(
    text,
    "static void asus_emit_key(struct input_dev *input, unsigned int key)\n",
    feature_support + "static void asus_emit_key(struct input_dev *input, unsigned int key)\n",
    "ASUS-WMI Fn-lock and microphone LED callbacks",
)

text = replace_once(
    text,
    "\tcase A14_EC_EVT_KEY_FN_ESC:\n\t\tasus_emit_key(data->hotkeys, KEY_FN_ESC);\n\t\treturn 1;",
    """\tcase A14_EC_EVT_KEY_FN_ESC:
\t\tatomic_set(&data->desired_fn_lock,
\t\t\t   !atomic_read(&data->desired_fn_lock));
\t\tschedule_work(&data->fnlock_work);
\t\treturn 1;""",
    "Fn+Esc ASUS-WMI toggle",
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
    """\tif (ret)
\t\treturn ret;
\tret = asus_hid_set_backlight_hw(data, level);
\tif (ret)
\t\treturn ret;
\tif (data->fn_lock)
\t\tschedule_work(&data->fnlock_work);
\treturn 0;
}""",
    "Fn-lock resume restoration",
)

text = replace_once(
    text,
    "\tINIT_WORK(&data->backlight_work, asus_backlight_work);\n\tatomic_set(&data->desired_brightness,",
    """\tINIT_WORK(&data->backlight_work, asus_backlight_work);
\tINIT_WORK(&data->fnlock_work, asus_fnlock_work);
\tdata->fn_lock = false;
\tatomic_set(&data->desired_fn_lock, 0);
\tatomic_set(&data->desired_brightness,""",
    "Fn-lock worker initialization",
)

text = replace_once(
    text,
    "\tdata->led_registered = true;\n\n\tret = asus_hid_initialise(data);",
    """\tdata->led_registered = true;

\tdata->micmute_led.name = \"platform::micmute\";
\tdata->micmute_led.default_trigger = \"audio-micmute\";
\tdata->micmute_led.max_brightness = 1;
\tdata->micmute_led.brightness_set_blocking = asus_micmute_brightness_set;
\tdata->micmute_led.flags = LED_CORE_SUSPENDRESUME | LED_HW_PLUGGABLE;
\tret = led_classdev_register(&hdev->dev, &data->micmute_led);
\tif (ret)
\t\tgoto err_led;
\tdata->micmute_led_registered = true;

\tret = asus_fnlock_detect_wmi(data);
\tif (!ret)
\t\tdev_info(&hdev->dev, \"ASUS WMI Fn Lock supported\\n\");
\telse if (ret == -EPERM)
\t\tdev_warn(&hdev->dev,
\t\t\t \"ASUS WMI Fn Lock is disabled by BIOS/firmware policy\\n\");
\telse
\t\tdev_info(&hdev->dev, \"ASUS WMI Fn Lock unavailable: %d\\n\", ret);

\tret = asus_hid_initialise(data);""",
    "microphone LED and ASUS-WMI Fn-lock registration",
)

text = replace_once(
    text,
    "err_led:\n\tled_classdev_unregister(&data->keyboard_led);",
    """err_led:
\tif (data->micmute_led_registered) {
\t\tled_classdev_unregister(&data->micmute_led);
\t\tdata->micmute_led_registered = false;
\t}
\tled_classdev_unregister(&data->keyboard_led);""",
    "microphone LED probe cleanup",
)

text = replace_once(
    text,
    "\tcancel_work_sync(&data->backlight_work);\n\tif (data->led_registered)",
    """\tcancel_work_sync(&data->backlight_work);
\tcancel_work_sync(&data->fnlock_work);
\tif (data->micmute_led_registered)
\t\tled_classdev_unregister(&data->micmute_led);
\tif (data->led_registered)""",
    "Fn-lock and microphone LED remove cleanup",
)

text = replace_once(
    text,
    "MODULE_LICENSE(\"GPL\");\n",
    "MODULE_IMPORT_NS(\"ASUS_WMI\");\nMODULE_LICENSE(\"GPL\");\n",
    "ASUS-WMI symbol namespace import",
)

path.write_text(text)
print("Linux 7.0-compatible ASUS-WMI Fn-lock and microphone LED support applied")
