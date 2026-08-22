#!/usr/bin/env python3
from pathlib import Path

path = Path("hid_asus_ec.c")
source = path.read_text()
label = "\nerr_led:\n"

if "goto err_led;" in source:
    print("a14_hid_err_led=needed")
elif label in source:
    if source.count(label) != 1:
        raise SystemExit(f"unexpected err_led label count={source.count(label)}")
    path.write_text(source.replace(label, "\n", 1))
    print("a14_hid_err_led=removed-unused")
else:
    print("a14_hid_err_led=clean")
