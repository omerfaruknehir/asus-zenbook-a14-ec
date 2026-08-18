#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
from pathlib import Path
import sys

MARKER = "A14_ACPI_SCAN_TRACE_V2"


def die(msg: str) -> None:
    raise SystemExit(f"A14 ACPI scan trace v2: {msg}")


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
        die("usage: apply-a14-full-acpi-scan-trace-v2.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    scan = root / "drivers/acpi/scan.c"
    if not scan.is_file():
        die(f"missing {scan}")

    text = scan.read_text()
    if MARKER in text:
        print("scan_trace_v2=current")
        print("A14_ACPI_SCAN_TRACE_V2=APPLIED")
        return

    # Trace before acpi_fetch_acpi_dev() and acpi_get_type().  This is
    # intentionally the first executable code in acpi_bus_check_add(), so if
    # the next namespace object is reached at all its path will be visible.
    replace_once(
        scan,
        "static acpi_status acpi_bus_check_add(acpi_handle handle, bool first_pass,\n"
        "\t\t\t\t      struct acpi_device **adev_p)\n"
        "{\n"
        "\tstruct acpi_device *device = acpi_fetch_acpi_dev(handle);\n"
        "\tacpi_object_type acpi_type;\n"
        "\tint type;\n\n"
        "\tif (device)\n"
        "\t\tgoto out;\n\n"
        "\tif (ACPI_FAILURE(acpi_get_type(handle, &acpi_type)))\n"
        "\t\treturn AE_OK;\n",
        "/* A14_ACPI_SCAN_TRACE_V2 */\n"
        "static acpi_status acpi_bus_check_add(acpi_handle handle, bool first_pass,\n"
        "\t\t\t\t      struct acpi_device **adev_p)\n"
        "{\n"
        "\tstruct acpi_device *device;\n"
        "\tacpi_object_type acpi_type;\n"
        "\tacpi_status type_status;\n"
        "\tint type;\n\n"
        "\tacpi_handle_info(handle, \"A14TRACE2 check-add ENTER first_pass=%d\\n\", first_pass);\n"
        "\tacpi_handle_info(handle, \"A14TRACE2 before fetch-existing\\n\");\n"
        "\tdevice = acpi_fetch_acpi_dev(handle);\n"
        "\tacpi_handle_info(handle, \"A14TRACE2 after fetch-existing exists=%d\\n\", !!device);\n"
        "\tif (device) {\n"
        "\t\tacpi_handle_info(handle, \"A14TRACE2 existing-device -> out\\n\");\n"
        "\t\tgoto out;\n"
        "\t}\n\n"
        "\tacpi_handle_info(handle, \"A14TRACE2 before get-type\\n\");\n"
        "\ttype_status = acpi_get_type(handle, &acpi_type);\n"
        "\tif (ACPI_FAILURE(type_status)) {\n"
        "\t\tacpi_handle_info(handle, \"A14TRACE2 get-type FAILED status=0x%x -> return\\n\", type_status);\n"
        "\t\treturn AE_OK;\n"
        "\t}\n"
        "\tacpi_handle_info(handle, \"A14TRACE2 after get-type type=%u\\n\", acpi_type);\n",
        "scan_trace_v2_entry",
    )

    replace_once(
        scan,
        "\tcase ACPI_TYPE_DEVICE:\n"
        "\t\tif (acpi_device_should_be_hidden(handle))\n"
        "\t\t\treturn AE_OK;\n\n"
        "\t\tif (first_pass) {\n"
        "\t\t\tacpi_mipi_check_crs_csi2(handle);\n\n"
        "\t\t\t/* Bail out if there are dependencies. */\n"
        "\t\t\tif (acpi_scan_check_dep(handle) > 0) {\n",
        "\tcase ACPI_TYPE_DEVICE:\n"
        "\t\tacpi_handle_info(handle, \"A14TRACE2 DEVICE before hidden-check\\n\");\n"
        "\t\tif (acpi_device_should_be_hidden(handle)) {\n"
        "\t\t\tacpi_handle_info(handle, \"A14TRACE2 DEVICE hidden -> return\\n\");\n"
        "\t\t\treturn AE_OK;\n"
        "\t\t}\n"
        "\t\tacpi_handle_info(handle, \"A14TRACE2 DEVICE after hidden-check\\n\");\n\n"
        "\t\tif (first_pass) {\n"
        "\t\t\tacpi_handle_info(handle, \"A14TRACE2 DEVICE before mipi-crs-check\\n\");\n"
        "\t\t\tacpi_mipi_check_crs_csi2(handle);\n"
        "\t\t\tacpi_handle_info(handle, \"A14TRACE2 DEVICE after mipi-crs-check\\n\");\n\n"
        "\t\t\t/* Bail out if there are dependencies. */\n"
        "\t\t\tacpi_handle_info(handle, \"A14TRACE2 DEVICE before dependency-check\\n\");\n"
        "\t\t\tif (acpi_scan_check_dep(handle) > 0) {\n"
        "\t\t\t\tacpi_handle_info(handle, \"A14TRACE2 DEVICE dependencies present -> postpone\\n\");\n",
        "scan_trace_v2_device_pre",
    )

    # If the dependency branch did not return, make that explicit.
    replace_once(
        scan,
        "\t\t\t\treturn AE_CTRL_DEPTH;\n"
        "\t\t\t}\n"
        "\t\t}\n\n"
        "\t\tfallthrough;\n",
        "\t\t\t\treturn AE_CTRL_DEPTH;\n"
        "\t\t\t}\n"
        "\t\t\tacpi_handle_info(handle, \"A14TRACE2 DEVICE dependency-check clear\\n\");\n"
        "\t\t}\n\n"
        "\t\tfallthrough;\n",
        "scan_trace_v2_device_dep_clear",
    )

    replace_once(
        scan,
        "\tcase ACPI_TYPE_POWER:\n"
        "\t\tacpi_handle_info(handle, \"A14TRACE scan POWER before add-power-resource\\n\");\n"
        "\t\tacpi_add_power_resource(handle);\n"
        "\t\tacpi_handle_info(handle, \"A14TRACE scan POWER after add-power-resource\\n\");\n"
        "\t\tfallthrough;\n"
        "\tdefault:\n"
        "\t\treturn AE_OK;\n"
        "\t}\n",
        "\tcase ACPI_TYPE_POWER:\n"
        "\t\tacpi_handle_info(handle, \"A14TRACE scan POWER before add-power-resource\\n\");\n"
        "\t\tacpi_add_power_resource(handle);\n"
        "\t\tacpi_handle_info(handle, \"A14TRACE scan POWER after add-power-resource\\n\");\n"
        "\t\tfallthrough;\n"
        "\tdefault:\n"
        "\t\tacpi_handle_info(handle, \"A14TRACE2 non-device type=%u -> return AE_OK\\n\", acpi_type);\n"
        "\t\treturn AE_OK;\n"
        "\t}\n",
        "scan_trace_v2_nondevice_return",
    )

    replace_once(
        scan,
        "\tacpi_add_single_object(&device, handle, type, !first_pass);\n"
        "\tif (!device)\n"
        "\t\treturn AE_CTRL_DEPTH;\n\n"
        "\tacpi_scan_init_hotplug(device);\n\n"
        "out:\n"
        "\tif (!*adev_p)\n"
        "\t\t*adev_p = device;\n\n"
        "\treturn AE_OK;\n",
        "\tacpi_handle_info(handle, \"A14TRACE2 before add-single-object type=%d enumerate=%d\\n\", type, !first_pass);\n"
        "\tacpi_add_single_object(&device, handle, type, !first_pass);\n"
        "\tacpi_handle_info(handle, \"A14TRACE2 after add-single-object device=%px\\n\", device);\n"
        "\tif (!device) {\n"
        "\t\tacpi_handle_info(handle, \"A14TRACE2 add-single-object NULL -> return depth\\n\");\n"
        "\t\treturn AE_CTRL_DEPTH;\n"
        "\t}\n\n"
        "\tacpi_handle_info(handle, \"A14TRACE2 before scan-init-hotplug\\n\");\n"
        "\tacpi_scan_init_hotplug(device);\n"
        "\tacpi_handle_info(handle, \"A14TRACE2 after scan-init-hotplug\\n\");\n\n"
        "out:\n"
        "\tacpi_handle_info(handle, \"A14TRACE2 OUT before adev_p\\n\");\n"
        "\tif (!*adev_p)\n"
        "\t\t*adev_p = device;\n"
        "\tacpi_handle_info(handle, \"A14TRACE2 OUT return AE_OK\\n\");\n\n"
        "\treturn AE_OK;\n",
        "scan_trace_v2_add_out",
    )

    replace_once(
        scan,
        "static acpi_status acpi_bus_check_add_1(acpi_handle handle, u32 lvl_not_used,\n"
        "\t\t\t\t\tvoid *not_used, void **ret_p)\n"
        "{\n"
        "\treturn acpi_bus_check_add(handle, true, (struct acpi_device **)ret_p);\n"
        "}\n\n"
        "static acpi_status acpi_bus_check_add_2(acpi_handle handle, u32 lvl_not_used,\n"
        "\t\t\t\t\tvoid *not_used, void **ret_p)\n"
        "{\n"
        "\treturn acpi_bus_check_add(handle, false, (struct acpi_device **)ret_p);\n"
        "}\n",
        "static acpi_status acpi_bus_check_add_1(acpi_handle handle, u32 lvl_not_used,\n"
        "\t\t\t\t\tvoid *not_used, void **ret_p)\n"
        "{\n"
        "\tacpi_status status;\n\n"
        "\tacpi_handle_info(handle, \"A14TRACE2 WALK1 callback ENTER\\n\");\n"
        "\tstatus = acpi_bus_check_add(handle, true, (struct acpi_device **)ret_p);\n"
        "\tacpi_handle_info(handle, \"A14TRACE2 WALK1 callback RETURN status=0x%x\\n\", status);\n"
        "\treturn status;\n"
        "}\n\n"
        "static acpi_status acpi_bus_check_add_2(acpi_handle handle, u32 lvl_not_used,\n"
        "\t\t\t\t\tvoid *not_used, void **ret_p)\n"
        "{\n"
        "\tacpi_status status;\n\n"
        "\tacpi_handle_info(handle, \"A14TRACE2 WALK2 callback ENTER\\n\");\n"
        "\tstatus = acpi_bus_check_add(handle, false, (struct acpi_device **)ret_p);\n"
        "\tacpi_handle_info(handle, \"A14TRACE2 WALK2 callback RETURN status=0x%x\\n\", status);\n"
        "\treturn status;\n"
        "}\n",
        "scan_trace_v2_walk_callbacks",
    )

    body = scan.read_text()
    required = [
        MARKER,
        "A14TRACE2 WALK1 callback ENTER",
        "A14TRACE2 check-add ENTER",
        "A14TRACE2 before fetch-existing",
        "A14TRACE2 before get-type",
        "A14TRACE2 DEVICE before dependency-check",
        "A14TRACE2 before add-single-object",
        "A14TRACE2 non-device type=",
        "A14TRACE2 WALK1 callback RETURN",
    ]
    missing = [s for s in required if s not in body]
    if missing:
        die(f"post-check failed: missing {missing}")

    print("A14_ACPI_SCAN_TRACE_V2=APPLIED")
    print("scope=every-namespace-callback-before-fetch/type/device-add")


if __name__ == "__main__":
    main()
