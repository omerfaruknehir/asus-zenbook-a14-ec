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


def main() -> None:
    if not EC.is_file() or not HID.is_file():
        raise SystemExit("run from the repository root")

    ec = EC.read_text()

    # BIOS 312 I2C6.WEBC uses Stall(0x64), i.e. 100 microseconds, with BMTR
    # initialized to 0xC8 (200 attempts). An earlier reconstruction incorrectly
    # interpreted this as Sleep(100) / 100 milliseconds. Besides being 1000x
    # too slow, that can make a cold-boot busy mailbox look like a dead profile
    # switch for up to ~20 seconds. Match the recovered AML exactly: ~20 ms
    # maximum pre-command busy wait.
    wrong = (
        "#define EC_FW_WAIT_ATTEMPTS              200\n"
        "/* DSDT WEBC uses Sleep(100): 100 ms per busy poll, not 100 us. */\n"
        "#define EC_FW_WAIT_MIN_US                100000\n"
        "#define EC_FW_WAIT_MAX_US                110000\n"
    )
    correct = (
        "#define EC_FW_WAIT_ATTEMPTS              200\n"
        "/* BIOS 312 I2C6.WEBC: Stall(0x64) = 100 us, BMTR = 0xC8. */\n"
        "#define EC_FW_WAIT_MIN_US                100\n"
        "#define EC_FW_WAIT_MAX_US                200\n"
    )
    if wrong in ec:
        ec = ec.replace(wrong, correct, 1)
    elif correct not in ec:
        raise SystemExit("BIOS 312 WEBC timing anchor missing")

    marker_anchor = "#define A14_EC_LIFECYCLE_HARDENING 1\n"
    marker = marker_anchor + "#define A14_BIOS312_COLD_BOOT_HARDENING 1\n"
    ec = replace_once(ec, marker_anchor, marker, "cold-boot marker")

    EC.write_text(ec)
    print("a14_bios312_webc_timing=100us-x200")
    print("a14_bios312_coldboot=current")


if __name__ == "__main__":
    main()
