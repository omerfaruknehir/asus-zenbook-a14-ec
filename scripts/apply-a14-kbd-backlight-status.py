#!/usr/bin/env python3
"""Add read-only A14 keyboard-backlight EC status diagnostics.

The UX3407RA DSDT GET path reads ECCR(0xc9, 0xf0) and masks bits 1..2.
This exposes the exact byte through sysfs so HID level changes can be
correlated with the firmware mailbox without adding another EC write path.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "asus_zenbook_a14_ec.c"
MARKER = "A14_EC_KBD_BACKLIGHT_STATUS_DIAGNOSTIC"


def replace_once(source: str, old: str, new: str, label: str) -> str:
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one anchor, found {count}")
    return source.replace(old, new, 1)


def main() -> None:
    source = SOURCE.read_text()
    if MARKER in source:
        print("a14_kbd_backlight_ec_status=current")
        return

    source = replace_once(
        source,
        "#define EC_REG_TEMP_MIN                 0x02\n",
        "#define EC_REG_TEMP_MIN                 0x02\n"
        "\n"
        "/* Read-only mirror of the UX3407RA DSDT ECCR(0xc9, 0xf0) path. */\n"
        "#define A14_EC_KBD_BACKLIGHT_STATUS_DIAGNOSTIC 1\n"
        "#define EC_REG_KBD_BACKLIGHT_STATUS_MAJ  0xc9\n"
        "#define EC_REG_KBD_BACKLIGHT_STATUS_MIN  0xf0\n",
        "keyboard-backlight status constants",
    )

    source = replace_once(
        source,
        "static int asus_ec_set_fan_mode(struct asus_ec *ec, u8 mode)\n",
        "static int asus_ec_read_kbd_backlight_status(struct asus_ec *ec,\n"
        "                                              u8 *status)\n"
        "{\n"
        "\tint ret;\n"
        "\n"
        "\t/* ECCR does not apply __ec_cr()'s generic minor < 0x80 rule. */\n"
        "\tmutex_lock(&ec->ec_lock);\n"
        "\tret = __ec_settle(ec);\n"
        "\tif (!ret)\n"
        "\t\tret = __ec_wb(ec, 0xc4, EC_CC_REGSEL,\n"
        "\t\t\t      EC_REG_KBD_BACKLIGHT_STATUS_MIN);\n"
        "\tif (!ret)\n"
        "\t\tret = __ec_wb(ec, 0xc4, EC_CC_BUSY,\n"
        "\t\t\t      EC_REG_KBD_BACKLIGHT_STATUS_MAJ);\n"
        "\tif (!ret)\n"
        "\t\tret = __ec_settle(ec);\n"
        "\tif (!ret)\n"
        "\t\tret = __ec_rb(ec, 0xc4, EC_CC_DATA, status);\n"
        "\tif (!ret)\n"
        "\t\tret = __ec_wb(ec, 0xc4, EC_CC_DATA, 0);\n"
        "\tmutex_unlock(&ec->ec_lock);\n"
        "\treturn ret;\n"
        "}\n"
        "\n"
        "static int asus_ec_set_fan_mode(struct asus_ec *ec, u8 mode)\n",
        "keyboard-backlight status helper",
    )

    source = replace_once(
        source,
        "static ssize_t profile_choices_show(struct device *dev,\n",
        "static ssize_t kbd_backlight_ec_status_show(struct device *dev,\n"
        "                                             struct device_attribute *attr,\n"
        "                                             char *buf)\n"
        "{\n"
        "\tstruct asus_ec *ec = dev_get_drvdata(dev);\n"
        "\tu8 status;\n"
        "\tint ret;\n"
        "\n"
        "\tret = asus_ec_read_kbd_backlight_status(ec, &status);\n"
        "\tif (ret)\n"
        "\t\treturn ret;\n"
        "\n"
        "\treturn sysfs_emit(buf, \"0x%02x\\n\", status);\n"
        "}\n"
        "\n"
        "static ssize_t profile_choices_show(struct device *dev,\n",
        "keyboard-backlight status sysfs show",
    )

    source = replace_once(
        source,
        "static DEVICE_ATTR_RW(profile);\n",
        "static DEVICE_ATTR_RW(profile);\n"
        "static DEVICE_ATTR_RO(kbd_backlight_ec_status);\n",
        "keyboard-backlight status attribute",
    )
    source = replace_once(
        source,
        "\t&dev_attr_profile.attr,\n",
        "\t&dev_attr_profile.attr,\n"
        "\t&dev_attr_kbd_backlight_ec_status.attr,\n",
        "keyboard-backlight status attribute group",
    )

    SOURCE.write_text(source)
    print("a14_kbd_backlight_ec_status=applied")


if __name__ == "__main__":
    main()
