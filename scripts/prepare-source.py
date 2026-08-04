#!/usr/bin/env python3
"""Prepare hardened out-of-tree module sources.

The reverse-engineering baseline remains readable in the repository. This
script applies production safety fixes to an isolated build copy and refuses
to continue when the expected baseline has changed.
"""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)


def patch_ec(text: str) -> str:
    text = replace_once(
        text,
        "#define PP_MAX_FREQ_KHZ\t\t3417600\t/* uncapped (full boost) */\n",
        "#define PP_MAX_FREQ_KHZ\t\tFREQ_QOS_MAX_DEFAULT_VALUE\t/* remove our cap */\n",
        "dynamic maximum CPU frequency",
    )
    text = replace_once(
        text,
        "#define PP_MAX_POLICIES\t\t4\t/* X1E: 3 clusters, room for 4 */\n",
        "#define PP_MAX_POLICIES\t\t4\t/* X1E: 3 clusters, room for 4 */\n\n"
        "/* Delay direct EC access after module load. Early boot I2C access has\n"
        " * caused hard hangs on warm boots on at least one A14 variant.\n"
        " */\n"
        "static unsigned int probe_delay_ms = 1500;\n"
        "module_param(probe_delay_ms, uint, 0644);\n"
        "MODULE_PARM_DESC(probe_delay_ms,\n"
        "\t\t \"Delay before the first direct EC transaction (0-30000 ms)\");\n",
        "probe delay module parameter",
    )
    text = replace_once(
        text,
        " *   QUIET        → manual PWM 0 (fans off) + CPU capped to 1.44 GHz\n"
        " *   BALANCED     → auto mode (EC thermal curve) + CPU uncapped\n"
        " *   PERFORMANCE  → manual PWM 180 (~2400 RPM) + CPU uncapped\n",
        " *   QUIET        → minimum stable fan speed + CPU capped to 1.44 GHz\n"
        " *   BALANCED     → auto mode (EC thermal curve) + CPU uncapped\n"
        " *   PERFORMANCE  → manual PWM 180 (~2400 RPM) + CPU uncapped\n",
        "profile documentation",
    )
    text = replace_once(
        text,
        "#define PP_QUIET_PWM\t0\t/* fans off — passive cooling at capped freq */\n",
        "#define PP_QUIET_PWM\t80\t/* calibrated near-silent stable floor */\n",
        "quiet profile fan floor",
    )
    text = replace_once(
        text,
        "\tplatform_set_drvdata(pdev, ec);\n\n\tasus_ec_lookup_thermal_zones(ec);\n",
        "\tplatform_set_drvdata(pdev, ec);\n\n"
        "\tif (probe_delay_ms) {\n"
        "\t\tunsigned int delay = min(probe_delay_ms, 30000U);\n\n"
        "\t\tdev_info(dev, \"delaying direct EC access by %u ms\\n\", delay);\n"
        "\t\tmsleep(delay);\n"
        "\t}\n\n"
        "\tasus_ec_lookup_thermal_zones(ec);\n",
        "late direct EC probe",
    )
    text = replace_once(
        text,
        "\t\tu8 tach0, tach1, pwm0, pwm1;\n\n"
        "\t\t(void)asus_ec_read_fan_reg(ec, 0, EC_REG_FAN_TACH_MIN, &tach0);\n"
        "\t\t(void)asus_ec_read_fan_reg(ec, 1, EC_REG_FAN_TACH_MIN, &tach1);\n"
        "\t\t(void)asus_ec_read_fan_reg(ec, 0, EC_REG_PWM_RMIN, &pwm0);\n"
        "\t\t(void)asus_ec_read_fan_reg(ec, 1, EC_REG_PWM_RMIN, &pwm1);\n"
        "\t\t(void)asus_ec_read_reg(ec, EC_REG_TEMP_MAJ, EC_REG_TEMP_MIN, &temp);\n"
        "\t\t(void)asus_ec_read_reg(ec, EC_REG_FAN_MODE_MAJ,\n"
        "\t\t\t\t       EC_REG_FAN_MODE_RMIN, &mode);\n",
        "\t\tu8 tach0 = 0, tach1 = 0, pwm0 = 0, pwm1 = 0;\n\n"
        "\t\tif (asus_ec_read_fan_reg(ec, 0, EC_REG_FAN_TACH_MIN, &tach0))\n"
        "\t\t\tdev_warn(dev, \"failed to read left fan tach\\n\");\n"
        "\t\tif (asus_ec_read_fan_reg(ec, 1, EC_REG_FAN_TACH_MIN, &tach1))\n"
        "\t\t\tdev_warn(dev, \"failed to read right fan tach\\n\");\n"
        "\t\tif (asus_ec_read_fan_reg(ec, 0, EC_REG_PWM_RMIN, &pwm0))\n"
        "\t\t\tdev_warn(dev, \"failed to read left fan PWM\\n\");\n"
        "\t\tif (asus_ec_read_fan_reg(ec, 1, EC_REG_PWM_RMIN, &pwm1))\n"
        "\t\t\tdev_warn(dev, \"failed to read right fan PWM\\n\");\n"
        "\t\tif (asus_ec_read_reg(ec, EC_REG_TEMP_MAJ, EC_REG_TEMP_MIN, &temp))\n"
        "\t\t\tdev_warn(dev, \"failed to read EC temperature\\n\");\n"
        "\t\tif (asus_ec_read_reg(ec, EC_REG_FAN_MODE_MAJ,\n"
        "\t\t\t\t     EC_REG_FAN_MODE_RMIN, &mode))\n"
        "\t\t\tdev_warn(dev, \"failed to read EC fan mode\\n\");\n",
        "initialized probe telemetry",
    )
    text = replace_once(
        text,
        "\t\tspeed = (u8)val;\n\n\t\tmutex_lock(&ec->mode_lock);\n",
        "\t\tspeed = (u8)val;\n"
        "\t\tif (speed > 0 && speed < EC_PWM_SPIN_FLOOR)\n"
        "\t\t\treturn -ERANGE;\n\n"
        "\t\tmutex_lock(&ec->mode_lock);\n",
        "reject unstable PWM values",
    )

    marker = (
        "/* ------------------------------------------------------------------ */\n"
        "/* probe / remove                                                     */\n"
        "/* ------------------------------------------------------------------ */\n"
    )
    safety = (
        "static void asus_ec_quiesce(struct asus_ec *ec, const char *reason)\n"
        "{\n"
        "\tint ret;\n\n"
        "\tmutex_lock(&ec->mode_lock);\n"
        "\tret = asus_ec_set_fan_mode(ec, EC_FAN_MODE_AUTO);\n"
        "\tif (ret)\n"
        "\t\tdev_warn(ec->dev, \"%s: failed to restore automatic fan mode: %d\\n\",\n"
        "\t\t\t reason, ret);\n"
        "\telse\n"
        "\t\tec->manual_active = false;\n"
        "\tasus_ec_stop_watchdog(ec);\n"
        "\tmutex_unlock(&ec->mode_lock);\n\n"
        "\t/* FREQ_QOS_MAX_DEFAULT_VALUE removes this driver's frequency cap. */\n"
        "\t(void)asus_ec_freq_qos_set(ec, PP_MAX_FREQ_KHZ);\n"
        "}\n\n"
        "static void asus_ec_shutdown(struct platform_device *pdev)\n"
        "{\n"
        "\tstruct asus_ec *ec = platform_get_drvdata(pdev);\n\n"
        "\tif (!ec)\n"
        "\t\treturn;\n\n"
        "\t/* Modules are not removed during reboot. Explicitly leave the EC in\n"
        "\t * automatic mode so the next kernel does not inherit manual state.\n"
        "\t */\n"
        "\tasus_ec_quiesce(ec, \"shutdown\");\n"
        "}\n\n"
        + marker
    )
    text = replace_once(text, marker, safety, "shutdown quiesce hook")
    text = replace_once(
        text,
        "\t/* Always restore auto + stop watchdog before tearing down. */\n"
        "\tmutex_lock(&ec->mode_lock);\n"
        "\tif (ec->manual_active)\n"
        "\t\t(void)asus_ec_leave_manual(ec);\n"
        "\telse\n"
        "\t\tasus_ec_stop_watchdog(ec);\n"
        "\tmutex_unlock(&ec->mode_lock);\n\n"
        "\t/* Restore CPU freq to uncapped before removing. */\n"
        "\tasus_ec_freq_qos_set(ec, PP_MAX_FREQ_KHZ);\n",
        "\t/* Restore firmware-owned fan control before tearing down. */\n"
        "\tasus_ec_quiesce(ec, \"remove\");\n",
        "shared remove quiesce path",
    )
    text = replace_once(
        text,
        "\t.probe\t= asus_ec_probe,\n\t.remove\t= asus_ec_remove,\n",
        "\t.probe\t\t= asus_ec_probe,\n"
        "\t.remove\t\t= asus_ec_remove,\n"
        "\t.shutdown\t= asus_ec_shutdown,\n",
        "platform shutdown callback",
    )
    return text


def patch_hid(text: str) -> str:
    text = replace_once(
        text,
        "\tenum led_brightness saved_brightness;\n};\n\nstatic struct asus_hid_data *asus_data;\n",
        "\tenum led_brightness saved_brightness;\n"
        "\tstruct mutex command_lock;\n"
        "\tu8 debug_response[A14_EC_REPORT_SIZE];\n"
        "};\n",
        "per-device HID state",
    )
    old = '''static void asus_kbd_set_brightness(struct led_classdev *led_cdev,
\t\t\t\t    enum led_brightness brightness)
{
\tstruct asus_hid_data *data = container_of(led_cdev, struct asus_hid_data, kbd_led_cdev);

\tu8 level = (u8)brightness;

\tif (level > A14_EC_MAX_BACKLIGHT)
\t\tlevel = A14_EC_MAX_BACKLIGHT;

\tu8 buf[A14_EC_REPORT_SIZE] = { A14_EC_REPORT_ID, 0xBA, 0xC5, 0xC4, level };

\tasus_send_ec_command(data->hdev, buf);
\tmsleep(20);
\tdata->saved_brightness = (enum led_brightness)level;
}
'''
    new = '''static int asus_kbd_apply_brightness(struct asus_hid_data *data,
\t\t\t\t     enum led_brightness brightness,
\t\t\t\t     bool remember)
{
\tu8 level = min_t(u8, (u8)brightness, A14_EC_MAX_BACKLIGHT);
\tu8 buf[A14_EC_REPORT_SIZE] = {
\t\tA14_EC_REPORT_ID, 0xBA, 0xC5, 0xC4, level
\t};
\tint ret;

\tret = asus_send_ec_command(data->hdev, buf);
\tif (ret < 0)
\t\treturn ret;

\tmsleep(20);
\tif (remember)
\t\tdata->saved_brightness = (enum led_brightness)level;
\treturn 0;
}

static void asus_kbd_set_brightness(struct led_classdev *led_cdev,
\t\t\t\t    enum led_brightness brightness)
{
\tstruct asus_hid_data *data = container_of(led_cdev,
\t\t\t\t\t\t struct asus_hid_data,
\t\t\t\t\t\t kbd_led_cdev);

\t(void)asus_kbd_apply_brightness(data, brightness, true);
}
'''
    text = replace_once(text, old, new, "preserve HID brightness across suspend")
    text = text.replace(
        "asus_kbd_set_brightness(&data->kbd_led_cdev, LED_OFF);",
        "(void)asus_kbd_apply_brightness(data, LED_OFF, false);",
    )
    if text.count("(void)asus_kbd_apply_brightness(data, LED_OFF, false);") != 2:
        raise RuntimeError("HID suspend paths: expected two replacements")
    text = replace_once(
        text,
        "\tasus_kbd_set_brightness(&data->kbd_led_cdev, data->saved_brightness);\n",
        "\t(void)asus_kbd_apply_brightness(data, data->saved_brightness, false);\n",
        "HID resume restore",
    )
    text = replace_once(text, "static u8 debug_response[A14_EC_REPORT_SIZE];\n\n", "", "remove global HID debug buffer")
    text = replace_once(
        text,
        "\tstruct hid_device *hdev = to_hid_device(dev);\n"
        "\tu8 cmd[A14_EC_REPORT_SIZE] = { A14_EC_REPORT_ID };\n",
        "\tstruct hid_device *hdev = to_hid_device(dev);\n"
        "\tstruct asus_hid_data *data = hid_get_drvdata(hdev);\n"
        "\tu8 cmd[A14_EC_REPORT_SIZE] = { A14_EC_REPORT_ID };\n",
        "HID command per-device lookup",
    )
    text = replace_once(
        text,
        "\tret = hid_hw_raw_request(hdev, A14_EC_REPORT_ID, cmd,\n",
        "\tmutex_lock(&data->command_lock);\n\tret = hid_hw_raw_request(hdev, A14_EC_REPORT_ID, cmd,\n",
        "serialize HID debug SET",
    )
    text = replace_once(
        text,
        "\t\tdev_err(dev, \"hid_cmd SET failed: %d\\n\", ret);\n\t\treturn ret;\n",
        "\t\tdev_err(dev, \"hid_cmd SET failed: %d\\n\", ret);\n"
        "\t\tmutex_unlock(&data->command_lock);\n"
        "\t\treturn ret;\n",
        "unlock failed HID debug SET",
    )
    text = replace_once(
        text,
        "\t\tmemset(debug_response, 0, sizeof(debug_response));\n"
        "\t} else {\n"
        "\t\tmemcpy(debug_response, resp, A14_EC_REPORT_SIZE);\n"
        "\t}\n\n\treturn count;\n",
        "\t\tmemset(data->debug_response, 0, sizeof(data->debug_response));\n"
        "\t} else {\n"
        "\t\tmemcpy(data->debug_response, resp, A14_EC_REPORT_SIZE);\n"
        "\t}\n"
        "\tmutex_unlock(&data->command_lock);\n\n"
        "\treturn count;\n",
        "store per-device HID response",
    )
    text = replace_once(
        text,
        "static ssize_t hid_cmd_show(struct device *dev, struct device_attribute *attr,\n"
        "\t\t\t    char *buf)\n"
        "{\n\tint i, len = 0;\n\n"
        "\tfor (i = 0; i < A14_EC_REPORT_SIZE; i++)\n"
        "\t\tlen += sysfs_emit_at(buf, len, \"%02x \", debug_response[i]);\n"
        "\tlen += sysfs_emit_at(buf, len, \"\\n\");\n"
        "\treturn len;\n"
        "}\n",
        "static ssize_t hid_cmd_show(struct device *dev, struct device_attribute *attr,\n"
        "\t\t\t    char *buf)\n"
        "{\n"
        "\tstruct hid_device *hdev = to_hid_device(dev);\n"
        "\tstruct asus_hid_data *data = hid_get_drvdata(hdev);\n"
        "\tint i, len = 0;\n\n"
        "\tmutex_lock(&data->command_lock);\n"
        "\tfor (i = 0; i < A14_EC_REPORT_SIZE; i++)\n"
        "\t\tlen += sysfs_emit_at(buf, len, \"%02x \",\n"
        "\t\t\t\t     data->debug_response[i]);\n"
        "\tmutex_unlock(&data->command_lock);\n"
        "\tlen += sysfs_emit_at(buf, len, \"\\n\");\n"
        "\treturn len;\n"
        "}\n",
        "read per-device HID response",
    )
    text = replace_once(text, "\tasus_data = data;\n", "", "remove HID singleton assignment")
    text = replace_once(
        text,
        "\tdata->saved_brightness = A14_EC_MAX_BACKLIGHT;\n",
        "\tdata->saved_brightness = A14_EC_MAX_BACKLIGHT;\n"
        "\tmutex_init(&data->command_lock);\n",
        "initialize HID command lock",
    )
    text = replace_once(
        text,
        "\tdevice_create_file(&hdev->dev, &dev_attr_hid_cmd);\n\n\treturn 0;\n",
        "\tret = device_create_file(&hdev->dev, &dev_attr_hid_cmd);\n"
        "\tif (ret)\n"
        "\t\tdev_warn(&hdev->dev, \"failed to create hid_cmd: %d\\n\", ret);\n\n"
        "\treturn 0;\n",
        "check HID debug sysfs creation",
    )
    text = replace_once(text, "\tasus_data = NULL;\n", "", "remove HID singleton cleanup")
    return text


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=Path("."))
    parser.add_argument("--output", type=Path, default=Path("build-src"))
    args = parser.parse_args()

    source = args.source.resolve()
    output = args.output.resolve()
    if output == source:
        raise SystemExit("refusing to overwrite source directory")

    shutil.rmtree(output, ignore_errors=True)
    output.mkdir(parents=True)
    (output / "asus_zenbook_a14_ec.c").write_text(
        patch_ec((source / "asus_zenbook_a14_ec.c").read_text())
    )
    (output / "hid_asus_ec.c").write_text(
        patch_hid((source / "hid_asus_ec.c").read_text())
    )
    shutil.copy2(source / "Kbuild", output / "Kbuild")
    print(f"Prepared hardened module sources in {output}")


if __name__ == "__main__":
    main()
