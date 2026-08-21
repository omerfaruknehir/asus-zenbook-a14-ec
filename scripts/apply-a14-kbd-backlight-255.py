#!/usr/bin/env python3
"""Compose true 0..255 A14 keyboard-backlight control.

The keyboard HID feature report only accepts the legacy four firmware levels.
The A14 DSDT also exposes a separate EC compound-write transaction whose value
byte is the native 8-bit keyboard-light duty.  Keep the HID request as a
fallback, but make the LED class use the EC transaction whenever the direct EC
driver is ready.
"""

from pathlib import Path


EC_PATH = Path("asus_zenbook_a14_ec.c")
HID_PATH = Path("hid_asus_ec.c")
EC_MARKER = "A14_EC_KBD_BACKLIGHT_255"
HID_MARKER = "A14_HID_KBD_BACKLIGHT_255"


ec = EC_PATH.read_text()
hid = HID_PATH.read_text()

if EC_MARKER in ec and HID_MARKER in hid:
    print("a14_kbd_backlight_255=current")
    raise SystemExit(0)
if EC_MARKER in ec or HID_MARKER in hid:
    raise SystemExit("a14_kbd_backlight_255=partial-composition")


def ec_once(old: str, new: str, label: str) -> None:
    global ec
    count = ec.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one EC anchor, found {count}")
    ec = ec.replace(old, new, 1)


def hid_once(old: str, new: str, label: str) -> None:
    global hid
    count = hid.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one HID anchor, found {count}")
    hid = hid.replace(old, new, 1)


ec_once(
    "#define EC_REG_TEMP_MIN                 0x02\n",
    """#define EC_REG_TEMP_MIN                 0x02

/* DSDT ECCW(0x02, 0x82, value): native 8-bit keyboard-light duty. */
#define A14_EC_KBD_BACKLIGHT_255         1
#define EC_REG_KBD_BACKLIGHT_MAJ         0x02
#define EC_REG_KBD_BACKLIGHT_WMIN        0x82
""",
    "keyboard EC register constants",
)

ec_once(
    "static struct platform_device *asus_ec_pdev;\n",
    """static struct platform_device *asus_ec_pdev;
static DEFINE_MUTEX(asus_ec_instance_lock);
static struct asus_ec *asus_ec_instance;
""",
    "ready EC instance state",
)

ec_once(
    "static int asus_ec_set_native_fan_profile(struct asus_ec *ec, u8 marker)\n",
    """int asus_a14_set_keyboard_backlight(unsigned int brightness)
{
	struct asus_ec *ec;
	int ret;

	if (brightness > U8_MAX)
		return -EINVAL;

	/* Serialize against remove so the exported consumer never observes a
	 * devres-managed EC instance after its successful probe lifetime. */
	mutex_lock(&asus_ec_instance_lock);
	ec = asus_ec_instance;
	if (!ec)
		ret = -ENODEV;
	else if (READ_ONCE(ec->shutting_down))
		ret = -ESHUTDOWN;
	else
		ret = asus_ec_write_reg(ec, EC_REG_KBD_BACKLIGHT_MAJ,
					EC_REG_KBD_BACKLIGHT_WMIN, (u8)brightness);
	mutex_unlock(&asus_ec_instance_lock);

	return ret;
}
EXPORT_SYMBOL_GPL(asus_a14_set_keyboard_backlight);

static int asus_ec_set_native_fan_profile(struct asus_ec *ec, u8 marker)
""",
    "exported keyboard brightness setter",
)

ec_once(
    """\tasus_ec_platform_profile_register(ec);
\tdev_info(dev,
""",
    """\tasus_ec_platform_profile_register(ec);
	mutex_lock(&asus_ec_instance_lock);
	asus_ec_instance = ec;
	mutex_unlock(&asus_ec_instance_lock);
	dev_info(dev,
""",
    "publish ready EC instance",
)

ec_once(
    """\tif (!ec)
\t\treturn;
\tasus_ec_quiesce(ec);
""",
    """\tif (!ec)
		return;
	mutex_lock(&asus_ec_instance_lock);
	if (asus_ec_instance == ec)
		asus_ec_instance = NULL;
	mutex_unlock(&asus_ec_instance_lock);
	asus_ec_quiesce(ec);
""",
    "unpublish EC instance before remove",
)

hid_once(
    "#define A14_EC_MAX_BACKLIGHT            3\n",
    """#define A14_HID_KBD_BACKLIGHT_255       1
#define A14_EC_MAX_BACKLIGHT            255
#define A14_EC_BACKLIGHT_STEP           85
#define A14_HID_MAX_BACKLIGHT           3
""",
    "8-bit LED limits",
)

hid_once(
    "extern int asus_a14_cycle_native_profile(void);\n",
    """extern int asus_a14_cycle_native_profile(void);
extern int asus_a14_set_keyboard_backlight(unsigned int brightness);
""",
    "EC keyboard setter declaration",
)

hid_once(
    """static uint initial_brightness = 1;
module_param(initial_brightness, uint, 0644);
MODULE_PARM_DESC(initial_brightness, "Initial keyboard-backlight level (0-3)");
""",
    """static uint initial_brightness = A14_EC_BACKLIGHT_STEP;
module_param(initial_brightness, uint, 0644);
MODULE_PARM_DESC(initial_brightness, "Initial keyboard-backlight brightness (0-255)");
""",
    "initial 8-bit brightness",
)

old_setter = """static int asus_hid_set_backlight_hw(struct asus_hid_data *data,
\t\t\t\t    unsigned int level)
{
\tu8 command[A14_EC_REPORT_SIZE] = {
\t\tA14_EC_REPORT_ID, 0xba, 0xc5, 0xc4, 0,
\t};

\tif (level > A14_EC_MAX_BACKLIGHT)
\t\treturn -EINVAL;
\tcommand[4] = level;
\treturn asus_hid_raw_request(data, command, HID_REQ_SET_REPORT);
}
"""
new_setter = """static int asus_hid_set_backlight_fallback(struct asus_hid_data *data,
\t\t\t\t\t  unsigned int brightness)
{
\tu8 command[A14_EC_REPORT_SIZE] = {
\t\tA14_EC_REPORT_ID, 0xba, 0xc5, 0xc4, 0,
\t};

\t/* The HID feature itself has only four discrete firmware levels. */
\tcommand[4] = DIV_ROUND_CLOSEST(brightness * A14_HID_MAX_BACKLIGHT,
\t\t\t\t       A14_EC_MAX_BACKLIGHT);
\treturn asus_hid_raw_request(data, command, HID_REQ_SET_REPORT);
}

static int asus_hid_set_backlight_hw(struct asus_hid_data *data,
\t\t\t\t    unsigned int brightness)
{
\tint ret;

\tif (brightness > A14_EC_MAX_BACKLIGHT)
\t\treturn -EINVAL;

\tret = asus_a14_set_keyboard_backlight(brightness);
\tif (!ret)
\t\treturn 0;

\t/* Preserve usable lighting if the late-loaded direct EC provider is not
\t * ready, or if its transaction fails transiently. */
\tdev_warn_ratelimited(&data->hdev->dev,
\t\t"8-bit EC keyboard-backlight write failed (%d); using HID 0-3 fallback\\n",
\t\tret);
\treturn asus_hid_set_backlight_fallback(data, brightness);
}
"""
hid_once(old_setter, new_setter, "EC-first keyboard setter")

hid_once(
    """\t\tunsigned int level = atomic_read(&data->desired_brightness);
\t\tunsigned int next = (level + 1) % (A14_EC_MAX_BACKLIGHT + 1);

\t\tatomic_set(&data->desired_brightness, next);
""",
    """\t\tunsigned int level = atomic_read(&data->desired_brightness);
\t\tunsigned int next;

		if (level < A14_EC_BACKLIGHT_STEP)
			next = A14_EC_BACKLIGHT_STEP;
		else if (level < 2 * A14_EC_BACKLIGHT_STEP)
			next = 2 * A14_EC_BACKLIGHT_STEP;
		else if (level < A14_EC_MAX_BACKLIGHT)
			next = A14_EC_MAX_BACKLIGHT;
		else
			next = 0;

		atomic_set(&data->desired_brightness, next);
""",
    "Fn+F4 canonical 8-bit cycle",
)

for token in (
    EC_MARKER,
    "ECCW(0x02, 0x82, value)",
    "EXPORT_SYMBOL_GPL(asus_a14_set_keyboard_backlight)",
    "asus_ec_instance = ec",
):
    if token not in ec:
        raise SystemExit(f"EC keyboard-backlight transform incomplete: {token}")

for token in (
    HID_MARKER,
    "#define A14_EC_MAX_BACKLIGHT            255",
    "asus_a14_set_keyboard_backlight(brightness)",
    "asus_hid_set_backlight_fallback",
    "next = 2 * A14_EC_BACKLIGHT_STEP",
):
    if token not in hid:
        raise SystemExit(f"HID keyboard-backlight transform incomplete: {token}")

EC_PATH.write_text(ec)
HID_PATH.write_text(hid)
print("a14_kbd_backlight_255=applied")
