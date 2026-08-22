#!/usr/bin/env python3
from pathlib import Path

p = Path("hid_asus_ec.c")
if not p.is_file():
    raise SystemExit("run from the repository root")

s = p.read_text()


def replace_once(old: str, new: str, label: str) -> None:
    global s
    if new in s:
        return
    count = s.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one anchor, found {count}")
    s = s.replace(old, new, 1)


if "A14_HID_FNLOCK_STATE_SYSFS" in s:
    print("a14_fnlock_state=current")
    raise SystemExit(0)
if "A14_HID_LIFECYCLE_HARDENING" not in s:
    raise SystemExit("Fn-lock state export requires lifecycle-hardened HID source")

marker_anchor = "#define A14_HID_LIFECYCLE_HARDENING 1\n"
replace_once(
    marker_anchor,
    marker_anchor + "#define A14_HID_FNLOCK_STATE_SYSFS 1\n",
    "Fn-lock state marker",
)

replace_once(
    "\tbool debug_attribute_created;\n",
    "\tbool debug_attribute_created;\n\tbool fnlock_attribute_created;\n",
    "Fn-lock attribute state",
)

# Export the state that was actually accepted by the vendor FEATURE command,
# not merely the user's desired state. The extension uses this for OSD.
anchor = "static ssize_t hid_cmd_store(struct device *dev, struct device_attribute *attr,\n"
helper = r'''static ssize_t fn_lock_show(struct device *dev,
                            struct device_attribute *attr, char *buf)
{
    struct hid_device *hdev = to_hid_device(dev);
    struct asus_hid_data *data = hid_get_drvdata(hdev);

    if (!data || !READ_ONCE(data->fnlock_ready))
        return sysfs_emit(buf, "-1\n");
    return sysfs_emit(buf, "%u\n", READ_ONCE(data->fn_lock) ? 1 : 0);
}

static DEVICE_ATTR_RO(fn_lock);

'''
if helper not in s:
    if s.count(anchor) != 1:
        raise SystemExit(f"Fn-lock sysfs helper anchor: found {s.count(anchor)}")
    s = s.replace(anchor, helper + anchor, 1)

# Notify only after a successful vendor-state update. There are two success
# paths: initial/resume reconstruction and a live Fn+Esc change.
ready_anchor = "    WRITE_ONCE(data->fnlock_ready, true);\n    led_classdev_notify_brightness_hw_changed(&data->keyboard_led, level);\n"
ready_new = (
    "    WRITE_ONCE(data->fnlock_ready, true);\n"
    "    if (data->fnlock_attribute_created)\n"
    "        sysfs_notify(&data->hdev->dev.kobj, NULL, \"fn_lock\");\n"
    "    led_classdev_notify_brightness_hw_changed(&data->keyboard_led, level);\n"
)
replace_once(ready_anchor, ready_new, "vendor-ready Fn-lock notification")

live_anchor = (
    "    data->fn_lock = requested;\n"
    "    dev_info(&data->hdev->dev, \"Fn-lock hardware state=%u\\n\",\n"
    "             requested ? 1 : 0);\n"
)
live_new = (
    "    data->fn_lock = requested;\n"
    "    if (data->fnlock_attribute_created)\n"
    "        sysfs_notify(&data->hdev->dev.kobj, NULL, \"fn_lock\");\n"
    "    dev_info(&data->hdev->dev, \"Fn-lock hardware state=%u\\n\",\n"
    "             requested ? 1 : 0);\n"
)
replace_once(live_anchor, live_new, "live Fn-lock notification")

# Create the read-only state node before asynchronous vendor initialization so
# userspace can discover it immediately. -1 means the vendor path is not ready.
probe_anchor = "\tdata->led_registered = true;\n\n"
probe_new = (
    "\tdata->led_registered = true;\n\n"
    "\tret = device_create_file(&hdev->dev, &dev_attr_fn_lock);\n"
    "\tif (ret)\n"
    "\t\tdev_warn(&hdev->dev, \"cannot create fn_lock attribute: %d\\n\", ret);\n"
    "\telse\n"
    "\t\tdata->fnlock_attribute_created = true;\n\n"
)
replace_once(probe_anchor, probe_new, "Fn-lock attribute creation")

remove_anchor = (
    "\tif (data->debug_attribute_created)\n"
    "\t\tdevice_remove_file(&hdev->dev, &dev_attr_hid_cmd);\n"
)
remove_new = (
    "\tif (data->debug_attribute_created)\n"
    "\t\tdevice_remove_file(&hdev->dev, &dev_attr_hid_cmd);\n"
    "\tif (data->fnlock_attribute_created)\n"
    "\t\tdevice_remove_file(&hdev->dev, &dev_attr_fn_lock);\n"
)
replace_once(remove_anchor, remove_new, "Fn-lock attribute removal")

p.write_text(s)
print("a14_fnlock_state=applied")
