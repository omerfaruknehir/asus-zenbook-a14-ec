#!/usr/bin/env python3
from pathlib import Path

p = Path("asus_zenbook_a14_ec.c")
s = p.read_text()

prototype = "int asus_a14_cycle_native_profile(void);"
definition = "int asus_a14_cycle_native_profile(void)\n{"
prefix = prototype + "\n\n" + definition

if definition not in s:
    raise SystemExit("Fn+F cycle definition missing")

# Whisper rewrites the cycle function after the native-mode transform. Keep a
# declaration immediately beside the final definition so module builds do not
# report -Wmissing-prototypes for the symbol exported to hid_asus_ec.
if prefix in s:
    print("a14_fn_f_export_prototype=current")
    raise SystemExit(0)

# Remove a stale declaration left farther above by an earlier transform and
# place exactly one declaration beside the final post-Whisper definition.
s = s.replace(prototype + "\n\n", "")
if s.count(definition) != 1:
    raise SystemExit(f"Fn+F cycle definition count={s.count(definition)}")
s = s.replace(definition, prefix, 1)

if s.count(prototype) != 1 or s.count(definition) != 1 or prefix not in s:
    raise SystemExit(
        "Fn+F exported prototype finalization failed: "
        f"declarations={s.count(prototype)} definitions={s.count(definition)}"
    )

p.write_text(s)
print("a14_fn_f_export_prototype=applied")
