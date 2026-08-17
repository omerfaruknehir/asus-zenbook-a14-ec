#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Harden the installed A14 full-ACPI GRUB entry for one diagnostic boot.
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "ERROR: run with sudo/root" >&2
    exit 1
fi

snippet=/etc/grub.d/41_a14_full_acpi
[[ -f "$snippet" ]] || { echo "ERROR: $snippet is missing; install the full-ACPI kernel first" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 missing" >&2; exit 1; }
command -v update-grub >/dev/null 2>&1 || { echo "ERROR: update-grub missing" >&2; exit 1; }

cp -a "$snippet" "$snippet.before-debug"

python3 - "$snippet" <<'PY'
from pathlib import Path
import shlex
import sys

p = Path(sys.argv[1])
lines = p.read_text().splitlines()
new = []
changed = 0

# Remove only arguments that hide or conflict with visible diagnostics. Keep
# efi=noruntime because the known-good DT boot uses it; changing EFI runtime
# policy at the same time as DT-vs-ACPI authority would spoil the A/B test.
remove_exact = {
    "quiet",
    "splash",
    "ignore_loglevel",
    "initcall_debug",
    "keep_bootcon",
}
remove_prefixes = (
    "acpi=",
    "loglevel=",
    "panic=",
    "oops=",
    "panic_print=",
    "printk.time=",
    "printk.always_kmsg_dump=",
    "earlycon=",
    "console=",
)

debug_args = [
    "acpi=force",
    "loglevel=8",
    "ignore_loglevel",
    "initcall_debug",
    "panic=0",
    "oops=panic",
    "panic_print=103",
    "printk.time=1",
    "printk.always_kmsg_dump=Y",
    "earlycon=efifb,ram",
    "console=tty0",
    "keep_bootcon",
]

for line in lines:
    stripped = line.lstrip()
    indent = line[: len(line) - len(stripped)]
    if stripped.startswith("linux "):
        parts = shlex.split(stripped)
        if len(parts) < 2:
            raise SystemExit("malformed GRUB linux line")
        kept = [parts[0], parts[1]]
        for arg in parts[2:]:
            if arg in remove_exact or arg.startswith(remove_prefixes):
                continue
            kept.append(arg)
        # Preserve known-good EFI policy even if an earlier edit removed it.
        if "efi=noruntime" not in kept:
            kept.append("efi=noruntime")
        kept.extend(debug_args)
        line = indent + " ".join(shlex.quote(x) for x in kept)
        changed += 1
    new.append(line)

if changed != 1:
    raise SystemExit(f"expected exactly one linux line, changed {changed}")
text = "\n".join(new) + "\n"
if any(x.lstrip().startswith("devicetree ") for x in new):
    raise SystemExit("refusing: full-ACPI entry unexpectedly contains devicetree command")
for forbidden in (" quiet ", " splash "):
    if forbidden in f" {text} ":
        raise SystemExit(f"diagnostic-hiding argument survived: {forbidden.strip()}")
for required in ["efi=noruntime", *debug_args]:
    if required not in text:
        raise SystemExit(f"missing required debug argument: {required}")
p.write_text(text)
PY

chmod 0755 "$snippet"
update-grub

echo "A14_FULL_ACPI_DEBUG_ENTRY=READY"
echo "The experimental entry now has visible early boot logging and panic=0."
echo "EFI runtime policy remains efi=noruntime to match the known-good DT control."
echo "If it stops or panics, photograph the FINAL visible screen before recovery."
echo "If it hard-resets anyway, note approximately how many seconds elapsed and the last visible line if possible."
grep -E '^[[:space:]]*linux[[:space:]]' "$snippet"
