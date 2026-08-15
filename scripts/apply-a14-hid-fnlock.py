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
helper = '''#define A14_HID_FNLOCK_WINDOWS_FULL_FEATURE_REPORT 1\n\nstatic int asus_hid_set_fnlock_hw(struct asus_hid_data *data, bool enabled)\n{\n\tu8 command[A14_EC_REPORT_SIZE] = {\n\t\tA14_EC_REPORT_ID, 0xd0, 0x4e, enabled ? 1 : 0,\n\t};\n\n\t/*\n\t * UX3407RA Windows reference, ASUSOptimization.exe 2.1.75.0:\n\t *   VID 0b05 / PID 0220 / UsagePage ff31 / Usage 0076\n\t *   FeatureReportByteLength = 64\n\t *   payload = 5a d0 4e <state>, zero-padded to all 64 bytes\n\t *   HidD_SetFeature(handle, payload, 64)\n\t *\n\t * On the real machine state 0 selects ASUS/media actions as the primary\n\t * F-row behavior and state 1 selects ordinary F1..F12 as primary.  The\n\t * existing A14 HID raw-request helper already submits a full 64-byte feature\n\t * report, matching that Windows transport exactly.\n\t */\n\treturn asus_hid_raw_request(data, command, HID_REQ_SET_REPORT);\n}\n\nstatic void asus_fnlock_work(struct work_struct *work)\n{\n\tstruct asus_hid_data *data = container_of(work, struct asus_hid_data,\n\t\t\t\t\t\t  fnlock_work);\n\tbool requested = atomic_read(&data->desired_fn_lock);\n\tint ret;\n\n\tif (READ_ONCE(data->suspended))\n\t\treturn;\n\tret = asus_hid_set_fnlock_hw(data, requested);\n\tif (ret) {\n\t\tatomic_set(&data->desired_fn_lock, data->fn_lock);\n\t\tdev_warn(&data->hdev->dev, "Fn-lock update failed: %d\\n", ret);\n\t\treturn;\n\t}\n\tdata->fn_lock = requested;\n}\n\n'''
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
    '\tif (ret)\n\t\treturn ret;\n\tret = asus_hid_set_backlight_hw(data, level);\n\tif (ret)\n\t\treturn ret;\n\t/* Firmware may lose the Fn-row mode across suspend; always restore it. */\n\tret = asus_hid_set_fnlock_hw(data, data->fn_lock);\n\tif (ret)\n\t\tdev_warn(&data->hdev->dev, "Fn-lock resume restore failed: %d\\n", ret);\n\treturn 0;\n}\n',
    'resume')

once(
    '\tINIT_WORK(&data->backlight_work, asus_backlight_work);\n\tatomic_set(&data->desired_brightness,\n',
    '\tINIT_WORK(&data->backlight_work, asus_backlight_work);\n\tINIT_WORK(&data->fnlock_work, asus_fnlock_work);\n\tatomic_set(&data->desired_fn_lock, 0);\n\tdata->fn_lock = false;\n\tatomic_set(&data->desired_brightness,\n',
    'probe init')

# Establish a deterministic state at driver bind.  Windows state 0 means the
# normal ASUS action-key-first behavior.  Fn+Esc then toggles to state 1.
once(
    '\tret = asus_hid_set_backlight_hw(data,\n\t\t\t\t\tatomic_read(&data->desired_brightness));\n\tif (ret)\n\t\tgoto err_led;\n\n\tif (enable_debug_commands) {\n',
    '\tret = asus_hid_set_backlight_hw(data,\n\t\t\t\t\tatomic_read(&data->desired_brightness));\n\tif (ret)\n\t\tgoto err_led;\n\tret = asus_hid_set_fnlock_hw(data, false);\n\tif (ret)\n\t\tdev_warn(&hdev->dev, "initial Fn-lock state setup failed: %d\\n", ret);\n\n\tif (enable_debug_commands) {\n',
    'probe hardware init')

once(
    '\tcancel_work_sync(&data->backlight_work);\n\tif (data->led_registered)\n',
    '\tcancel_work_sync(&data->backlight_work);\n\tcancel_work_sync(&data->fnlock_work);\n\tif (data->led_registered)\n',
    'remove')

p.write_text(s)
print('a14_hid_fnlock=windows-full-feature-report')
