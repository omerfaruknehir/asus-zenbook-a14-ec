#!/usr/bin/env python3
from pathlib import Path

p = Path("hid_asus_ec.c")
if not p.is_file():
    raise SystemExit("run from the repository root")

s = p.read_text()

if "A14_HID_RESET_RESUME_HARDENING" in s:
    print("a14_hid_reset_resume=current")
    raise SystemExit(0)

if "A14_HID_LIFECYCLE_HARDENING" not in s:
    raise SystemExit("reset-resume hardening requires lifecycle-hardened HID source")

old = "#define A14_HID_LIFECYCLE_HARDENING 1\n"
new = old + "#define A14_HID_RESET_RESUME_HARDENING 1\n"
if s.count(old) != 1:
    raise SystemExit(f"lifecycle marker: expected one anchor, found {s.count(old)}")
s = s.replace(old, new, 1)

old_suspend = '''static int asus_hid_suspend(struct hid_device *hdev, pm_message_t message)
{
\tstruct asus_hid_data *data = hid_get_drvdata(hdev);

\tWRITE_ONCE(data->suspended, true);
\tWRITE_ONCE(data->fnlock_ready, false);
\tdata->fnlock_init_attempts = 0;
\tcancel_delayed_work_sync(&data->fnlock_init_work);
\tcancel_work_sync(&data->fnlock_work);
\tcancel_work_sync(&data->backlight_work);
\t(void)asus_hid_set_backlight_hw(data, 0);
\treturn 0;
}
'''
new_suspend = '''static int asus_hid_suspend(struct hid_device *hdev, pm_message_t message)
{
\tstruct asus_hid_data *data = hid_get_drvdata(hdev);

\tdev_info(&hdev->dev,
\t\t "lifecycle: suspend, Fn-lock=%u, backlight=%u\\n",
\t\t atomic_read(&data->desired_fn_lock) ? 1 : 0,
\t\t atomic_read(&data->desired_brightness));
\tWRITE_ONCE(data->suspended, true);
\tWRITE_ONCE(data->fnlock_ready, false);
\tdata->fnlock_init_attempts = 0;
\tcancel_delayed_work_sync(&data->fnlock_init_work);
\tcancel_work_sync(&data->fnlock_work);
\tcancel_work_sync(&data->backlight_work);
\t(void)asus_hid_set_backlight_hw(data, 0);
\treturn 0;
}
'''
if old_suspend not in s:
    raise SystemExit("lifecycle suspend function anchor missing")
s = s.replace(old_suspend, new_suspend, 1)

old_resume = '''static int asus_hid_resume(struct hid_device *hdev)
{
    struct asus_hid_data *data = hid_get_drvdata(hdev);

    WRITE_ONCE(data->suspended, false);
    WRITE_ONCE(data->fnlock_ready, false);
    data->fnlock_init_attempts = 0;

    /* GENI/I2C-HID runtime PM can complete after the HID driver's resume
     * callback. Start shortly afterwards and self-retry instead of making one
     * irreversible 250 ms guess. */
    mod_delayed_work(system_wq, &data->fnlock_init_work,
                     msecs_to_jiffies(100));
    return 0;
}
'''
new_resume = '''static int asus_hid_schedule_resume_recovery(struct hid_device *hdev,
                                             const char *path)
{
    struct asus_hid_data *data = hid_get_drvdata(hdev);

    WRITE_ONCE(data->suspended, false);
    WRITE_ONCE(data->fnlock_ready, false);
    data->fnlock_init_attempts = 0;

    dev_info(&hdev->dev,
             "lifecycle: %s, scheduling ASUS vendor restore; Fn-lock=%u, backlight=%u\\n",
             path,
             atomic_read(&data->desired_fn_lock) ? 1 : 0,
             atomic_read(&data->desired_brightness));

    /* The transport may finish resuming after the HID callback. The worker is
     * retry-capable, so both ordinary resume and HID reset-resume converge on
     * the same vendor-protocol reconstruction path. */
    mod_delayed_work(system_wq, &data->fnlock_init_work,
                     msecs_to_jiffies(100));
    return 0;
}

static int asus_hid_resume(struct hid_device *hdev)
{
    return asus_hid_schedule_resume_recovery(hdev, "resume");
}

static int asus_hid_reset_resume(struct hid_device *hdev)
{
    return asus_hid_schedule_resume_recovery(hdev, "reset-resume");
}
'''
if old_resume not in s:
    raise SystemExit("lifecycle resume function anchor missing")
s = s.replace(old_resume, new_resume, 1)

old_driver = '''\t.suspend = asus_hid_suspend,
\t.resume = asus_hid_resume,
};
'''
new_driver = '''\t.suspend = asus_hid_suspend,
\t.resume = asus_hid_resume,
\t.reset_resume = asus_hid_reset_resume,
};
'''
if old_driver not in s:
    raise SystemExit("hid_driver PM callback anchor missing")
s = s.replace(old_driver, new_driver, 1)

p.write_text(s)
print("a14_hid_reset_resume=applied")
