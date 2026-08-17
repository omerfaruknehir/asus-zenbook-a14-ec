#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Apply the UX3407RA ACPI+DT sidecar experiment to Linux v7.1.5.

Stage 0 intentionally keeps Linux's global acpi_disabled=1. Device tree remains
fully authoritative for CPU/PSCI/GIC/timers/PCI/IOMMU/clocks/regulators and
normal device enumeration. ACPICA is initialized separately only far enough to
load the firmware namespace and permit later controlled namespace inspection.

The transform is anchor-checked and refuses an unexpected kernel source tree.
"""

from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"
MARKER = "A14_ACPI_DT_HYBRID_V0"


def fail(message: str) -> None:
    raise SystemExit(f"A14 ACPI hybrid: {message}")


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text()
    if new in text:
        print(f"{label}=current")
        return
    count = text.count(old)
    if count != 1:
        fail(f"{label}: expected one source anchor in {path}, found {count}")
    path.write_text(text.replace(old, new, 1))
    print(f"{label}=applied")


def kernel_release(root: Path) -> str:
    values = {}
    for line in (root / "Makefile").read_text().splitlines():
        for key in ("VERSION", "PATCHLEVEL", "SUBLEVEL"):
            prefix = f"{key} ="
            if line.startswith(prefix):
                values[key] = line.split("=", 1)[1].strip()
    try:
        return ".".join(values[k] for k in ("VERSION", "PATCHLEVEL", "SUBLEVEL"))
    except KeyError as exc:
        fail(f"cannot identify kernel version: missing {exc.args[0]}")


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: apply-a14-acpi-hybrid-v0.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file():
        fail(f"not a kernel source tree: {root}")

    found = kernel_release(root)
    if found != KERNEL_VERSION:
        fail(f"this transform targets exactly {KERNEL_VERSION}, found {found}")

    arm64_acpi = root / "arch/arm64/kernel/acpi.c"
    acpi_bus = root / "drivers/acpi/bus.c"
    acpi_h = root / "include/linux/acpi.h"
    for path in (arm64_acpi, acpi_bus, acpi_h):
        if not path.is_file():
            fail(f"missing source: {path}")

    # Shared state. acpi_disabled deliberately remains true in hybrid mode;
    # this flag is only the ACPICA-sidecar opt-in.
    replace_once(
        acpi_h,
        "#include <asm/acpi.h>\n\n#ifdef CONFIG_ACPI_TABLE_LIB\n",
        "#include <asm/acpi.h>\n\n/* A14_ACPI_DT_HYBRID_V0: ACPICA namespace sidecar while DT remains authoritative. */\nextern bool acpi_dt_hybrid;\n\n#ifdef CONFIG_ACPI_TABLE_LIB\n",
        "hybrid_header_state",
    )

    replace_once(
        acpi_bus,
        "struct acpi_device *acpi_root;\nstruct proc_dir_entry *acpi_root_dir;\nEXPORT_SYMBOL(acpi_root_dir);\n",
        "struct acpi_device *acpi_root;\nstruct proc_dir_entry *acpi_root_dir;\nEXPORT_SYMBOL(acpi_root_dir);\n\n/* A14_ACPI_DT_HYBRID_V0: never means ACPI owns platform enumeration. */\nbool acpi_dt_hybrid;\nEXPORT_SYMBOL_GPL(acpi_dt_hybrid);\n",
        "hybrid_bus_state",
    )

    # acpi=hybrid is arm64-only and deliberately separate from acpi=on/force.
    replace_once(
        arm64_acpi,
        "static bool param_acpi_force __initdata;\nstatic bool param_acpi_nospcr __initdata;\n",
        "static bool param_acpi_force __initdata;\nstatic bool param_acpi_hybrid __initdata;\nstatic bool param_acpi_nospcr __initdata;\n",
        "hybrid_arm64_parameter_state",
    )

    replace_once(
        arm64_acpi,
        "\telse if (strcmp(arg, \"force\") == 0) /* force ACPI to be enabled */\n\t\tparam_acpi_force = true;\n\telse if (strcmp(arg, \"nospcr\") == 0) /* disable SPCR as default console */\n",
        "\telse if (strcmp(arg, \"force\") == 0) /* force ACPI to be enabled */\n\t\tparam_acpi_force = true;\n\telse if (strcmp(arg, \"hybrid\") == 0) /* parse ACPICA namespace, keep DT authoritative */\n\t\tparam_acpi_hybrid = true;\n\telse if (strcmp(arg, \"nospcr\") == 0) /* disable SPCR as default console */\n",
        "hybrid_arm64_parameter_parser",
    )

    replace_once(
        arm64_acpi,
        "void __init acpi_boot_table_init(void)\n{\n\t/*\n\t * Enable ACPI instead of device tree unless\n",
        "void __init acpi_boot_table_init(void)\n{\n\t/*\n\t * A14_ACPI_DT_HYBRID_V0\n\t *\n\t * Parse and sanity-check the firmware ACPI tables, but DO NOT call\n\t * enable_acpi(). Keeping acpi_disabled=1 is intentional: all existing\n\t * arm64 and Qualcomm code continues down its normal DT paths. ACPICA's\n\t * namespace is brought up later by the restricted sidecar in bus.c.\n\t * acpi=off wins if both options somehow appear on the command line.\n\t */\n\tif (param_acpi_hybrid && !param_acpi_off) {\n\t\tif (acpi_table_init() || acpi_fadt_sanity_check()) {\n\t\t\tpr_err(\"DT-hybrid sidecar: failed to initialize ACPI tables; continuing DT-only\\n\");\n\t\t} else {\n\t\t\tacpi_dt_hybrid = true;\n\t\t\tpr_info(\"DT-hybrid sidecar: ACPI tables accepted; DT remains boot authority\\n\");\n\t\t}\n\t\tgoto done;\n\t}\n\n\t/*\n\t * Enable ACPI instead of device tree unless\n",
        "hybrid_arm64_table_path",
    )

    # acpi_early_init normally exits solely because acpi_disabled remains set.
    # Allow only ACPICA's table/namespace core initialization in sidecar mode.
    replace_once(
        acpi_bus,
        "\tif (acpi_disabled)\n\t\treturn;\n\n\tpr_info(\"Core revision %08x\\n\", ACPI_CA_VERSION);\n",
        "\tif (acpi_disabled && !acpi_dt_hybrid)\n\t\treturn;\n\n\tif (acpi_dt_hybrid)\n\t\tpr_info(\"DT-hybrid sidecar: initializing ACPICA core with Linux ACPI platform mode disabled\\n\");\n\n\tpr_info(\"Core revision %08x\\n\", ACPI_CA_VERSION);\n",
        "hybrid_acpi_early_init",
    )

    hybrid_init = r'''static int __init acpi_dt_hybrid_namespace_init(void)
{
	static const char * const a14_namespace_paths[] = {
		"\\_SB.I2C9",
		"\\_SB.ECKB",
		"\\_SB.PEP0",
		"\\_SB.GIO0",
	};
	acpi_handle handle;
	acpi_status status;
	int result;
	int i;

	/*
	 * Stage 0 deliberately does NOT call the normal acpi_bus_init().
	 * In particular it does not probe ECDT/DSDT EC regions, negotiate _OSC,
	 * initialize sleep/SCI/GPE/global-lock handling, evaluate _PIC, register
	 * the ACPI bus, create platform devices, or run acpi_scan_init().
	 */
	pr_info("DT-hybrid sidecar: loading AML namespace with hardware/device initialization suppressed\n");

	acpi_kobj = kobject_create_and_add("acpi", firmware_kobj);
	if (!acpi_kobj) {
		pr_err("DT-hybrid sidecar: failed to register ACPI kobject\n");
		return -ENOMEM;
	}

	acpi_os_initialize1();

	status = acpi_load_tables();
	if (ACPI_FAILURE(status)) {
		pr_err("DT-hybrid sidecar: unable to load System Description Tables: %s\n",
		       acpi_format_exception(status));
		goto error;
	}

	/* No ACPI-mode switch, no fixed/GPE event setup, no SCI/global-lock. */
	status = acpi_enable_subsystem(ACPI_NO_ACPI_ENABLE |
					      ACPI_NO_HARDWARE_INIT |
					      ACPI_NO_EVENT_INIT |
					      ACPI_NO_HANDLER_INIT);
	if (ACPI_FAILURE(status)) {
		pr_err("DT-hybrid sidecar: unable to start restricted interpreter: %s\n",
		       acpi_format_exception(status));
		goto error;
	}

	/* Do not execute device _STA/_INI or operation-region _REG methods. */
	status = acpi_initialize_objects(ACPI_NO_DEVICE_INIT |
						 ACPI_NO_ADDRESS_SPACE_INIT);
	if (ACPI_FAILURE(status)) {
		pr_err("DT-hybrid sidecar: namespace object initialization failed: %s\n",
		       acpi_format_exception(status));
		goto error;
	}

	/* Expose the loaded firmware tables for byte-for-byte validation. */
	result = acpi_sysfs_init();
	if (result)
		pr_warn("DT-hybrid sidecar: ACPI table sysfs setup failed: %d\n", result);

	/* UX3407RA read-only namespace existence checks: no AML methods executed. */
	for (i = 0; i < ARRAY_SIZE(a14_namespace_paths); i++) {
		status = acpi_get_handle(NULL, (acpi_string)a14_namespace_paths[i],
					 &handle);
		if (ACPI_SUCCESS(status))
			pr_info("DT-hybrid namespace: %s present\n",
				a14_namespace_paths[i]);
		else
			pr_warn("DT-hybrid namespace: %s missing (%s)\n",
				a14_namespace_paths[i], acpi_format_exception(status));
	}

	pr_info("DT-hybrid sidecar ready: DT owns hardware; ACPI scan/power/IRQ/PCI disabled\n");
	return 0;

error:
	kobject_put(acpi_kobj);
	acpi_kobj = NULL;
	acpi_terminate();
	return -ENODEV;
}

'''

    replace_once(
        acpi_bus,
        "void __weak __init acpi_arch_init(void) { }\n\nstatic int __init acpi_init(void)\n",
        "void __weak __init acpi_arch_init(void) { }\n\n" + hybrid_init + "static int __init acpi_init(void)\n",
        "hybrid_namespace_initializer",
    )

    replace_once(
        acpi_bus,
        "static int __init acpi_init(void)\n{\n\tint result;\n\n\tif (acpi_disabled) {\n",
        "static int __init acpi_init(void)\n{\n\tint result;\n\n\tif (acpi_dt_hybrid)\n\t\treturn acpi_dt_hybrid_namespace_init();\n\n\tif (acpi_disabled) {\n",
        "hybrid_acpi_init_dispatch",
    )

    # Final invariants: stage 0 must not modify the binary DT/ACPI authority
    # decisions in setup.c or SMP. The whole point is that acpi_disabled stays 1.
    required = {
        arm64_acpi: (
            'strcmp(arg, "hybrid")',
            'acpi_dt_hybrid = true;',
            'DT-hybrid sidecar: ACPI tables accepted',
        ),
        acpi_bus: (
            'bool acpi_dt_hybrid;',
            'ACPI_NO_HARDWARE_INIT',
            'ACPI_NO_DEVICE_INIT',
            'ACPI_NO_ADDRESS_SPACE_INIT',
            'return acpi_dt_hybrid_namespace_init();',
            'DT-hybrid sidecar ready',
        ),
        acpi_h: ('extern bool acpi_dt_hybrid;',),
    }
    for path, tokens in required.items():
        text = path.read_text()
        missing = [token for token in tokens if token not in text]
        if missing:
            fail(f"post-transform validation failed for {path}: {missing}")

    setup = (root / "arch/arm64/kernel/setup.c").read_text()
    if "if (acpi_disabled)\n\t\tunflatten_device_tree();" not in setup:
        fail("arm64 setup.c DT-authority anchor unexpectedly changed")
    if "if (acpi_disabled)\n\t\tpsci_dt_init();" not in setup:
        fail("arm64 PSCI DT-authority anchor unexpectedly changed")

    print(f"{MARKER}=APPLIED")
    print("acpi_global_authority=DT (acpi_disabled remains true)")
    print("acpi_sidecar=tables+ACPICA namespace only")
    print("acpi_hardware_init=disabled")
    print("acpi_device_scan=disabled")
    print("acpi_device_ini_sta_reg=disabled")


if __name__ == "__main__":
    main()
