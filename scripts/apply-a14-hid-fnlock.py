#!/usr/bin/env python3
import runpy
from pathlib import Path

# build-deb.sh already invokes the EC composition before this HID transform.
# When invoked directly from a clean checkout, finish repository-only native EC
# composition here.
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


# This keyboard is ACPI QTEC0001 on Windows but exposes ASUS VID 0b05 in its
# HID-over-I2C descriptor. Linux i2c-hid's existing QTEC post-initialization
# re-power quirk keys on HID vendor 6243, so it does not run for this A14.
once(
    '#include <linux/input.h>\n',
    '#include <linux/input.h>\n#include <linux/i2c.h>\n#include <linux/property.h>\n#include <linux/unaligned.h>\n',
    'transport includes')

once(
    '\tstruct work_struct backlight_work;\n\tatomic_t desired_brightness;\n',
    '\tstruct work_struct backlight_work;\n\tstruct work_struct fnlock_work;\n\tstruct delayed_work fnlock_init_work;\n\tatomic_t desired_brightness;\n\tatomic_t desired_fn_lock;\n\tbool fn_lock;\n\tbool fnlock_ready;\n',
    'state')

old_initialise = '''static int asus_hid_initialise(struct asus_hid_data *data)\n{\n\tu8 command[A14_EC_REPORT_SIZE] = {\n\t\tA14_EC_REPORT_ID, 0xd0, 0x8f, 0x01,\n\t};\n\n\treturn asus_hid_raw_request(data, command, HID_REQ_SET_REPORT);\n}\n\n'''
new_initialise = '''#define A14_HID_FNLOCK_WINDOWS_FULL_FEATURE_REPORT 1\n#define A14_HID_FNLOCK_WINDOWS_COMMON_INIT 1\n#define A14_HID_QTEC_POST_HID_REPOWER 1\n\n#define A14_I2C_HID_DESC_SIZE 30\n#define A14_I2C_HID_COMMAND_REG_OFFSET 16\n#define A14_I2C_HID_PWR_ON 0x00\n#define A14_I2C_HID_OPCODE_SET_POWER 0x08\n\nstatic int asus_hid_i2c_transfer(struct i2c_client *client,\n\t\t\t\t struct i2c_msg *msgs, int num)\n{\n\tint ret = i2c_transfer(client->adapter, msgs, num);\n\n\tif (ret == num)\n\t\treturn 0;\n\treturn ret < 0 ? ret : -EIO;\n}\n\nstatic int asus_hid_qtec_post_init_repower(struct asus_hid_data *data)\n{\n\tstruct hid_device *hdev = data->hdev;\n\tstruct i2c_client *client;\n\tstruct i2c_msg read_msgs[2];\n\tstruct i2c_msg power_msg;\n\tu8 addr_buf[2];\n\tu8 descriptor[A14_I2C_HID_DESC_SIZE];\n\tu8 power_cmd[4];\n\tu16 command_register;\n\tu32 descriptor_address;\n\tint ret;\n\n\tif (hdev->bus != BUS_I2C)\n\t\treturn -EOPNOTSUPP;\n\n\t/* i2c-hid stores its transport i2c_client in hid_device::driver_data. */\n\tclient = hdev->driver_data;\n\tif (!client || !client->adapter)\n\t\treturn -ENODEV;\n\n\tret = device_property_read_u32(&client->dev, "hid-descr-addr",\n\t\t\t\t       &descriptor_address);\n\tif (ret)\n\t\treturn ret;\n\tif (descriptor_address > U16_MAX)\n\t\treturn -EINVAL;\n\n\tput_unaligned_le16((u16)descriptor_address, addr_buf);\n\tread_msgs[0] = (struct i2c_msg) {\n\t\t.addr = client->addr,\n\t\t.flags = client->flags & I2C_M_TEN,\n\t\t.len = sizeof(addr_buf),\n\t\t.buf = addr_buf,\n\t};\n\tread_msgs[1] = (struct i2c_msg) {\n\t\t.addr = client->addr,\n\t\t.flags = (client->flags & I2C_M_TEN) | I2C_M_RD,\n\t\t.len = sizeof(descriptor),\n\t\t.buf = descriptor,\n\t};\n\n\tmutex_lock(&data->io_lock);\n\tret = asus_hid_i2c_transfer(client, read_msgs, ARRAY_SIZE(read_msgs));\n\tif (ret)\n\t\tgoto out_unlock;\n\tif (get_unaligned_le16(descriptor) != A14_I2C_HID_DESC_SIZE ||\n\t    get_unaligned_le16(descriptor + 2) != 0x0100) {\n\t\tret = -EPROTO;\n\t\tgoto out_unlock;\n\t}\n\n\tcommand_register = get_unaligned_le16(\n\t\tdescriptor + A14_I2C_HID_COMMAND_REG_OFFSET);\n\tput_unaligned_le16(command_register, power_cmd);\n\tpower_cmd[2] = A14_I2C_HID_PWR_ON;\n\tpower_cmd[3] = A14_I2C_HID_OPCODE_SET_POWER;\n\tpower_msg = (struct i2c_msg) {\n\t\t.addr = client->addr,\n\t\t.flags = client->flags & I2C_M_TEN,\n\t\t.len = sizeof(power_cmd),\n\t\t.buf = power_cmd,\n\t};\n\tret = asus_hid_i2c_transfer(client, &power_msg, 1);\n\nout_unlock:\n\tmutex_unlock(&data->io_lock);\n\tif (ret)\n\t\treturn ret;\n\n\t/* i2c-hid itself uses 60 ms after PWR_ON for devices needing settling. */\n\tmsleep(60);\n\tdev_info(&hdev->dev,\n\t\t "applied A14/QTEC post-HID SET_POWER(ON), command-reg=0x%04x\\n",\n\t\t command_register);\n\treturn 0;\n}\n\nstatic bool asus_hid_windows_feature_is_known(const u8 *report)\n{\n\tstatic const u8 initial_string[] = {\n\t\t0x5a, 'A', 'S', 'U', 'S', ' ', 'T', 'e', 'c', 'h', '.',\n\t\t'I', 'n', 'c', '.', 0x00,\n\t};\n\n\tif (!memcmp(report, initial_string, sizeof(initial_string)))\n\t\treturn true;\n\tif (report[0] != A14_EC_REPORT_ID)\n\t\treturn false;\n\n\t/* Prefixes recognized by AsusOptimization.exe 2.1.75.0 before it\n\t * decides whether the 0x5a + "ASUS Tech.Inc." handshake is needed. */\n\tswitch (report[1]) {\n\tcase 0x05: /* configuration */\n\tcase 0xb0:\n\tcase 0xb1:\n\tcase 0xba: /* keyboard light */\n\tcase 0xbb: /* N-key rollover */\n\tcase 0xc2: /* arrow-key switch */\n\tcase 0xd0: /* Fn switch / status LEDs / battery family */\n\tcase 0xf4:\n\t\treturn true;\n\tdefault:\n\t\treturn false;\n\t}\n}\n\nstatic int asus_hid_set_fnlock_hw(struct asus_hid_data *data, bool enabled)\n{\n\tu8 command[A14_EC_REPORT_SIZE] = {\n\t\tA14_EC_REPORT_ID, 0xd0, 0x4e, enabled ? 1 : 0,\n\t};\n\n\t/* Exact A14 Windows path:\n\t * 0B05:0220 / UsagePage FF31 / Usage 0076 / FeatureReportByteLength 64.\n\t * AsusOptimization.exe passes the complete zero-padded 64-byte buffer to\n\t * HidD_SetFeature. State 0 = ASUS action keys primary; state 1 = F1..F12. */\n\treturn asus_hid_raw_request(data, command, HID_REQ_SET_REPORT);\n}\n\nstatic int asus_hid_windows_common_init(struct asus_hid_data *data,\n\t\t\t\t\tbool fn_lock)\n{\n\tstatic const u8 config_prefix[] = { 0x5a, 0x05, 0x20, 0x31, 0x00, 0x08 };\n\tu8 report[A14_EC_REPORT_SIZE] = { A14_EC_REPORT_ID };\n\tu8 command[A14_EC_REPORT_SIZE];\n\tint attempt;\n\tint ret;\n\n\t/* AsusOptimization common initialization first GETs report 0x5a. Only\n\t * when it is not one of the feature families it recognizes does it send\n\t * the Initial string feature. */\n\tret = asus_hid_raw_request(data, report, HID_REQ_GET_REPORT);\n\tif (ret || !asus_hid_windows_feature_is_known(report)) {\n\t\tmemset(command, 0, sizeof(command));\n\t\tcommand[0] = A14_EC_REPORT_ID;\n\t\tmemcpy(command + 1, "ASUS Tech.Inc.", sizeof("ASUS Tech.Inc."));\n\t\tret = asus_hid_raw_request(data, command, HID_REQ_SET_REPORT);\n\t\tif (ret)\n\t\t\treturn ret;\n\t}\n\n\t/* Configuration transaction at 0x1400264cc in the captured 2.1.75.0\n\t * binary. It retries up to four times until the echoed header is valid. */\n\tfor (attempt = 0; attempt < 4; attempt++) {\n\t\tmemset(command, 0, sizeof(command));\n\t\tmemcpy(command, config_prefix, sizeof(config_prefix));\n\t\tret = asus_hid_raw_request(data, command, HID_REQ_SET_REPORT);\n\t\tif (ret)\n\t\t\treturn ret;\n\n\t\tmemset(report, 0, sizeof(report));\n\t\treport[0] = A14_EC_REPORT_ID;\n\t\tret = asus_hid_raw_request(data, report, HID_REQ_GET_REPORT);\n\t\tif (!ret && !memcmp(report, config_prefix, sizeof(config_prefix)))\n\t\t\tbreak;\n\t\tmsleep(100);\n\t}\n\tif (attempt == 4)\n\t\treturn ret ? ret : -EPROTO;\n\n\tdev_info(&data->hdev->dev,\n\t\t "ASUS feature config: %02x %02x %02x (Fn switch next)\\n",\n\t\t report[6], report[7], report[8]);\n\n\t/* On this A14 the captured response is 01 20 01. In particular the\n\t * N-key-rollover capability bit (byte 6 bit 5) is clear, so the Windows\n\t * startup path skips its 5a bb state transaction. ArrowKeySwitch is an\n\t * independent registry option and is not part of Fn-lock initialization. */\n\treturn asus_hid_set_fnlock_hw(data, fn_lock);\n}\n\n'''
once(old_initialise, new_initialise, 'replace misidentified OOBE initializer')

# Insert both process-context workers after the backlight hardware helper so the
# delayed initializer can restore the LED after the transport has been repowered.
anchor = '''static int asus_kbd_brightness_set(struct led_classdev *led,\n'''
workers = '''static void asus_fnlock_init_work(struct work_struct *work)\n{\n\tstruct asus_hid_data *data = container_of(to_delayed_work(work),\n\t\t\t\t\t\t  struct asus_hid_data,\n\t\t\t\t\t\t  fnlock_init_work);\n\tunsigned int level = atomic_read(&data->desired_brightness);\n\tbool requested = atomic_read(&data->desired_fn_lock);\n\tint ret;\n\n\tif (READ_ONCE(data->suspended))\n\t\treturn;\n\n\t/* Match i2c-hid's upstream QTEC quirk ordering: the extra PWR_ON must\n\t * happen after HID initialization. This delayed worker is queued at the\n\t * end of the upper HID driver's probe, so hid_add_device() can finish\n\t * before the transaction runs. */\n\tret = asus_hid_qtec_post_init_repower(data);\n\tif (ret) {\n\t\tdev_warn(&data->hdev->dev, "A14/QTEC post-init repower failed: %d\\n", ret);\n\t\treturn;\n\t}\n\n\tret = asus_hid_windows_common_init(data, requested);\n\tif (ret) {\n\t\tdev_warn(&data->hdev->dev, "ASUS Fn-switch common init failed: %d\\n", ret);\n\t\treturn;\n\t}\n\n\tdata->fn_lock = requested;\n\tWRITE_ONCE(data->fnlock_ready, true);\n\n\tret = asus_hid_set_backlight_hw(data, level);\n\tif (ret)\n\t\tdev_warn(&data->hdev->dev, "keyboard-backlight restore after Fn init failed: %d\\n", ret);\n}\n\nstatic void asus_fnlock_work(struct work_struct *work)\n{\n\tstruct asus_hid_data *data = container_of(work, struct asus_hid_data,\n\t\t\t\t\t\t  fnlock_work);\n\tbool requested = atomic_read(&data->desired_fn_lock);\n\tint ret;\n\n\tif (READ_ONCE(data->suspended))\n\t\treturn;\n\tif (!READ_ONCE(data->fnlock_ready)) {\n\t\tmod_delayed_work(system_wq, &data->fnlock_init_work, 0);\n\t\treturn;\n\t}\n\n\tret = asus_hid_set_fnlock_hw(data, requested);\n\tif (ret) {\n\t\tatomic_set(&data->desired_fn_lock, data->fn_lock);\n\t\tdev_warn(&data->hdev->dev, "Fn-lock update failed: %d\\n", ret);\n\t\treturn;\n\t}\n\tdata->fn_lock = requested;\n}\n\n'''
if workers not in s:
    if s.count(anchor) != 1:
        raise SystemExit(f'worker insertion: expected one source anchor, found {s.count(anchor)}')
    s = s.replace(anchor, workers + anchor, 1)

once(
    '\tcase A14_EC_EVT_KEY_FN_ESC:\n\t\tasus_emit_key(data->hotkeys, KEY_FN_ESC);\n\t\treturn 1;\n',
    '\tcase A14_EC_EVT_KEY_FN_ESC:\n\t\tatomic_set(&data->desired_fn_lock,\n\t\t\t   !atomic_read(&data->desired_fn_lock));\n\t\tschedule_work(&data->fnlock_work);\n\t\treturn 1;\n',
    'Fn+Esc')

once(
    '\tWRITE_ONCE(data->suspended, true);\n\tcancel_work_sync(&data->backlight_work);\n',
    '\tWRITE_ONCE(data->suspended, true);\n\tWRITE_ONCE(data->fnlock_ready, false);\n\tcancel_work_sync(&data->backlight_work);\n\tcancel_work_sync(&data->fnlock_work);\n\tcancel_delayed_work_sync(&data->fnlock_init_work);\n',
    'suspend')

old_resume = '''static int asus_hid_resume(struct hid_device *hdev)\n{\n\tstruct asus_hid_data *data = hid_get_drvdata(hdev);\n\tunsigned int level = atomic_read(&data->desired_brightness);\n\tint ret;\n\tint attempt;\n\n\tmsleep(100);\n\tfor (attempt = 0; attempt < 5; attempt++) {\n\t\tret = asus_hid_initialise(data);\n\t\tif (!ret)\n\t\t\tbreak;\n\t\tmsleep(100 * (attempt + 1));\n\t}\n\tWRITE_ONCE(data->suspended, false);\n\tif (ret)\n\t\treturn ret;\n\treturn asus_hid_set_backlight_hw(data, level);\n}\n'''
new_resume = '''static int asus_hid_resume(struct hid_device *hdev)\n{\n\tstruct asus_hid_data *data = hid_get_drvdata(hdev);\n\n\tWRITE_ONCE(data->suspended, false);\n\tWRITE_ONCE(data->fnlock_ready, false);\n\tmod_delayed_work(system_wq, &data->fnlock_init_work,\n\t\t\t msecs_to_jiffies(100));\n\treturn 0;\n}\n'''
once(old_resume, new_resume, 'resume')

once(
    '\tINIT_WORK(&data->backlight_work, asus_backlight_work);\n\tatomic_set(&data->desired_brightness,\n',
    '\tINIT_WORK(&data->backlight_work, asus_backlight_work);\n\tINIT_WORK(&data->fnlock_work, asus_fnlock_work);\n\tINIT_DELAYED_WORK(&data->fnlock_init_work, asus_fnlock_init_work);\n\tatomic_set(&data->desired_fn_lock, 0);\n\tdata->fn_lock = false;\n\tdata->fnlock_ready = false;\n\tatomic_set(&data->desired_brightness,\n',
    'probe init')

# The old 5a d0 8f 01 packet was previously mislabeled as generic HID
# initialization. Reverse engineering of the exact ASUSOptimization binary
# shows D0/8F is the OOBE Complete feature, not the Fn-switch prerequisite.
old_probe_hw = '''\tret = asus_hid_initialise(data);\n\tif (ret)\n\t\tgoto err_led;\n\tret = asus_hid_set_backlight_hw(data,\n\t\t\t\t\tatomic_read(&data->desired_brightness));\n\tif (ret)\n\t\tgoto err_led;\n\n\tif (enable_debug_commands) {\n'''
new_probe_hw = '''\t/* Queue the real post-HID transport re-power + ASUSOptimization common\n\t * initialization after this upper-driver probe is able to return. */\n\tmod_delayed_work(system_wq, &data->fnlock_init_work,\n\t\t\t msecs_to_jiffies(100));\n\n\tif (enable_debug_commands) {\n'''
once(old_probe_hw, new_probe_hw, 'probe hardware init')

once(
    '\tcancel_work_sync(&data->backlight_work);\n\tif (data->led_registered)\n',
    '\tcancel_work_sync(&data->backlight_work);\n\tcancel_work_sync(&data->fnlock_work);\n\tcancel_delayed_work_sync(&data->fnlock_init_work);\n\tif (data->led_registered)\n',
    'remove')

required = (
    'A14_HID_FNLOCK_WINDOWS_COMMON_INIT',
    'A14_HID_QTEC_POST_HID_REPOWER',
    'static int asus_hid_qtec_post_init_repower',
    'static int asus_hid_windows_common_init',
    'static int asus_hid_set_fnlock_hw',
    'INIT_DELAYED_WORK(&data->fnlock_init_work, asus_fnlock_init_work);',
    'mod_delayed_work(system_wq, &data->fnlock_init_work',
    'schedule_work(&data->fnlock_work);',
)
missing = [token for token in required if token not in s]
if missing:
    raise SystemExit('A14 Fn-lock reverse-engineered transform incomplete: ' + ', '.join(missing))
if 'static int asus_hid_initialise' in s or '0xd0, 0x8f, 0x01' in s:
    raise SystemExit('obsolete OOBE-as-initializer path still present')

p.write_text(s)
print('a14_hid_fnlock=asusoptimization-common-init-plus-qtec-post-hid-repower')