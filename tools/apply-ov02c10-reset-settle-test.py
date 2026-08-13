#!/usr/bin/env python3
from pathlib import Path
import shutil
import sys

if len(sys.argv) != 2:
    raise SystemExit(f"usage: {sys.argv[0]} /path/to/ov02c10.c")

path = Path(sys.argv[1]).resolve()
text = path.read_text()

old = """\tif (ov02c10->reset) {\n\t\t/* Assert reset for at least 2ms on back to back off-on */\n\t\tusleep_range(2000, 2200);\n\t\tgpiod_set_value_cansleep(ov02c10->reset, 0);\n\t\tusleep_range(5000, 5100);\n\t}\n"""
new = """\tif (ov02c10->reset) {\n\t\t/* Assert reset for at least 2ms on back to back off-on */\n\t\tusleep_range(2000, 2200);\n\t\tgpiod_set_value_cansleep(ov02c10->reset, 0);\n\n\t\t/*\n\t\t * Diagnostic A/B test for X1E80100 rapid camera switching.\n\t\t * The CCI timeout dump shows the controller stalling on the\n\t\t * first mode-table write immediately after sensor power-up.\n\t\t * Use a deliberately generous settle interval to test whether\n\t\t * the sensor is not yet ready for SCCB/I2C traffic after reset.\n\t\t */\n\t\tusleep_range(20000, 21000);\n\t}\n"""

if new in text:
    raise SystemExit("already patched")

count = text.count(old)
if count != 1:
    raise SystemExit(f"refusing to patch: expected exact power-on block once, found {count}")

backup = path.with_name(path.name + ".pre-reset-settle-test")
if not backup.exists():
    shutil.copy2(path, backup)

path.write_text(text.replace(old, new, 1))
print(f"patched: {path}")
print(f"backup:  {backup}")
