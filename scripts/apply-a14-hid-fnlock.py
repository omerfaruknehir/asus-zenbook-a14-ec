#!/usr/bin/env python3
import runpy
from pathlib import Path

# build-deb.sh already invokes the EC composition before this HID transform.
# When invoked directly from a clean checkout, finish repository-only native EC
# composition here. Do not key this on a particular telemetry experiment: the
# calibrated selector telemetry intentionally removed the old EC_NATIVE_FAN1_*
# marker, and using that marker caused an already-composed EC source to be
# transformed twice.
ec_path = Path('asus_zenbook_a14_ec.c')
ec_source = ec_path.read_text()
if ('EC_FW_FAN_PROFILE_COMMAND' not in ec_source or
        'KERNEL_VERSION(6, 19, 0)' not in ec_source):
    transforms = [
        Path('scripts/apply-a14-native-fan-profile.py'),
        Path('scripts/apply-a14-native-hardening-compat.py'),
        Path('scripts/apply-a14-native-max-power.py'),
        Path('scripts/apply-a14-native-fan-telemetry.py'),
    ]
    for transform in transforms:
        if transform.is_file():
            runpy.run_path(str(transform), run_name='__main__')

p = Path('hid_asus_ec.c')
s = p.read_text()

def once(old, new, label):
    global s
    if new in s:
        return
    if s.count(old) != 1:
        raise SystemExit(f'{label}: expected one source anchor, found {s.count(old)}')
    s = s.replace(old, new, 1)

once(
    '\tstruct work_struct backlight_work;\n\tatomic_t desired_brightness;\n',
    '\tstruct work_struct backlight_work;\n\tstruct work_struct fnlock_work;\n\tatomic_t desired_brightness;\n\tatomic_t desired_fn_lock;\n\tbool fn_lock;\n',
    'state')

anchor = '''static int asus_hid_set_backlight_hw(struct asus_hid_data *data,\n\t\t\t\t    unsigned int level)\n'''
helper = '''#define A14_HID_FNLOCK_EXACT_SET_REPORT 1\n\nstatic int asus_hid_set_fnlock_hw(struct asus_hid_data *data, bool enabled)\n{\n\tu8 command[] = {\n\t\tA14_EC_REPORT_ID, 0xd0, 0x4e, enabled ? 1 : 0,\n\t};\n\tint ret;\n\n\t/*\n\t * ASUS' upstream HID implementation sends Fn-lock as the exact four-byte\n\t * feature report. Padding this command to A14_EC_REPORT_SIZE (64) is not\n\t * equivalent on all firmware, even though GET_REPORT uses a 64-byte buffer.\n\t */\n\tmutex_lock(&data->io_lock);\n\tret = hid_hw_raw_request(data->hdev, A14_EC_REPORT_ID, command,\n\t\t\t\t sizeof(command), HID_FEATURE_REPORT, HID_REQ_SET_REPORT);\n\tmutex_unlock(&data->io_lock);\n\treturn ret < 0 ? ret : 0;\n}\n\nstatic void asus_fnlock_work(struct work_struct *work)\n{\n\tstruct asus_hid_data *data = container_of(work, struct asus_hid_data,\n\t\t\t\t\t\t  fnlock_work);\n\tbool requested = atomic_read(&data->desired_fn_lock);\n\tint ret;\n\n\tif (READ_ONCE(data->suspended))\n\t\treturn;\n\tret = asus_hid_set_fnlock_hw(data, requested);\n\tif (ret) {\n\t\tatomic_set(&data->desired_fn_lock, data->fn_lock);\n\t\tdev_warn(&data->hdev->dev, "Fn-lock update failed: %d\\n", ret);\n\t\treturn;\n\t}\n\tdata->fn_lock = requested;\n}\n\n'''
once(anchor, helper + anchor, 'fnlock helper')

once(
    '\tcase A14_EC_EVT_KEY_FN_ESC:\n\t\tasus_emit_key(data->hotkeys, KEY_FN_ESC);\n\t\treturn 1;\n',
    '\tcase A14_EC_EVT_KEY_FN_ESC:\n\t\tatomic_set(&data->desired_fn_lock,\n\t\t\t   !atomic_read(&data->desired_fn_lock));\n\t\tschedule_work(&data->fnlock_work);\n\t\treturn 1;\n',
    'Fn+Esc')

once(
    '\tWRITE_ONCE(data->suspended, true);\n\tcancel_work_sync(&data->backlight_work);\n',
    '\tWRITE_ONCE(data->suspended, true);\n\tcancel_work_sync(&data->backlight_work);\n\tcancel_work_sync(&data->fnlock_work);\n',
    'suspend')

once(
    '\tif (ret)\n\t\treturn ret;\n\treturn asus_hid_set_backlight_hw(data, level);\n}\n',
    '\tif (ret)\n\t\treturn ret;\n\tret = asus_hid_set_backlight_hw(data, level);\n\tif (ret)\n\t\treturn ret;\n\tif (data->fn_lock)\n\t\tschedule_work(&data->fnlock_work);\n\treturn 0;\n}\n',
    'resume')

once(
    '\tINIT_WORK(&data->backlight_work, asus_backlight_work);\n\tatomic_set(&data->desired_brightness,\n',
    '\tINIT_WORK(&data->backlight_work, asus_backlight_work);\n\tINIT_WORK(&data->fnlock_work, asus_fnlock_work);\n\tatomic_set(&data->desired_fn_lock, 0);\n\tdata->fn_lock = false;\n\tatomic_set(&data->desired_brightness,\n',
    'probe init')

once(
    '\tcancel_work_sync(&data->backlight_work);\n\tif (data->led_registered)\n',
    '\tcancel_work_sync(&data->backlight_work);\n\tcancel_work_sync(&data->fnlock_work);\n\tif (data->led_registered)\n',
    'remove')

p.write_text(s)
print('a14_hid_fnlock=applied')
