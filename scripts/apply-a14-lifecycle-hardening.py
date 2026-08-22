#!/usr/bin/env python3
from pathlib import Path

EC = Path("asus_zenbook_a14_ec.c")
HID = Path("hid_asus_ec.c")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one anchor, found {count}")
    return text.replace(old, new, 1)


def replace_function(text: str, start_token: str, next_token: str,
                     replacement: str, label: str) -> str:
    start = text.find(start_token)
    if start < 0:
        raise SystemExit(f"{label}: start token missing")
    end = text.find(next_token, start)
    if end < 0:
        raise SystemExit(f"{label}: end token missing")
    return text[:start] + replacement + "\n\n" + text[end:]


def harden_hid() -> None:
    h = HID.read_text()
    if "A14_HID_LIFECYCLE_HARDENING" in h:
        print("a14_hid_lifecycle=current")
        return
    if "A14_HID_FNLOCK_WINDOWS_COMMON_INIT" not in h:
        raise SystemExit("HID lifecycle hardening requires composed Fn-lock support")

    h = replace_once(
        h,
        "#define A14_HID_NO_POST_RESET_POWER_ON 1\n",
        "#define A14_HID_NO_POST_RESET_POWER_ON 1\n"
        "#define A14_HID_LIFECYCLE_HARDENING 1\n"
        "#define A14_HID_INIT_RETRY_MAX          20\n"
        "#define A14_HID_INIT_RETRY_MS           200\n",
        "HID lifecycle constants",
    )
    h = replace_once(
        h,
        "\tbool fnlock_ready;\n",
        "\tbool fnlock_ready;\n\tunsigned int fnlock_init_attempts;\n",
        "HID init retry state",
    )

    start = h.find("static int asus_kbd_brightness_set(struct led_classdev *led,")
    end = h.find("static enum led_brightness asus_kbd_brightness_get", start)
    if start < 0 or end < 0:
        raise SystemExit("brightness-set function boundaries missing")
    segment = h[start:end]
    old = "\tif (READ_ONCE(data->suspended))\n\t\treturn 0;\n"
    new = "\tif (READ_ONCE(data->suspended) || !READ_ONCE(data->fnlock_ready))\n\t\treturn 0;\n"
    if old not in segment:
        raise SystemExit("brightness-set lifecycle gate missing")
    segment = segment.replace(old, new, 1)
    h = h[:start] + segment + h[end:]

    start = h.find("static void asus_backlight_work(struct work_struct *work)")
    end = h.find("static void asus_emit_key", start)
    if start < 0 or end < 0:
        raise SystemExit("backlight-work function boundaries missing")
    segment = h[start:end]
    old = "\tif (READ_ONCE(data->suspended))\n\t\treturn;\n"
    new = "\tif (READ_ONCE(data->suspended) || !READ_ONCE(data->fnlock_ready))\n\t\treturn;\n"
    if old not in segment:
        raise SystemExit("backlight-work lifecycle gate missing")
    segment = segment.replace(old, new, 1)
    h = h[:start] + segment + h[end:]

    init_worker = r'''static void asus_fnlock_init_retry(struct asus_hid_data *data,
                                  const char *stage, int error)
{
    unsigned int attempt;

    WRITE_ONCE(data->fnlock_ready, false);
    if (READ_ONCE(data->suspended))
        return;

    attempt = ++data->fnlock_init_attempts;
    if (attempt >= A14_HID_INIT_RETRY_MAX) {
        dev_err(&data->hdev->dev,
                "ASUS vendor init gave up after %u attempts at %s: %d\n",
                attempt, stage, error);
        return;
    }

    dev_warn_ratelimited(&data->hdev->dev,
                         "ASUS vendor init attempt %u/%u failed at %s: %d; retrying\n",
                         attempt, A14_HID_INIT_RETRY_MAX, stage, error);
    mod_delayed_work(system_wq, &data->fnlock_init_work,
                     msecs_to_jiffies(A14_HID_INIT_RETRY_MS));
}

static void asus_fnlock_init_work(struct work_struct *work)
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
            asus_fnlock_init_retry(data, "optional HIDI2C reinit", ret);
            return;
        }
    }

    ret = asus_hid_windows_common_init(data, requested);
    if (ret) {
        asus_fnlock_init_retry(data, "ASUS feature init", ret);
        return;
    }

    data->fn_lock = requested;

    /* BIOS 312 lifecycle order is vendor init -> logical Fn restore ->
     * keyboard-light restore -> ready. Do not let userspace/hotkey work race
     * the feature protocol before all three stages are usable. */
    ret = asus_hid_set_backlight_hw(data, level);
    if (ret) {
        asus_fnlock_init_retry(data, "keyboard-backlight restore", ret);
        return;
    }

    data->fnlock_init_attempts = 0;
    WRITE_ONCE(data->fnlock_ready, true);
    led_classdev_notify_brightness_hw_changed(&data->keyboard_led, level);
    dev_info(&data->hdev->dev,
             "ASUS vendor path ready, Fn-lock state=%u, backlight=%u\n",
             requested ? 1 : 0, level);
}'''
    h = replace_function(
        h,
        "static void asus_fnlock_init_work(struct work_struct *work)",
        "static void asus_fnlock_work(struct work_struct *work)",
        init_worker,
        "Fn-lock init worker",
    )

    start = h.find("static int asus_raw_event(struct hid_device *hdev,")
    end = h.find("static ssize_t hid_cmd_store", start)
    if start < 0 or end < 0:
        raise SystemExit("raw-event function boundaries missing")
    segment = h[start:end]
    gate_anchor = "\tusage = raw_data[1];\n\n"
    gate = (
        "\tusage = raw_data[1];\n\n"
        "\t/* Suspend/resume may leave the transport alive before the ASUS\n"
        "\t * feature protocol is reconstructed. Consume vendor reports during\n"
        "\t * that window rather than racing stale state into userspace. */\n"
        "\tif (!READ_ONCE(data->fnlock_ready))\n"
        "\t\treturn 1;\n\n"
    )
    if gate_anchor not in segment:
        raise SystemExit("raw-event ready-gate anchor missing")
    segment = segment.replace(gate_anchor, gate, 1)
    h = h[:start] + segment + h[end:]

    start = h.find("static int asus_hid_suspend(struct hid_device *hdev,")
    end = h.find("static int asus_hid_resume", start)
    if start < 0 or end < 0:
        raise SystemExit("HID suspend boundaries missing")
    segment = h[start:end]
    anchor = "\tWRITE_ONCE(data->fnlock_ready, false);\n"
    if anchor not in segment:
        raise SystemExit("HID suspend ready reset missing")
    segment = segment.replace(
        anchor,
        anchor + "\tdata->fnlock_init_attempts = 0;\n",
        1,
    )
    h = h[:start] + segment + h[end:]

    resume = r'''static int asus_hid_resume(struct hid_device *hdev)
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
}'''
    h = replace_function(
        h,
        "static int asus_hid_resume(struct hid_device *hdev)",
        "static int asus_hid_probe(struct hid_device *hdev,",
        resume,
        "HID resume",
    )

    h = replace_once(
        h,
        "\tdata->fn_lock = false;\n\tdata->fnlock_ready = false;\n",
        "\tdata->fn_lock = false;\n\tdata->fnlock_ready = false;\n"
        "\tdata->fnlock_init_attempts = 0;\n",
        "HID probe retry initialization",
    )

    preinit_backlight = (
        "\tret = asus_hid_set_backlight_hw(data,\n"
        "\t\t\t\t\tatomic_read(&data->desired_brightness));\n"
        "\tif (ret)\n"
        "\t\tgoto err_led;\n\n"
    )
    if h.count(preinit_backlight) != 1:
        raise SystemExit(
            f"pre-init backlight block: expected one anchor, found {h.count(preinit_backlight)}"
        )
    h = h.replace(preinit_backlight, "", 1)

    HID.write_text(h)
    print("a14_hid_lifecycle=applied")


def harden_ec() -> None:
    s = EC.read_text()
    if "A14_EC_LIFECYCLE_HARDENING" in s:
        print("a14_ec_lifecycle=current")
        return
    if "A14_WHISPER_MODE" not in s or "static void asus_ec_whisper_work" not in s:
        raise SystemExit("EC lifecycle hardening requires the final Whisper/native profile stack")

    s = replace_once(
        s,
        "#define A14_WHISPER_MODE 1\n",
        "#define A14_WHISPER_MODE 1\n"
        "#define A14_EC_LIFECYCLE_HARDENING 1\n"
        "#define A14_EC_RESUME_RETRY_MAX       20\n"
        "#define A14_EC_RESUME_RETRY_MS        250\n",
        "EC lifecycle constants",
    )
    s = replace_once(
        s,
        "\tstruct delayed_work whisper_work;\n",
        "\tstruct delayed_work whisper_work;\n"
        "\tstruct delayed_work resume_work;\n"
        "\tunsigned int resume_retries;\n",
        "EC resume-work state",
    )

    lifecycle_helpers = r'''static int asus_ec_resume_ready(struct asus_ec *ec)
{
    u8 mode;
    u8 temp;
    int ret;

    ret = asus_ec_read_reg(ec, EC_REG_FAN_MODE_MAJ,
                           EC_REG_FAN_MODE_RMIN, &mode);
    if (ret)
        return ret;
    return asus_ec_read_reg(ec, EC_REG_TEMP_MAJ, EC_REG_TEMP_MIN, &temp);
}

static void asus_ec_resume_work(struct work_struct *work)
{
    struct asus_ec *ec = container_of(to_delayed_work(work),
                                      struct asus_ec, resume_work);
    enum asus_ec_profile profile;
    bool custom_to_normal = false;
    bool fallback = false;
    int ret;

    mutex_lock(&ec->mode_lock);
    if (ec->shutting_down) {
        mutex_unlock(&ec->mode_lock);
        return;
    }
    profile = ec->active_profile;
    if (profile == ASUS_EC_PROFILE_CUSTOM) {
        profile = ASUS_EC_PROFILE_BALANCED;
        custom_to_normal = true;
    }
    mutex_unlock(&ec->mode_lock);

    ret = asus_ec_resume_ready(ec);
    if (!ret) {
        mutex_lock(&ec->mode_lock);
        if (!ec->shutting_down) {
            /* Re-read the logical profile in case userspace changed it while
             * the EC transport was recovering. */
            profile = ec->active_profile;
            custom_to_normal = profile == ASUS_EC_PROFILE_CUSTOM;
            if (custom_to_normal)
                profile = ASUS_EC_PROFILE_BALANCED;
            ret = asus_ec_apply_profile_locked(ec, profile);
        }
        mutex_unlock(&ec->mode_lock);
    }

    if (!ret) {
        ec->resume_retries = 0;
        if (custom_to_normal) {
            sysfs_notify(&ec->dev->kobj, NULL, "profile");
            asus_ec_notify_profile(ec);
        }
        dev_info(ec->dev, "resume: EC policy restored (%s)\n",
                 asus_ec_profile_name(profile));
        return;
    }

    if (++ec->resume_retries < A14_EC_RESUME_RETRY_MAX) {
        dev_warn_ratelimited(ec->dev,
                             "resume: EC not ready/policy replay failed (%d), retry %u/%u\n",
                             ret, ec->resume_retries,
                             A14_EC_RESUME_RETRY_MAX);
        mod_delayed_work(system_freezable_wq, &ec->resume_work,
                         msecs_to_jiffies(A14_EC_RESUME_RETRY_MS));
        return;
    }

    /* We deliberately stopped replaying custom manual PWM before suspend. If
     * the desired named mode still cannot be reconstructed, make one final
     * attempt at firmware AUTO + native Normal rather than leaving Linux in a
     * half-restored software state. */
    mutex_lock(&ec->mode_lock);
    if (!ec->shutting_down) {
        ret = asus_ec_apply_profile_locked(ec, ASUS_EC_PROFILE_BALANCED);
        if (!ret)
            fallback = true;
    }
    mutex_unlock(&ec->mode_lock);

    if (fallback) {
        sysfs_notify(&ec->dev->kobj, NULL, "profile");
        asus_ec_notify_profile(ec);
        dev_warn(ec->dev,
                 "resume: desired profile could not be restored; fell back to native Normal\n");
    } else {
        dev_err(ec->dev,
                "resume: EC recovery exhausted and native Normal fallback failed: %d\n",
                ret);
    }
}'''
    quiesce_token = "static void asus_ec_quiesce(struct asus_ec *ec)"
    pos = s.find(quiesce_token)
    if pos < 0:
        raise SystemExit("EC quiesce function missing")
    s = s[:pos] + lifecycle_helpers + "\n\n" + s[pos:]

    start = s.find(quiesce_token)
    end = s.find("static int asus_ec_probe(struct platform_device *pdev)", start)
    if start < 0 or end < 0:
        raise SystemExit("EC quiesce boundaries missing")
    segment = s[start:end]
    anchor = "\tcancel_delayed_work_sync(&ec->safety_work);\n"
    if anchor not in segment:
        raise SystemExit("EC quiesce safety cancellation missing")
    segment = segment.replace(
        anchor,
        anchor
        + "\tcancel_delayed_work_sync(&ec->whisper_work);\n"
        + "\tcancel_delayed_work_sync(&ec->resume_work);\n",
        1,
    )
    s = s[:start] + segment + s[end:]

    probe_start = s.find("static int asus_ec_probe(struct platform_device *pdev)")
    probe_end = s.find("static void asus_ec_remove", probe_start)
    if probe_start < 0 or probe_end < 0:
        raise SystemExit("EC probe boundaries missing")
    segment = s[probe_start:probe_end]
    anchor = "\tINIT_DELAYED_WORK(&ec->whisper_work, asus_ec_whisper_work);\n"
    if anchor not in segment:
        raise SystemExit("Whisper worker initialization missing")
    segment = segment.replace(
        anchor,
        anchor + "\tINIT_DELAYED_WORK(&ec->resume_work, asus_ec_resume_work);\n"
        + "\tec->resume_retries = 0;\n",
        1,
    )
    s = s[:probe_start] + segment + s[probe_end:]

    suspend = r'''static int asus_ec_suspend(struct device *dev)
{
    struct asus_ec *ec = dev_get_drvdata(dev);
    enum asus_ec_profile profile;
    int ret;

    cancel_delayed_work_sync(&ec->resume_work);
    cancel_delayed_work_sync(&ec->safety_work);
    cancel_delayed_work_sync(&ec->whisper_work);

    mutex_lock(&ec->mode_lock);
    profile = ec->active_profile;
    ret = asus_ec_leave_manual_locked(ec);
    if (ret && ec->manual_active) {
        if (profile == ASUS_EC_PROFILE_WHISPER)
            mod_delayed_work(system_freezable_wq, &ec->whisper_work,
                             msecs_to_jiffies(250));
        else
            mod_delayed_work(system_freezable_wq, &ec->safety_work,
                             msecs_to_jiffies(500));
    }
    mutex_unlock(&ec->mode_lock);
    if (ret) {
        dev_err(ec->dev,
                "refusing suspend: automatic fan mode restore failed: %d\n",
                ret);
        return ret;
    }

    ret = asus_ec_mailbox_quiesce(ec);
    if (ret) {
        int restore_ret;

        dev_err(ec->dev,
                "refusing suspend: EC mailbox quiesce failed: %d\n", ret);
        mutex_lock(&ec->mode_lock);
        if (profile == ASUS_EC_PROFILE_CUSTOM) {
            restore_ret = asus_ec_apply_profile_locked(
                ec, ASUS_EC_PROFILE_BALANCED);
        } else {
            /* Suspend may already have changed fan ownership (notably
             * Whisper). Reconstruct the complete named policy on abort. */
            restore_ret = asus_ec_apply_profile_locked(ec, profile);
        }
        mutex_unlock(&ec->mode_lock);
        if (restore_ret)
            dev_err(ec->dev,
                    "failed to restore pre-suspend policy after abort: %d\n",
                    restore_ret);
        else if (profile == ASUS_EC_PROFILE_CUSTOM) {
            sysfs_notify(&ec->dev->kobj, NULL, "profile");
            asus_ec_notify_profile(ec);
        }
        return ret;
    }

    return 0;
}'''
    s = replace_function(
        s,
        "static int asus_ec_suspend(struct device *dev)",
        "static int asus_ec_resume(struct device *dev)",
        suspend,
        "EC suspend",
    )

    resume = r'''static int asus_ec_resume(struct device *dev)
{
    struct asus_ec *ec = dev_get_drvdata(dev);

    /* Resume the policy only after GENI/EC transport is actually responsive.
     * A fixed sleep followed by one write is fragile on this platform; use a
     * bounded asynchronous recovery loop so system resume itself is never held
     * hostage by a late EC controller. */
    ec->resume_retries = 0;
    mod_delayed_work(system_freezable_wq, &ec->resume_work,
                     msecs_to_jiffies(150));
    return 0;
}'''
    s = replace_function(
        s,
        "static int asus_ec_resume(struct device *dev)",
        "static DEFINE_SIMPLE_DEV_PM_OPS",
        resume,
        "EC resume",
    )

    EC.write_text(s)
    print("a14_ec_lifecycle=applied")


def main() -> None:
    if not EC.is_file() or not HID.is_file():
        raise SystemExit("run from the repository root")
    harden_hid()
    harden_ec()
    print("a14_lifecycle_hardening=current")


if __name__ == "__main__":
    main()
