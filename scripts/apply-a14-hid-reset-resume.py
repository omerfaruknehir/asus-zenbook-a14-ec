#!/usr/bin/env python3
from pathlib import Path

p = Path("hid_asus_ec.c")
if not p.is_file():
    raise SystemExit("run from the repository root")

s = p.read_text()


def function_range(text: str, start_token: str, next_token: str,
                   label: str) -> tuple[int, int]:
    start = text.find(start_token)
    if start < 0:
        raise SystemExit(f"{label}: start token missing")
    end = text.find(next_token, start)
    if end < 0:
        raise SystemExit(f"{label}: end token missing")
    return start, end


if "A14_HID_RESET_RESUME_HARDENING" in s:
    print("a14_hid_reset_resume=current")
    raise SystemExit(0)

if "A14_HID_LIFECYCLE_HARDENING" not in s:
    raise SystemExit("reset-resume hardening requires lifecycle-hardened HID source")

# Add the marker only in memory. The file is written once, at the end, so a
# failed validation never leaves a half-transformed generated source behind.
old = "#define A14_HID_LIFECYCLE_HARDENING 1\n"
new = old + "#define A14_HID_RESET_RESUME_HARDENING 1\n"
if s.count(old) != 1:
    raise SystemExit(f"lifecycle marker: expected one anchor, found {s.count(old)}")
s = s.replace(old, new, 1)

# Instrument suspend without matching the entire generated function. Earlier
# transforms legitimately change whitespace and individual statements here.
start, end = function_range(
    s,
    "static int asus_hid_suspend(struct hid_device *hdev,",
    "static int asus_hid_resume(struct hid_device *hdev)",
    "HID suspend",
)
segment = s[start:end]
if '"lifecycle: suspend,' not in segment:
    data_anchor = "\tstruct asus_hid_data *data = hid_get_drvdata(hdev);\n"
    if data_anchor not in segment:
        # Accept space-indented generated variants as well.
        data_anchor = "    struct asus_hid_data *data = hid_get_drvdata(hdev);\n"
    if data_anchor not in segment:
        raise SystemExit("HID suspend data anchor missing")
    log = (
        data_anchor
        + "\n"
        + "    dev_info(&hdev->dev,\n"
        + "             \"lifecycle: suspend, Fn-lock=%u, backlight=%u\\n\",\n"
        + "             atomic_read(&data->desired_fn_lock) ? 1 : 0,\n"
        + "             atomic_read(&data->desired_brightness));\n"
    )
    segment = segment.replace(data_anchor, log, 1)
    s = s[:start] + segment + s[end:]

# Replace the ordinary lifecycle resume with one common scheduler used by both
# HID PM paths. hid-core calls reset_resume rather than resume when the device
# was reset across system sleep; ASUS vendor state must be rebuilt in either
# case.
start, end = function_range(
    s,
    "static int asus_hid_resume(struct hid_device *hdev)",
    "static int asus_hid_probe(struct hid_device *hdev,",
    "HID resume",
)
new_resume = r'''static int asus_hid_schedule_resume_recovery(struct hid_device *hdev,
                                             const char *path)
{
    struct asus_hid_data *data = hid_get_drvdata(hdev);

    WRITE_ONCE(data->suspended, false);
    WRITE_ONCE(data->fnlock_ready, false);
    data->fnlock_init_attempts = 0;

    dev_info(&hdev->dev,
             "lifecycle: %s, scheduling ASUS vendor restore; Fn-lock=%u, backlight=%u\n",
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
s = s[:start] + new_resume + "\n" + s[end:]

# Register reset_resume next to the existing PM callbacks. Do this narrowly so
# unrelated generated driver-table changes do not break composition.
if ".reset_resume = asus_hid_reset_resume," not in s:
    anchor = "\t.resume = asus_hid_resume,\n"
    if anchor not in s:
        anchor = "    .resume = asus_hid_resume,\n"
    if s.count(anchor) != 1:
        raise SystemExit(
            f"hid_driver resume callback: expected one anchor, found {s.count(anchor)}"
        )
    s = s.replace(
        anchor,
        anchor + anchor[:len(anchor) - len(anchor.lstrip())]
        + ".reset_resume = asus_hid_reset_resume,\n",
        1,
    )

p.write_text(s)
print("a14_hid_reset_resume=applied")
