#!/usr/bin/env python3
"""Apply ASUS WMI Fn-lock and microphone-mute LED support idempotently."""
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
    "#include <linux/delay.h>\n#include <linux/hid.h>",
    "#include <linux/acpi.h>\n#include <linux/delay.h>\n#include <linux/hid.h>",
    "ACPI include",
)
text = replace_once(
    text,
    "#include <linux/workqueue.h>\n",
    "#include <linux/workqueue.h>\n#include <linux/wmi.h>\n",
    "WMI include",
)

text = replace_once(
    text,
    "#define A14_EC_MAX_BACKLIGHT            3\n",
    """#define A14_EC_MAX_BACKLIGHT            3

#define ASUS_WMI_MGMT_GUID              \"97845ED0-4E6D-11DE-8A39-0800200C9A66\"
#define ASUS_WMI_METHODID_DSTS           0x53545344
#define ASUS_WMI_METHODID_DEVS           0x53564544
#define ASUS_WMI_DEVID_FNLOCK            0x00100023
#define ASUS_WMI_DSTS_PRESENCE_BIT       0x00010000
#define ASUS_WMI_FNLOCK_BIOS_DISABLED    BIT(0)
#define ASUS_WMI_UNSUPPORTED_METHOD      0xfffffffe
""",
    "ASUS WMI constants",
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

struct asus_wmi_args {
	u32 arg0;
	u32 arg1;
	u32 arg2;
} __packed;

static int asus_wmi_evaluate(u32 method_id, u32 arg0, u32 arg1, u32 *retval)
{
	struct asus_wmi_args args = {
		.arg0 = arg0,
		.arg1 = arg1,
	};
	struct acpi_buffer input = { sizeof(args), &args };
	struct acpi_buffer output = { ACPI_ALLOCATE_BUFFER, NULL };
	union acpi_object *obj;
	acpi_status status;
	u32 value;

	status = wmi_evaluate_method(ASUS_WMI_MGMT_GUID, 0, method_id,
				     &input, &output);
	if (ACPI_FAILURE(status))
		return -EIO;

	obj = output.pointer;
	if (!obj || obj->type != ACPI_TYPE_INTEGER) {
		kfree(obj);
		return -ENODATA;
	}

	value = (u32)obj->integer.value;
	kfree(obj);
	if (value == ASUS_WMI_UNSUPPORTED_METHOD)
		return -ENODEV;
	if (retval)
		*retval = value;
	return 0;
}

static int asus_fnlock_detect_wmi(struct asus_hid_data *data)
{
	u32 state;
	int ret;

	data->fnlock_wmi_available = false;
	data->fnlock_bios_disabled = false;

	if (!wmi_has_guid(ASUS_WMI_MGMT_GUID))
		return -ENODEV;

	ret = asus_wmi_evaluate(ASUS_WMI_METHODID_DSTS,
				ASUS_WMI_DEVID_FNLOCK, 0, &state);
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
	u32 retval = 0;
	int ret;

	if (!data->fnlock_wmi_available) {
		ret = asus_fnlock_detect_wmi(data);
		if (ret)
			return ret;
	}

	ret = asus_wmi_evaluate(ASUS_WMI_METHODID_DEVS,
				ASUS_WMI_DEVID_FNLOCK, enabled, &retval);
	if (ret)
		data->fnlock_wmi_available = false;
	return ret;
}
'''
text = replace_once(text, old_init, new_init, "WMI Fn-lock backend")

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
    "WMI Fn-lock and microphone LED callbacks",
)

text = replace_once(
    text,
    "\tcase A14_EC_EVT_KEY_FN_ESC:\n\t\tasus_emit_key(data->hotkeys, KEY_FN_ESC);\n\t\treturn 1;",
    """\tcase A14_EC_EVT_KEY_FN_ESC:
\t\tatomic_set(&data->desired_fn_lock,
\t\t\t   !atomic_read(&data->desired_fn_lock));
\t\tschedule_work(&data->fnlock_work);
\t\treturn 1;""",
    "Fn+Esc WMI toggle",
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
    "microphone LED and WMI Fn-lock registration",
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

path.write_text(text)
print("ASUS WMI firmware Fn-lock and microphone LED support applied")
