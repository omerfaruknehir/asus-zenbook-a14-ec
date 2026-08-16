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


once(
    '#include <linux/input.h>\n',
    '#include <linux/input.h>\n#include <linux/i2c.h>\n#include <linux/property.h>\n#include <linux/unaligned.h>\n',
    'transport includes')

once(
    'MODULE_PARM_DESC(enable_debug_commands, "Expose root-only raw EC HID command sysfs+");\n',
    '''MODULE_PARM_DESC(enable_debug_commands, "Expose root-only raw EC HID command sysfs+");

/*
 * Exact Windows HIDI2C initialization comparison for QTEC0001/0b05:0220.
 * Windows powers the device on and then resets it; its HidReset path does not
 * issue another SET_POWER(ON) after reset completion. Linux i2c-hid normally
 * does. Keep this enabled for the A14 until the lower-level transport quirk is
 * proven and can be moved into i2c-hid itself.
 */
static bool fnlock_windows_transport_reinit = true;
module_param(fnlock_windows_transport_reinit, bool, 0644);
MODULE_PARM_DESC(fnlock_windows_transport_reinit,
                 "Re-run Windows-style HIDI2C POWER_ON->RESET (without post-reset POWER_ON) before Fn-switch init");

/* -1 mirrors the normal ASUSOptimization behavior of leaving ArrowKeySwitch
 * untouched unless its HKLM setting is explicitly enabled. 0/1 are diagnostic
 * overrides that send 5a c2 4b <value> before FnSwitch. */
static int fnlock_arrow_switch = -1;
module_param(fnlock_arrow_switch, int, 0644);
MODULE_PARM_DESC(fnlock_arrow_switch,
                 "Diagnostic ASUS ArrowKeySwitch startup value: -1=skip, 0/1=send before FnSwitch");
''',
    'Fn-lock module parameters')

once(
    '\tstruct work_struct backlight_work;\n\tatomic_t desired_brightness;\n',
    '\tstruct work_struct backlight_work;\n\tstruct work_struct fnlock_work;\n\tstruct delayed_work fnlock_init_work;\n\tatomic_t desired_brightness;\n\tatomic_t desired_fn_lock;\n\tbool fn_lock;\n\tbool fnlock_ready;\n',
    'state')

old_initialise = '''static int asus_hid_initialise(struct asus_hid_data *data)\n{\n\tu8 command[A14_EC_REPORT_SIZE] = {\n\t\tA14_EC_REPORT_ID, 0xd0, 0x8f, 0x01,\n\t};\n\n\treturn asus_hid_raw_request(data, command, HID_REQ_SET_REPORT);\n}\n\n'''
new_initialise = '''#define A14_HID_FNLOCK_WINDOWS_FULL_FEATURE_REPORT 1
#define A14_HID_FNLOCK_WINDOWS_COMMON_INIT 1
#define A14_HID_WINDOWS_POWER_RESET_SEQUENCE 1
#define A14_HID_NO_POST_RESET_POWER_ON 1

#define A14_I2C_HID_DESC_SIZE             30
#define A14_I2C_HID_COMMAND_REG_OFFSET    16
#define A14_I2C_HID_CMD_POWER_ON          0x0800
#define A14_I2C_HID_CMD_RESET             0x0100

static int asus_hid_i2c_xfer(struct i2c_client *client,
                             struct i2c_msg *msgs, int num)
{
    int ret = i2c_transfer(client->adapter, msgs, num);

    if (ret == num)
        return 0;
    return ret < 0 ? ret : -EIO;
}

static int asus_hid_i2c_command_register(struct asus_hid_data *data,
                                         struct i2c_client **client_out,
                                         u16 *command_register)
{
    struct hid_device *hdev = data->hdev;
    struct i2c_client *client;
    struct i2c_msg msgs[2];
    u8 addr_buf[2];
    u8 descriptor[A14_I2C_HID_DESC_SIZE];
    u32 descriptor_address;
    int ret;

    if (hdev->bus != BUS_I2C)
        return -EOPNOTSUPP;

    /* i2c-hid stores its transport i2c_client in hid_device::driver_data. */
    client = hdev->driver_data;
    if (!client || !client->adapter)
        return -ENODEV;

    ret = device_property_read_u32(&client->dev, "hid-descr-addr",
                                   &descriptor_address);
    if (ret)
        return ret;
    if (descriptor_address > U16_MAX)
        return -EINVAL;

    put_unaligned_le16((u16)descriptor_address, addr_buf);
    msgs[0] = (struct i2c_msg) {
        .addr = client->addr,
        .flags = client->flags & I2C_M_TEN,
        .len = sizeof(addr_buf),
        .buf = addr_buf,
    };
    msgs[1] = (struct i2c_msg) {
        .addr = client->addr,
        .flags = (client->flags & I2C_M_TEN) | I2C_M_RD,
        .len = sizeof(descriptor),
        .buf = descriptor,
    };

    ret = asus_hid_i2c_xfer(client, msgs, ARRAY_SIZE(msgs));
    if (ret)
        return ret;
    if (get_unaligned_le16(descriptor) != A14_I2C_HID_DESC_SIZE ||
        get_unaligned_le16(descriptor + 2) != 0x0100)
        return -EPROTO;

    *command_register = get_unaligned_le16(
        descriptor + A14_I2C_HID_COMMAND_REG_OFFSET);
    *client_out = client;
    return 0;
}

static int asus_hid_i2c_send_command(struct i2c_client *client,
                                     u16 command_register, u16 command)
{
    struct i2c_msg msg;
    u8 buffer[4];

    put_unaligned_le16(command_register, buffer);
    put_unaligned_le16(command, buffer + 2);
    msg = (struct i2c_msg) {
        .addr = client->addr,
        .flags = client->flags & I2C_M_TEN,
        .len = sizeof(buffer),
        .buf = buffer,
    };
    return asus_hid_i2c_xfer(client, &msg, 1);
}

static int asus_hid_windows_transport_reinit_hw(struct asus_hid_data *data)
{
    struct i2c_client *client;
    u8 report[A14_EC_REPORT_SIZE];
    u16 command_register;
    int attempt;
    int ret;

    ret = asus_hid_i2c_command_register(data, &client, &command_register);
    if (ret)
        return ret;

    /*
     * Exact hidi2c.sys 10.0.28000.2546 public-symbol path recovered from the
     * matching Microsoft PDB and ARM64 disassembly:
     *
     *   OnD0Entry -> HidInitialize -> _HidPower(0)
     *       command register: 00 08 (SET_POWER ON)
     *   OnPostInterruptsEnabled -> HidReset
     *       command register: 00 01 (RESET)
     *       waits up to 4 seconds for reset completion
     *
     * HidReset does NOT send a second SET_POWER(ON). Linux i2c-hid normally
     * does that in i2c_hid_finish_hwreset(), which is the concrete boot-state
     * difference this A/B removes.
     */
    mutex_lock(&data->io_lock);
    ret = asus_hid_i2c_send_command(client, command_register,
                                    A14_I2C_HID_CMD_POWER_ON);
    mutex_unlock(&data->io_lock);
    if (ret)
        return ret;

    /* Keep the device comfortably awake before reset. The Windows power
     * callback and post-interrupt callback are separate framework stages. */
    msleep(60);

    mutex_lock(&data->io_lock);
    ret = asus_hid_i2c_send_command(client, command_register,
                                    A14_I2C_HID_CMD_RESET);
    mutex_unlock(&data->io_lock);
    if (ret)
        return ret;

    /* The lower i2c-hid IRQ handler consumes the zero-length reset-complete
     * input report even though this upper driver does not own its reset event.
     * Poll a harmless FEATURE GET until the transport is usable, bounded by
     * the same four-second window used by Windows HidReset. Crucially, do not
     * send SET_POWER(ON) after RESET. */
    for (attempt = 0; attempt < 80; attempt++) {
        msleep(50);
        memset(report, 0, sizeof(report));
        report[0] = A14_EC_REPORT_ID;
        ret = asus_hid_raw_request(data, report, HID_REQ_GET_REPORT);
        if (!ret) {
            dev_info(&data->hdev->dev,
                     "Windows HIDI2C reinit ready after %d ms, command-reg=0x%04x (no post-reset POWER_ON)\\n",
                     (attempt + 1) * 50 + 60, command_register);
            return 0;
        }
    }

    return ret ? ret : -ETIMEDOUT;
}

static bool asus_hid_windows_feature_is_known(const u8 *report)
{
    static const u8 initial_string[] = {
        0x5a, 'A', 'S', 'U', 'S', ' ', 'T', 'e', 'c', 'h', '.',
        'I', 'n', 'c', '.', 0x00,
    };

    if (!memcmp(report, initial_string, sizeof(initial_string)))
        return true;
    if (report[0] != A14_EC_REPORT_ID)
        return false;

    switch (report[1]) {
    case 0x05: /* configuration */
    case 0xb0:
    case 0xb1:
    case 0xba: /* keyboard light */
    case 0xbb: /* N-key rollover */
    case 0xc2: /* arrow-key switch */
    case 0xd0: /* Fn switch / status LEDs */
    case 0xf4:
        return true;
    default:
        return false;
    }
}

static int asus_hid_set_arrow_switch_hw(struct asus_hid_data *data, bool enabled)
{
    u8 command[A14_EC_REPORT_SIZE] = {
        A14_EC_REPORT_ID, 0xc2, 0x4b, enabled ? 1 : 0,
    };

    return asus_hid_raw_request(data, command, HID_REQ_SET_REPORT);
}

static int asus_hid_set_fnlock_hw(struct asus_hid_data *data, bool enabled)
{
    u8 command[A14_EC_REPORT_SIZE] = {
        A14_EC_REPORT_ID, 0xd0, 0x4e, enabled ? 1 : 0,
    };

    /* Exact successful Windows call: 0b05:0220, FF31:0076, complete 64-byte
     * FeatureReportByteLength buffer passed to HidD_SetFeature(). */
    return asus_hid_raw_request(data, command, HID_REQ_SET_REPORT);
}

static int asus_hid_windows_common_init(struct asus_hid_data *data,
                                        bool fn_lock)
{
    static const u8 config_prefix[] = { 0x5a, 0x05, 0x20, 0x31, 0x00, 0x08 };
    u8 report[A14_EC_REPORT_SIZE] = { A14_EC_REPORT_ID };
    u8 command[A14_EC_REPORT_SIZE];
    int attempt;
    int ret;

    /* ASUSOptimization 2.1.75.0 first GETs report 0x5a. It sends the initial
     * ASUS Tech.Inc. feature only when the returned feature family is unknown. */
    ret = asus_hid_raw_request(data, report, HID_REQ_GET_REPORT);
    if (ret || !asus_hid_windows_feature_is_known(report)) {
        memset(command, 0, sizeof(command));
        command[0] = A14_EC_REPORT_ID;
        memcpy(command + 1, "ASUS Tech.Inc.", sizeof("ASUS Tech.Inc."));
        ret = asus_hid_raw_request(data, command, HID_REQ_SET_REPORT);
        if (ret)
            return ret;
    }

    for (attempt = 0; attempt < 4; attempt++) {
        memset(command, 0, sizeof(command));
        memcpy(command, config_prefix, sizeof(config_prefix));
        ret = asus_hid_raw_request(data, command, HID_REQ_SET_REPORT);
        if (ret)
            return ret;

        memset(report, 0, sizeof(report));
        report[0] = A14_EC_REPORT_ID;
        ret = asus_hid_raw_request(data, report, HID_REQ_GET_REPORT);
        if (!ret && !memcmp(report, config_prefix, sizeof(config_prefix)))
            break;
        msleep(100);
    }
    if (attempt == 4)
        return ret ? ret : -EPROTO;

    dev_info(&data->hdev->dev,
             "ASUS feature config: %02x %02x %02x (Fn switch next)\\n",
             report[6], report[7], report[8]);

    /* On the captured UX3407RA the response is 01 20 01, so N-key rollover
     * startup is skipped. ASUSOptimization sends ArrowKeySwitch only when its
     * HKLM setting is explicitly present/enabled. -1 therefore means skip. */
    if (fnlock_arrow_switch >= 0) {
        ret = asus_hid_set_arrow_switch_hw(data, fnlock_arrow_switch != 0);
        if (ret)
            return ret;
        dev_info(&data->hdev->dev, "diagnostic ArrowKeySwitch=%d applied\\n",
                 fnlock_arrow_switch != 0);
    }

    return asus_hid_set_fnlock_hw(data, fn_lock);
}

'''
once(old_initialise, new_initialise, 'replace obsolete OOBE initializer')

anchor = '''static int asus_kbd_brightness_set(struct led_classdev *led,\n'''
workers = '''static void asus_fnlock_init_work(struct work_struct *work)
{
    struct asus_hid_data *data = container_of(to_delayed_work(work),
                                               struct asus_hid_data,
                                               fnlock_init_work);
    unsigned int level = atomic_read(&data->desired_brightness);
    bool requested = atomic_read(&data->desired_fn_lock);
    int ret;

    if (READ_ONCE(data->suspended))
        return;

    if (fnlock_windows_transport_reinit) {
        ret = asus_hid_windows_transport_reinit_hw(data);
        if (ret) {
            dev_warn(&data->hdev->dev,
                     "Windows HIDI2C POWER_ON->RESET reinit failed: %d\\n", ret);
            return;
        }
    }

    ret = asus_hid_windows_common_init(data, requested);
    if (ret) {
        dev_warn(&data->hdev->dev, "ASUS Fn-switch common init failed: %d\\n", ret);
        return;
    }

    data->fn_lock = requested;
    WRITE_ONCE(data->fnlock_ready, true);
    dev_info(&data->hdev->dev, "Fn-lock hardware path ready, state=%u\\n",
             requested ? 1 : 0);

    ret = asus_hid_set_backlight_hw(data, level);
    if (ret)
        dev_warn(&data->hdev->dev,
                 "keyboard-backlight restore after Fn init failed: %d\\n", ret);
}

static void asus_fnlock_work(struct work_struct *work)
{
    struct asus_hid_data *data = container_of(work, struct asus_hid_data,
                                               fnlock_work);
    bool requested = atomic_read(&data->desired_fn_lock);
    int ret;

    if (READ_ONCE(data->suspended))
        return;
    if (!READ_ONCE(data->fnlock_ready)) {
        mod_delayed_work(system_wq, &data->fnlock_init_work, 0);
        return;
    }

    ret = asus_hid_set_fnlock_hw(data, requested);
    if (ret) {
        atomic_set(&data->desired_fn_lock, data->fn_lock);
        dev_warn(&data->hdev->dev, "Fn-lock update failed: %d\\n", ret);
        return;
    }
    data->fn_lock = requested;
    dev_info(&data->hdev->dev, "Fn-lock hardware state=%u\\n",
             requested ? 1 : 0);
}

'''
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
    '\tWRITE_ONCE(data->suspended, true);\n\tcancel_work_sync(&data->backlight_work);\n\tcancel_work_sync(&data->fnlock_work);\n\tcancel_delayed_work_sync(&data->fnlock_init_work);\n\tWRITE_ONCE(data->fnlock_ready, false);\n',
    'suspend')

old_resume = '''static int asus_hid_resume(struct hid_device *hdev)\n{\n\tstruct asus_hid_data *data = hid_get_drvdata(hdev);\n\tunsigned int level = atomic_read(&data->desired_brightness);\n\tint ret;\n\tint attempt;\n\n\tmsleep(100);\n\tfor (attempt = 0; attempt < 5; attempt++) {\n\t\tret = asus_hid_initialise(data);\n\t\tif (!ret)\n\t\t\tbreak;\n\t\tmsleep(100 * (attempt + 1));\n\t}\n\tWRITE_ONCE(data->suspended, false);\n\tif (ret)\n\t\treturn ret;\n\treturn asus_hid_set_backlight_hw(data, level);\n}\n'''
new_resume = '''static int asus_hid_resume(struct hid_device *hdev)
{
    struct asus_hid_data *data = hid_get_drvdata(hdev);

    WRITE_ONCE(data->suspended, false);
    WRITE_ONCE(data->fnlock_ready, false);
    mod_delayed_work(system_wq, &data->fnlock_init_work,
                     msecs_to_jiffies(250));
    return 0;
}
'''
once(old_resume, new_resume, 'resume')

once(
    '\tINIT_WORK(&data->backlight_work, asus_backlight_work);\n\tatomic_set(&data->desired_brightness,\n',
    '\tINIT_WORK(&data->backlight_work, asus_backlight_work);\n\tINIT_WORK(&data->fnlock_work, asus_fnlock_work);\n\tINIT_DELAYED_WORK(&data->fnlock_init_work, asus_fnlock_init_work);\n\tatomic_set(&data->desired_fn_lock, 0);\n\tdata->fn_lock = false;\n\tdata->fnlock_ready = false;\n\tatomic_set(&data->desired_brightness,\n',
    'probe init')

once(
    '''\tret = asus_hid_initialise(data);\n\tif (ret)\n\t\tgoto err_led;\n\tret = asus_hid_set_backlight_hw(data,\n\t\t\t\t\tatomic_read(&data->desired_brightness));\n\tif (ret)\n\t\tgoto err_led;\n\n\tif (enable_debug_commands) {\n''',
    '''\tret = asus_hid_set_backlight_hw(data,\n\t\t\t\t\tatomic_read(&data->desired_brightness));\n\tif (ret)\n\t\tgoto err_led;\n\n\t/* Let hid_add_device()/the transport's initial power callbacks finish,\n\t * then recreate the exact Windows POWER_ON->RESET ordering and ASUS\n\t * startup feature sequence in process context. */\n\tmod_delayed_work(system_wq, &data->fnlock_init_work,\n\t\t\t msecs_to_jiffies(250));\n\n\tif (enable_debug_commands) {\n''',
    'probe hardware init')

once(
    '\tcancel_work_sync(&data->backlight_work);\n\tif (data->led_registered)\n',
    '\tcancel_work_sync(&data->backlight_work);\n\tcancel_work_sync(&data->fnlock_work);\n\tcancel_delayed_work_sync(&data->fnlock_init_work);\n\tif (data->led_registered)\n',
    'remove')

required = (
    'A14_HID_FNLOCK_WINDOWS_FULL_FEATURE_REPORT',
    'A14_HID_FNLOCK_WINDOWS_COMMON_INIT',
    'A14_HID_WINDOWS_POWER_RESET_SEQUENCE',
    'A14_HID_NO_POST_RESET_POWER_ON',
    'static int asus_hid_windows_transport_reinit_hw',
    'A14_I2C_HID_CMD_POWER_ON',
    'A14_I2C_HID_CMD_RESET',
    'static int asus_hid_windows_common_init',
    'static int asus_hid_set_fnlock_hw',
    'struct delayed_work fnlock_init_work;',
    'INIT_DELAYED_WORK(&data->fnlock_init_work, asus_fnlock_init_work);',
    'schedule_work(&data->fnlock_work);',
    'no post-reset POWER_ON',
)
missing = [token for token in required if token not in s]
if missing:
    raise SystemExit('Fn-lock Windows transport transform incomplete: ' + ', '.join(missing))

forbidden = (
    'A14_HID_QTEC_POST_HID_REPOWER',
    'asus_hid_qtec_post_init_repower',
    '0xd0, 0x8f, 0x01',
)
stale = [token for token in forbidden if token in s]
if stale:
    raise SystemExit('Fn-lock stale/disproven transport path remains: ' + ', '.join(stale))

p.write_text(s)
print('a14_hid_fnlock=windows-power-on-reset-no-post-power-plus-asus-startup')
