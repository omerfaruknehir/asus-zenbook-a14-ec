#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Add an A14 diagnostic-only early ramoops collector to Linux 7.1.5.

When booted with ramoops.a14_collector=1, ramoops prints the *previous boot's*
persistent console immediately after the console PRZ is recovered, waits a
bounded interval for a photo, then emergency-restarts. This happens from the
postcore ramoops probe, before the later device-initcall/provider failures that
make the full experimental DT collector unsuitable as a normal userspace boot.
"""
from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 pstore collector: {msg}")


def kernel_version(root: Path) -> str:
    vals = {}
    for line in (root / "Makefile").read_text().splitlines():
        for key in ("VERSION", "PATCHLEVEL", "SUBLEVEL"):
            if line.startswith(key + " ="):
                vals[key] = line.split("=", 1)[1].strip()
    return ".".join(vals[k] for k in ("VERSION", "PATCHLEVEL", "SUBLEVEL"))


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        print(f"{label}=current")
        return text
    count = text.count(old)
    if count != 1:
        fail(f"{label}: expected one anchor, found {count}")
    print(f"{label}=applied")
    return text.replace(old, new, 1)


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: apply-a14-full-acpi-pstore-collector.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file() or kernel_version(root) != KERNEL_VERSION:
        fail(f"targets exactly Linux {KERNEL_VERSION}")

    path = root / "fs/pstore/ram.c"
    text = path.read_text()

    text = replace_once(
        text,
        '#include <linux/mm.h>\n',
        '#include <linux/mm.h>\n#include <linux/reboot.h>\n#include <linux/delay.h>\n',
        "collector_includes",
    )

    old_params = '''static int ramoops_dump_oops = -1;\nmodule_param_named(dump_oops, ramoops_dump_oops, int, 0400);\nMODULE_PARM_DESC(dump_oops,\n\t\t "(deprecated: use max_reason instead) set to 1 to dump oopses & panics, 0 to only dump panics");\n'''
    new_params = old_params + '''\n/* A14 diagnostic collector. Built-in ramoops parses these as\n * ramoops.a14_collector= and ramoops.a14_collector_delay_ms=. */\nstatic bool a14_collector;\nmodule_param_named(a14_collector, a14_collector, bool, 0400);\nMODULE_PARM_DESC(a14_collector,\n\t\t "A14 diagnostic: print previous ramoops console and reboot early");\n\nstatic unsigned int a14_collector_delay_ms = 12000;\nmodule_param_named(a14_collector_delay_ms, a14_collector_delay_ms, uint, 0400);\nMODULE_PARM_DESC(a14_collector_delay_ms,\n\t\t "A14 diagnostic collector on-screen wait before emergency reboot");\n'''
    text = replace_once(text, old_params, new_params, "collector_params")

    helper_anchor = '''static int ramoops_probe(struct platform_device *pdev)\n{\n'''
    helper = '''static void ramoops_a14_echo_previous_console(struct ramoops_context *cxt)\n{\n\tconst char *old = NULL;\n\tsize_t old_size = 0;\n\tsize_t off = 0;\n\tunsigned int remaining;\n\n\tif (!a14_collector)\n\t\treturn;\n\n\tif (cxt->cprz) {\n\t\told_size = persistent_ram_old_size(cxt->cprz);\n\t\told = persistent_ram_old(cxt->cprz);\n\t}\n\n\tpr_emerg("============================================================\\n");\n\tpr_emerg("A14 PSTORE EARLY COLLECTOR\\n");\n\tpr_emerg("previous_console_bytes=%zu\\n", old_size);\n\tpr_emerg("ramoops_region=0x%lx@0x%llx\\n", cxt->size,\n\t\t (unsigned long long)cxt->phys_addr);\n\tpr_emerg("================ PREVIOUS BOOT CONSOLE BEGIN ================\\n");\n\n\tif (!old || !old_size) {\n\t\tpr_emerg("A14 PSTORE: no previous console recovered\\n");\n\t} else {\n\t\twhile (off < old_size) {\n\t\t\tsize_t chunk = min_t(size_t, old_size - off, 512);\n\n\t\t\tprintk(KERN_EMERG "%.*s", (int)chunk, old + off);\n\t\t\toff += chunk;\n\t\t}\n\t\tif (old[old_size - 1] != '\\n')\n\t\t\tprintk(KERN_EMERG "\\n");\n\t}\n\n\tpr_emerg("================= PREVIOUS BOOT CONSOLE END =================\\n");\n\tif (a14_collector_delay_ms > 60000)\n\t\ta14_collector_delay_ms = 60000;\n\tpr_emerg("A14 PSTORE: rebooting automatically in %u ms\\n",\n\t\t a14_collector_delay_ms);\n\tpr_emerg("============================================================\\n");\n\n\tremaining = a14_collector_delay_ms;\n\twhile (remaining) {\n\t\tunsigned int step = remaining > 100 ? 100 : remaining;\n\n\t\tmdelay(step);\n\t\tremaining -= step;\n\t}\n\n\tpr_emerg("A14 PSTORE: collector reboot now\\n");\n\temergency_restart();\n\tpr_emerg("A14 PSTORE ERROR: emergency_restart returned\\n");\n\tfor (;;)\n\t\tmdelay(1000);\n}\n\n''' + helper_anchor
    text = replace_once(text, helper_anchor, helper, "collector_helper")

    old_call = '''\terr = ramoops_init_prz("console", dev, cxt, &cxt->cprz, &paddr,\n\t\t\t       cxt->console_size, 0);\n\tif (err)\n\t\tgoto fail_init;\n\n\terr = ramoops_init_prz("pmsg", dev, cxt, &cxt->mprz, &paddr,\n'''
    new_call = '''\terr = ramoops_init_prz("console", dev, cxt, &cxt->cprz, &paddr,\n\t\t\t       cxt->console_size, 0);\n\tif (err)\n\t\tgoto fail_init;\n\n\t/* In collector mode, persistent_ram_new() has already copied the prior\n\t * console into cprz->old_log. Echo it and reboot before device initcalls. */\n\tramoops_a14_echo_previous_console(cxt);\n\n\terr = ramoops_init_prz("pmsg", dev, cxt, &cxt->mprz, &paddr,\n'''
    text = replace_once(text, old_call, new_call, "collector_probe_hook")

    path.write_text(text)
    final = path.read_text()
    required = (
        'ramoops.a14_collector=',
        'A14 PSTORE EARLY COLLECTOR',
        'persistent_ram_old_size(cxt->cprz)',
        'ramoops_a14_echo_previous_console(cxt);',
        'emergency_restart();',
    )
    for token in required:
        if token not in final:
            fail(f"verification missing {token}")

    print("A14_FULL_ACPI_PSTORE_COLLECTOR=APPLIED")
    print("collector_phase=ramoops-postcore-probe-before-device-initcalls")
    print("default_collector_delay_ms=12000")


if __name__ == "__main__":
    main()
