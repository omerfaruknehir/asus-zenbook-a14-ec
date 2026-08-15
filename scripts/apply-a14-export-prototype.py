#!/usr/bin/env python3
from pathlib import Path

p = Path("asus_zenbook_a14_ec.c")
s = p.read_text()

prototype = "int asus_a14_cycle_native_profile(void);"
definition = "int asus_a14_cycle_native_profile(void)\n{"

if definition not in s:
    raise SystemExit("Fn+F cycle definition missing")

# Whisper rewrites the cycle function to add itself to the ordering. Keep a
# declaration immediately before that final definition so W=1/module builds do
# not report -Wmissing-prototypes for the symbol exported to hid_asus_ec.
prefix = prototype + "\n\n" + definition
if prefix in s:
    print("a14_fn_f_export_prototype=current")
    raise SystemExit(0)

# Remove any stale declaration left farther above by the pre-Whisper transform;
# then place exactly one beside the final post-Whisper definition.
s = s.replace(prototype + "\n\n", "")
if s.count(definition) != 1:
    raise SystemExit(f"Fn+F cycle definition count={s.count(definition)}")
s = s.replace(definition, prefix, 1)

if s.count(prototype) != 2:
    # One textual occurrence is the declaration and one is the function
    # signature prefix inside the definition.
    raise SystemExit(f"unexpected Fn+F prototype/signature count={s.count(prototype)}")

p.write_text(s)
print("a14_fn_f_export_prototype=applied")
