#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
from pathlib import Path
import sys

MARKER = "A14_ACPI_SCAN_TRACE_V1"

def die(msg: str) -> None:
    raise SystemExit(f"A14 ACPI scan trace: {msg}")

def replace_once(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text()
    if new in text:
        print(f"{label}=current")
        return
    n = text.count(old)
    if n != 1:
        die(f"{label}: expected exactly one anchor in {path}, found {n}")
    path.write_text(text.replace(old, new, 1))
    print(f"{label}=applied")

def main() -> None:
    if len(sys.argv) != 2:
        die("usage: apply-a14-full-acpi-scan-trace.py /path/to/linux-7.1.5")
    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file():
        die(f"not a kernel tree: {root}")

    power = root / "drivers/acpi/power.c"
    scan = root / "drivers/acpi/scan.c"
    bus = root / "drivers/acpi/bus.c"

    p = power.read_text()
    if MARKER not in p:
        replace_once(
            power,
            "struct acpi_device *acpi_add_power_resource(acpi_handle handle)\n{\n\tstruct acpi_device *device = acpi_fetch_acpi_dev(handle);\n",
            "/* A14_ACPI_SCAN_TRACE_V1 */\nstruct acpi_device *acpi_add_power_resource(acpi_handle handle)\n{\n\tstruct acpi_device *device = acpi_fetch_acpi_dev(handle);\n\n\tacpi_handle_info(handle, \"A14TRACE power enter\\n\");\n",
            "power_trace_marker",
        )
        replace_once(
            power,
            "\tif (device)\n\t\treturn device;\n",
            "\tif (device) {\n\t\tacpi_handle_info(handle, \"A14TRACE power already-exists\\n\");\n\t\treturn device;\n\t}\n",
            "power_trace_existing",
        )
        replace_once(
            power,
            "\t/* Evaluate the object to get the system level and resource order. */\n\tstatus = acpi_evaluate_object(handle, NULL, NULL, &buffer);\n",
            "\t/* Evaluate the object to get the system level and resource order. */\n\tacpi_handle_info(handle, \"A14TRACE power before evaluate-object\\n\");\n\tstatus = acpi_evaluate_object(handle, NULL, NULL, &buffer);\n\tacpi_handle_info(handle, \"A14TRACE power after evaluate-object status=0x%x\\n\", status);\n",
            "power_trace_eval",
        )
        replace_once(
            power,
            "\t/* Get the initial state or just flip it on if that fails. */\n\tif (acpi_power_get_state(resource, &state_dummy))\n\t\t__acpi_power_on(resource);\n\n\tacpi_handle_info(handle, \"New power resource\\n\");\n\n\tresult = acpi_tie_acpi_dev(device);\n",
            "\t/* Get the initial state or just flip it on if that fails. */\n\tacpi_handle_info(handle, \"A14TRACE power before initial-state\\n\");\n\tif (acpi_power_get_state(resource, &state_dummy))\n\t\t__acpi_power_on(resource);\n\tacpi_handle_info(handle, \"A14TRACE power after initial-state\\n\");\n\n\tacpi_handle_info(handle, \"New power resource\\n\");\n\tacpi_handle_info(handle, \"A14TRACE power before tie-acpi-dev\\n\");\n\n\tresult = acpi_tie_acpi_dev(device);\n\tacpi_handle_info(handle, \"A14TRACE power after tie-acpi-dev result=%d\\n\", result);\n",
            "power_trace_state_tie",
        )
        replace_once(
            power,
            "\tresult = acpi_device_add(device);\n\tif (result)\n\t\tgoto err;\n\n\tif (!device_create_file(&device->dev, &dev_attr_resource_in_use))\n\t\tdevice->remove = acpi_power_sysfs_remove;\n\n\tacpi_power_add_resource_to_list(resource);\n\tacpi_device_add_finalize(device);\n\treturn device;\n",
            "\tacpi_handle_info(handle, \"A14TRACE power before device-add\\n\");\n\tresult = acpi_device_add(device);\n\tacpi_handle_info(handle, \"A14TRACE power after device-add result=%d\\n\", result);\n\tif (result)\n\t\tgoto err;\n\n\tacpi_handle_info(handle, \"A14TRACE power before sysfs-file\\n\");\n\tif (!device_create_file(&device->dev, &dev_attr_resource_in_use))\n\t\tdevice->remove = acpi_power_sysfs_remove;\n\tacpi_handle_info(handle, \"A14TRACE power after sysfs-file\\n\");\n\n\tacpi_handle_info(handle, \"A14TRACE power before resource-list-add\\n\");\n\tacpi_power_add_resource_to_list(resource);\n\tacpi_handle_info(handle, \"A14TRACE power after resource-list-add\\n\");\n\tacpi_handle_info(handle, \"A14TRACE power before device-finalize\\n\");\n\tacpi_device_add_finalize(device);\n\tacpi_handle_info(handle, \"A14TRACE power after device-finalize; return\\n\");\n\treturn device;\n",
            "power_trace_add_finalize",
        )
    else:
        print("power_trace=current")

    replace_once(
        scan,
        "\tif (ACPI_FAILURE(acpi_get_type(handle, &acpi_type)))\n\t\treturn AE_OK;\n\n\tswitch (acpi_type) {\n",
        "\tif (ACPI_FAILURE(acpi_get_type(handle, &acpi_type)))\n\t\treturn AE_OK;\n\n\tif (acpi_type == ACPI_TYPE_POWER)\n\t\tacpi_handle_info(handle, \"A14TRACE scan POWER first_pass=%d enter\\n\", first_pass);\n\n\tswitch (acpi_type) {\n",
        "scan_trace_power_enter",
    )
    replace_once(
        scan,
        "\tcase ACPI_TYPE_POWER:\n\t\tacpi_add_power_resource(handle);\n\t\tfallthrough;\n",
        "\tcase ACPI_TYPE_POWER:\n\t\tacpi_handle_info(handle, \"A14TRACE scan POWER before add-power-resource\\n\");\n\t\tacpi_add_power_resource(handle);\n\t\tacpi_handle_info(handle, \"A14TRACE scan POWER after add-power-resource\\n\");\n\t\tfallthrough;\n",
        "scan_trace_power_call",
    )
    replace_once(
        scan,
        "\t/*\n\t * Enumerate devices in the ACPI namespace.\n\t */\n\tif (acpi_bus_scan(ACPI_ROOT_OBJECT))\n\t\tgoto unlock;\n",
        "\t/*\n\t * Enumerate devices in the ACPI namespace.\n\t */\n\tpr_emerg(\"A14TRACE acpi_scan_init before root acpi_bus_scan\\n\");\n\tif (acpi_bus_scan(ACPI_ROOT_OBJECT)) {\n\t\tpr_emerg(\"A14TRACE acpi_scan_init root acpi_bus_scan FAILED\\n\");\n\t\tgoto unlock;\n\t}\n\tpr_emerg(\"A14TRACE acpi_scan_init after root acpi_bus_scan\\n\");\n",
        "scan_trace_root_scan",
    )

    replace_once(
        bus,
        "\tacpi_hest_init();\n\tacpi_ghes_init();\n\tacpi_arch_init();\n\tacpi_scan_init();\n\tacpi_ec_init();\n",
        "\tacpi_hest_init();\n\tacpi_ghes_init();\n\tpr_emerg(\"A14TRACE acpi_init before acpi_arch_init\\n\");\n\tacpi_arch_init();\n\tpr_emerg(\"A14TRACE acpi_init after acpi_arch_init\\n\");\n\tpr_emerg(\"A14TRACE acpi_init before acpi_scan_init\\n\");\n\tacpi_scan_init();\n\tpr_emerg(\"A14TRACE acpi_init after acpi_scan_init\\n\");\n\tacpi_ec_init();\n",
        "bus_trace_scan",
    )

    for path, required in {
        power: [MARKER, "A14TRACE power before tie-acpi-dev", "A14TRACE power after device-finalize"],
        scan: ["A14TRACE scan POWER before add-power-resource", "A14TRACE acpi_scan_init before root acpi_bus_scan"],
        bus: ["A14TRACE acpi_init before acpi_scan_init", "A14TRACE acpi_init after acpi_scan_init"],
    }.items():
        text = path.read_text()
        missing = [x for x in required if x not in text]
        if missing:
            die(f"post-check failed for {path}: missing {missing}")

    print("A14_ACPI_SCAN_TRACE=APPLIED")
    print("scope=acpi_init/acpi_scan_init/power-resource-add")

if __name__ == "__main__":
    main()
