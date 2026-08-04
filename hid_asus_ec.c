// SPDX-License-Identifier: GPL-2.0-or-later
/* ASUS Zenbook A14 EC HID driver: keyboard backlight and Fn hotkeys. */

#include <linux/delay.h>
#include <linux/hid.h>
#include <linux/input.h>
#include <linux/leds.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/pm.h>
#include <linux/slab.h>
#include <linux/workqueue.h>

#define ASUS_VENDOR_ID                  0x0b05
#define ASUS_PRODUCT_ID                 0x0220
#define A14_EC_REPORT_ID                0x5a
#define A14_EC_REPORT_SIZE              64
#define A14_EC_MAX_BACKLIGHT            3

#ifndef KEY_PERFORMANCE
#define KEY_PERFORMANCE KEY_PROG2
#endif

#define A14_EC_EVT_KEY_FN_ESC           0x4e
#define A14_EC_EVT_KEY_FN_F4            0xc7
#define A14_EC_EVT_KEY_FN_F5            0x10
#define A14_EC_EVT_KEY_FN_F6            0x20
#define A14_EC_EVT_KEY_FN_F8            0x7e
#define A14_EC_EVT_KEY_FN_F9            0x7c
#define A14_EC_EVT_KEY_FN_F10           0x85
#define A14_EC_EVT_KEY_FN_F11           0x6b
#define A14_EC_EVT_KEY_FN_F12           0x86
#define A14_EC_EVT_KEY_FN_F             0x9d

static uint initial_brightness = 1;
module_param(initial_brightness, uint, 0644);
MODULE_PARM_DESC(initial_brightness, "Initial keyboard-backlight level (0-3)");

static bool enable_debug_commands;
module_param(enable_debug_commands, bool, 0600);
MODULE_PARM_DESC(enable_debug_commands, "Expose root-only raw EC HID command sysfs+");

struct asus_hid_data {
	struct hid_device *hdev;
	struct led_classdev keyboard_led;
	struct input_dev *hotkeys;
	struct mutex io_lock;
	struct work_struct backlight_work;
	atomic_t desired_brightness;
	bool suspended;
	bool led_registered;
	bool debug_attribute_created;
	u8 debug_response[A14_EC_REPORT_SIZE];
};

static int asus_hid_raw_request(struct asus_hid_data *data, u8 *buffer,
				int request)
{
	int ret;

	mutex_lock(&data->io_lock);
	ret = hid_hw_raw_request(data->hdev, A14_EC_REPORT_ID, buffer,
				 A14_EC_REPORT_SIZE, HID_FEATURE_REPORT, request);
	mutex_unlock(&data->io_lock);
	return ret < 0 ? ret : 0;
}

static int asus_hid_initialise(struct asus_hid_data *data)
{
	u8 command[A14_EC_REPORT_SIZE] = {
		A14_EC_REPORT_ID, 0xd0, 0x8f, 0x01,
	};

	return asus_hid_raw_request(data, command, HID_REQ_SET_REPORT);
}

static int asus_hid_set_backlight_hw(struct asus_hid_data *data,
				    unsigned int level)
{
	u8 command[A14_EC_REPORT_SIZE] = {
		A14_EC_REPORT_ID, 0xba, 0xc5, 0xc4, 0,
	};

	if (level > A14_EC_MAX_BACKLIGHT)
		return -EINVAL;
	command[4] = level;
	return asus_hid_raw_request(data, command, HID_REQ_SET_REPORT);
}

static int asus_kbd_brightness_set(struct led_classdev *led,
				   enum led_brightness brightness)
{
	struct asus_hid_data *data = container_of(led, struct asus_hid_data,
						  keyboard_led);
	int ret;

	brightness = min_t(enum led_brightness, brightness,
			   A14_EC_MAX_BACKLIGHT);
	atomic_set(&data->desired_brightness, brightness);
	if (READ_ONCE(data->suspended))
		return 0;
	ret = asus_hid_set_backlight_hw(data, brightness);
	if (ret)
		dev_warn(&data->hdev->dev, "failed to set keyboard backlight: %d\n",
			 ret);
	return ret;
}

static enum led_brightness asus_kbd_brightness_get(struct led_classdev *led)
{
	struct asus_hid_data *data = container_of(led, struct asus_hid_data,
						  keyboard_led);

	return atomic_read(&data->desired_brightness);
}

static void asus_backlight_work(struct work_struct *work)
{
	struct asus_hid_data *data = container_of(work, struct asus_hid_data,
						  backlight_work);
	unsigned int level = atomic_read(&data->desired_brightness);
	int ret;

	if (READ_ONCE(data->suspended))
		return;
	ret = asus_hid_set_backlight_hw(data, level);
	if (ret) {
		dev_warn(&data->hdev->dev, "Fn backlight update failed: %d\n", ret);
		return;
	}
	led_classdev_notify_brightness_hw_changed(&data->keyboard_led, level);
}

static void asus_emit_key(struct input_dev *input, unsigned int key)
{
	input_report_key(input, key, 1);
	input_sync(input);
	input_report_key(input, key, 0);
	input_sync(input);
}

static int asus_raw_event(struct hid_device *hdev, struct hid_report *report,
			  u8 *raw_data, int size)
{
	struct asus_hid_data *data = hid_get_drvdata(hdev);
	u8 usage;

	if (!data || report->id != A14_EC_REPORT_ID || size < 2)
		return 0;
	usage = raw_data[1];

	switch (usage) {
	case A14_EC_EVT_KEY_FN_ESC:
		asus_emit_key(data->hotkeys, KEY_FN_ESC);
		return 1;
	case A14_EC_EVT_KEY_FN_F4: {
		unsigned int level = atomic_read(&data->desired_brightness);
		unsigned int next = (level + 1) % (A14_EC_MAX_BACKLIGHT + 1);

		atomic_set(&data->desired_brightness, next);
		schedule_work(&data->backlight_work);
		return 1;
	}
	case A14_EC_EVT_KEY_FN_F5:
		asus_emit_key(data->hotkeys, KEY_BRIGHTNESSDOWN);
		return 1;
	case A14_EC_EVT_KEY_FN_F6:
		asus_emit_key(data->hotkeys, KEY_BRIGHTNESSUP);
		return 1;
	case A14_EC_EVT_KEY_FN_F8:
		asus_emit_key(data->hotkeys, KEY_EMOJI_PICKER);
		return 1;
	case A14_EC_EVT_KEY_FN_F9:
		asus_emit_key(data->hotkeys, KEY_MICMUTE);
		return 1;
	case A14_EC_EVT_KEY_FN_F10:
		asus_emit_key(data->hotkeys, KEY_CAMERA_ACCESS_TOGGLE);
		return 1;
	case A14_EC_EVT_KEY_FN_F11:
		asus_emit_key(data->hotkeys, KEY_TOUCHPAD_TOGGLE);
		return 1;
	case A14_EC_EVT_KEY_FN_F12:
		asus_emit_key(data->hotkeys, KEY_PROG1);
		return 1;
	case A14_EC_EVT_KEY_FN_F:
		asus_emit_key(data->hotkeys, KEY_PERFORMANCE);
		return 1;
	default:
		return 0;
	}
}

static ssize_t hid_cmd_store(struct device *dev, struct device_attribute *attr,
			     const char *buf, size_t count)
{
	struct hid_device *hdev = to_hid_device(dev);
	struct asus_hid_data *data = hid_get_drvdata(hdev);
	u8 command[A14_EC_REPORT_SIZE] = { A14_EC_REPORT_ID };
	u8 response[A14_EC_REPORT_SIZE] = { A14_EC_REPORT_ID };
	const char *cursor = buf;
	unsigned int value;
	int index = 1;
	int consumed;
	int ret;

	while (*cursor && index < A14_EC_REPORT_SIZE) {
		while (*cursor == ' ' || *cursor == '\t' || *cursor == '\n')
			cursor++;
		if (!*cursor)
			break;
		if (sscanf(cursor, "%2x%n", &value, &consumed) != 1 || value > 0xff)
			return -EINVAL;
		command[index++] = value;
		cursor += consumed;
		if (*cursor && *cursor != ' ' && *cursor != '\t' && *cursor*+;
			return -EINVAL;
	}
	if (index == 1)
		return -EINVAL;

	ret = asus_hid_raw_request(data, command, HID_REQ_SET_REPORT);
	if (ret)
		return ret;
	msleep(30);
	ret = asus_hid_raw_request(data, response, HID_REQ_GET_REPORT);
	if (ret)
		return ret;
	memcpy(data->debug_response, response, sizeof(response));
	return count;
}

static ssize_t hid_cmd_show(struct device *dev, struct device_attribute *attr,
			    char *buf)
{
	struct hid_device *hdev = to_hid_device(dev);
	struct asus_hid_data *data = hid_get_drvdata(hdev);
	int length = 0;
	int i;

	for (i = 0; i < A14_EC_REPORT_SIZE; i++)
		length += sysfs_emit_at(buf, length, "%02x%c",
					 data->debug_response[i],
					 i == A14_EC_REPORT_SIZE - 1 ? '\n' : ' ');
	return length;
}

static struct device_attribute dev_attr_hid_cmd =
	__ATTR(hid_cmd, 0600, hid_cmd_show, hid_cmd_store);

static int asus_hid_suspend(struct hid_device *hdev, pm_message_t message)
{
	struct asus_hid_data *data = hid_get_drvdata(hdev);

	WRITE_ONCE(data->suspended, true);
	cancel_work_sync(&data->backlight_work);
	(void)asus_hid_set_backlight_hw(data, 0);
	return 0;
}

static int asus_hid_resume(struct hid_device *hdev)
{
	struct asus_hid_data *data = hid_get_drvdata(hdev);
	unsigned int level = atomic_read(&data->desired_brightness);
	int ret;
	int attempt;

	msleep(100);
	for (attempt = 0; attempt < 5; attempt++) {
		ret = asus_hid_initialise(data);
		if (!ret)
			break;
		msleep(100 * (attempt + 1));
	}
	WRITE_ONCE(data->suspended, false);
	if (ret)
		return ret;
	return asus_hid_set_backlight_hw(data, level);
}

static int asus_hid_probe(struct hid_device *hdev,
			  const struct hid_device_id *id)
{
	struct asus_hid_data *data;
	int ret;

	data = devm_kzalloc(&hdev->dev, sizeof(*data), GFP_KERNEL);
	if (!data)
		return -ENOMEM;
	data->hdev = hdev;
	mutex_init(&data->io_lock);
	INIT_WORK(&data->backlight_work, asus_backlight_work);
	atomic_set(&data->desired_brightness,
		   min_t(uint, initial_brightness, A14_EC_MAX_BACKLIGHT));
	hid_set_drvdata(hdev, data);

	ret = hid_parse(hdev);
	if (ret)
		return ret;
	ret = hid_hw_start(hdev, HID_CONNECT_DEFAULT);
	if (ret)
		return ret;

	data->hotkeys = input_allocate_device();
	if (!data->hotkeys) {
		ret = -ENOMEM;
		goto err_hid;
	}
	data->hotkeys->name = "ASUS Zenbook A14 EC hotkeys";
	data->hotkeys->phys = "i2c-hid/input1/hotkeys";
	data->hotkeys->id.bustype = hdev->bus;
	data->hotkeys->id.vendor = hdev->vendor;
	data->hotkeys->id.product = hdev->product;
	data->hotkeys->dev.parent = &hdev->dev;
	input_set_capability(data->hotkeys, EV_KEY, KEY_FN_ESC);
	input_set_capability(data->hotkeys, EV_KEY, KEY_BRIGHTNESSDOWN);
	input_set_capability(data->hotkeys, EV_KEY, KEY_BRIGHTNESSUP);
	input_set_capability(data->hotkeys, EV_KEY, KEY_EMOJI_PICKER);
	input_set_capability(data->hotkeys, EV_KEY, KEY_MICMUTE);
	input_set_capability(data->hotkeys, EV_KEY, KEY_CAMERA_ACCESS_TOGGLE);
	input_set_capability(data->hotkeys, EV_KEY, KEY_TOUCHPAD_TOGGLE);
	input_set_capability(data->hotkeys, EV_KEY, KEY_PROG1);
	input_set_capability(data->hotkeys, EV_KEY, KEY_PERFORMANCE);
	ret = input_register_device(data->hotkeys);
	if (ret)
		goto err_input;

	data->keyboard_led.name = "asus::kbd_backlight";
	data->keyboard_led.max_brightness = A14_EC_MAX_BACKLIGHT;
	data->keyboard_led.brightness_set_blocking = asus_kbd_brightness_set;
	data->keyboard_led.brightness_get = asus_kbd_brightness_get;
	data->keyboard_led.flags = LED_BRIGHT_HW_CHANGED;
	ret = led_classdev_register(&hdev->dev, &data->keyboard_led);
	if (ret)
		goto err_registered_input;
	data->led_registered = true;

	ret = asus_hid_initialise(data);
	if (ret)
		goto err_led;
	ret = asus_hid_set_backlight_hw(data,
					atomic_read(&data->desired_brightness));
	if (ret)
		goto err_led;

	if (enable_debug_commands) {
		ret = device_create_file(&hdev->dev, &dev_attr_hid_cmd);
		if (ret)
			dev_warn(&hdev->dev, "cannot create hid_cmd debug attribute: %d\n",
				 ret);
		else
			data->debug_attribute_created = true;
	}

	dev_info(&hdev->dev, "Zenbook A14 EC keyboard support enabled\n");
	return 0;

err_led:
	led_classdev_unregister(&data->keyboard_led);
	data->led_registered = false;
err_registered_input:
	input_unregister_device(data->hotkeys);
	data->hotkeys = NULL;
	goto err_hid;
err_input:
	input_free_device(data->hotkeys);
	data->hotkeys = NULL;
err_hid:
	hid_hw_stop(hdev);
	return ret;
}

static void asus_hid_remove(struct hid_device *hdev)
{
	struct asus_hid_data *data = hid_get_drvdata(hdev);

	if (data->debug_attribute_created)
		device_remove_file(&hdev->dev, &dev_attr_hid_cmd);
	cancel_work_sync(&data->backlight_work);
	if (data->led_registered)
		led_classdev_unregister(&data->keyboard_led);
	if (data->hotkeys)
		input_unregister_device(data->hotkeys);
	hid_hw_stop(hdev);
}

static const struct hid_device_id asus_hid_devices[] = {
	{ HID_DEVICE(0x18, 0x00, ASUS_VENDOR_ID, ASUS_PRODUCT_ID) },
	{ }
};
MODULE_DEVICE_TABLE(hid, asus_hid_devices);

static struct hid_driver asus_hid_driver = {
	.name = "hid_asus_zenbook_a14_ec",
	.id_table = asus_hid_devices,
	.probe = asus_hid_probe,
	.remove = asus_hid_remove,
	.raw_event = asus_raw_event,
	.suspend = asus_hid_suspend,
	.resume = asus_hid_resume,
};
module_hid_driver(asus_hid_driver);

MODULE_AUTHOR("Alexandru Marc Serdeliuc <serdeliuk@yahoo.com>");
MODULE_AUTHOR("Ömer Faruk Nehir <omerfaruknehir@gmail.com>");
MODULE_DESCRIPTION("ASUS Zenbook A14 EC HID keyboard driver");
MODULE_LICENSE("GPL");
