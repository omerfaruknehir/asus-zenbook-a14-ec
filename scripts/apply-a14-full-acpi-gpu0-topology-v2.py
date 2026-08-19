#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Apply QCOM0C36 topology V1 then remove unexported ACPI helper use.

Linux exposes the initialized ACPI coherent_dma flag in struct acpi_device but
does not export acpi_get_dma_attr() to modules.  The MSM bridge is a module on
the recovered A14 config, so derive the same coherent/non-coherent choice from
the parent ACPI device's initialized flag instead.
"""

from pathlib import Path
import subprocess
import sys


def fail(msg: str) -> None:
    raise SystemExit(f"A14 GPU topology V2 transform: {msg}")


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: apply-a14-full-acpi-gpu0-topology-v2.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    base = Path(__file__).with_name("apply-a14-full-acpi-gpu0-topology.py")
    if not base.is_file():
        fail(f"missing base transform: {base}")

    subprocess.run([sys.executable, str(base), str(root)], check=True)

    msm = root / "drivers/gpu/drm/msm/msm_drv.c"
    text = msm.read_text()
    old = "\tattr = acpi_get_dma_attr(adev);\n"
    new = ("\tattr = adev->flags.coherent_dma ? DEV_DMA_COHERENT :\n"
           "\t\t\t\t\t      DEV_DMA_NON_COHERENT;\n")

    if old in text:
        count = text.count(old)
        if count != 2:
            fail(f"expected two acpi_get_dma_attr bridge calls, found {count}")
        text = text.replace(old, new)
        msm.write_text(text)
        print("module_safe_dma_attr=applied")
    elif text.count(new) == 2:
        print("module_safe_dma_attr=current")
    else:
        fail("cannot identify bridge DMA attribute state")

    body = msm.read_text()
    if "acpi_get_dma_attr(adev)" in body:
        fail("unexported acpi_get_dma_attr call remains")
    if body.count("adev->flags.coherent_dma ? DEV_DMA_COHERENT") != 2:
        fail("module-safe coherent_dma selection verification failed")

    print("A14_QCOM0C36_TOPOLOGY_V2=APPLIED")
    print("module_link_unexported_acpi_get_dma_attr=false")
    print("dma_coherency_source=parent_ACPI_initialized_flag")
    print("hardware_driver_binding=disabled_this_layer")
    print("gpu_mmio_access=none")


if __name__ == "__main__":
    main()
