#!/usr/bin/env python3
"""Apply the ASUS HID feature-report Fn-lock implementation idempotently."""
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
    "\tstruct work_struct backlight_work;\n\tatomic_t desired_brightness;\n\tbool suspended;",
    "\tstruct work_struct backlight_work;\n\tstruct work_struct fnlock_work;\n\tatomic_t desired_brightness;\n\tbool fn_lock;\n\tbool suspended;",
    "Fn-lock state",
)

fnlock_work = r'''
static void asus_fnlock_work(struct work_struct *work)
{
	struct asus_hid_data *data = container_of(work, struct asus_hid_data,
						  fnlock_work);
	u8 command[A14_EC_REPORT_SIZE] = {
		A14_EC_REPORT_ID, 0xd0, 0x4e, data->fn_lock ? 1 : 0,
	};
	int ret;

	if (READ_ONCE(data->suspended))
		return;

	ret = asus_hid_raw_request(data, command, HID_REQ_SET_REPORT);
	if (ret)
		dev_warn(&data->hdev->dev, "failed to set Fn lock: %d\n", ret);
	else
		dev_info(&data->hdev->dev, "Fn lock %s\n",
			 data->fn_lock ? "enabled" : "disabled");
}

'''
text = replace_once(
    text,
    "static void asus_emit_key(struct input_dev *input, unsigned int key)\n",
    fnlock_work + "static void asus_emit_key(struct input_dev *input, unsigned int key)\n",
    "Fn-lock worker",
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
    "\tcancel_work_sync(&data->backlight_work);\n\tif (data->led_registered)",
    "\tcancel_work_sync(&data->backlight_work);\n\tcancel_work_sync(&data->fnlock_work);\n\tif (data->led_registered)",
    "Fn-lock remove cancellation",
)

path.write_text(text)
print("Fn-lock HID feature-report support applied")
