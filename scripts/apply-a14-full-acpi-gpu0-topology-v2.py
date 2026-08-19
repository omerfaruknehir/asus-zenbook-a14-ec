#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Apply the QCOM0C36 no-MMIO topology bridge safely and idempotently.

Linux exposes the initialized ACPI coherent_dma flag in struct acpi_device but
does not export acpi_get_dma_attr() to modules. The recovered A14 config builds
MSM DRM as a module, so derive the same coherent/non-coherent choice from the
parent ACPI device's initialized flag.

Important: once the V2 bridge is present, do not rerun the V1 exact-block
inserter because V2 intentionally changes two lines inside that block.
"""

from pathlib import Path
import subprocess
import sys

MARKER = "A14_QCOM0C36_TOPOLOGY_V1"
SAFE = "adev->flags.coherent_dma ? DEV_DMA_COHERENT"
EXPORT = "EXPORT_SYMBOL_GPL(iort_iommu_configure_id);"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 GPU topology V2 transform: {msg}")


def verify(root: Path) -> None:
    msm = root / "drivers/gpu/drm/msm/msm_drv.c"
    iort = root / "drivers/acpi/arm64/iort.c"
    body = msm.read_text()
    ibody = iort.read_text()

    required = [
        MARKER,
        '"QCOM0C36", 0',
        "0x03030000",
        "0x03030020",
        "0x03030060",
        "a14-adreno-x185-acpi-topology",
        "a14-gmu-x185-acpi-topology",
        "a14-gpucc-x1e80100-acpi-topology",
        "gmu_watchdog_irq=firmware-unexposed",
        "no_mmio=true",
    ]
    missing = [x for x in required if x not in body]
    if missing:
        fail(f"bridge verification missing: {missing}")
    if body.count(SAFE) != 2:
        fail(f"expected two module-safe DMA attribute selections, found {body.count(SAFE)}")
    if "acpi_get_dma_attr(adev)" in body:
        fail("unexported acpi_get_dma_attr call remains")
    if EXPORT not in ibody:
        fail("IORT configure-id GPL export missing")


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: apply-a14-full-acpi-gpu0-topology-v2.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    msm = root / "drivers/gpu/drm/msm/msm_drv.c"
    iort = root / "drivers/acpi/arm64/iort.c"
    if not msm.is_file() or not iort.is_file():
        fail(f"not the expected Linux source tree: {root}")

    # Fully-applied V2 state: verify and stop. This is what makes repeated
    # build commands safe even though V2 differs textually from V1's block.
    if MARKER in msm.read_text() and SAFE in msm.read_text() and EXPORT in iort.read_text():
        verify(root)
        print("topology_v1=current")
        print("module_safe_dma_attr=current")
        print("A14_QCOM0C36_TOPOLOGY_V2=APPLIED")
        print("module_link_unexported_acpi_get_dma_attr=false")
        print("dma_coherency_source=parent_ACPI_initialized_flag")
        print("hardware_driver_binding=disabled_this_layer")
        print("gpu_mmio_access=none")
        return

    base = Path(__file__).with_name("apply-a14-full-acpi-gpu0-topology.py")
    if not base.is_file():
        fail(f"missing base transform: {base}")

    subprocess.run([sys.executable, str(base), str(root)], check=True)

    text = msm.read_text()
    old = "\tattr = acpi_get_dma_attr(adev);\n"
    new = ("\tattr = adev->flags.coherent_dma ? DEV_DMA_COHERENT :\n"
           "\t\t\t\t\t      DEV_DMA_NON_COHERENT;\n")

    if old in text:
        count = text.count(old)
        if count != 2:
            fail(f"expected two acpi_get_dma_attr bridge calls, found {count}")
        msm.write_text(text.replace(old, new))
        print("module_safe_dma_attr=applied")
    elif text.count(new) == 2:
        print("module_safe_dma_attr=current")
    else:
        fail("cannot identify bridge DMA attribute state")

    verify(root)
    print("A14_QCOM0C36_TOPOLOGY_V2=APPLIED")
    print("module_link_unexported_acpi_get_dma_attr=false")
    print("dma_coherency_source=parent_ACPI_initialized_flag")
    print("hardware_driver_binding=disabled_this_layer")
    print("gpu_mmio_access=none")


if __name__ == "__main__":
    main()
