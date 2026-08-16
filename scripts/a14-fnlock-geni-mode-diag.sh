#!/usr/bin/env bash
set -euo pipefail

DEV="/sys/devices/platform/soc@0/ac0000.geniqup/a80000.i2c"
RES="$DEV/resource0"

echo '===== A14 FN-LOCK GENI LIVE MODE DIAGNOSTIC ====='
echo "kernel=$(uname -r)"
echo "controller_path=$DEV"

if [[ ${EUID} -ne 0 ]]; then
    echo "ERROR: run with sudo" >&2
    exit 1
fi

if [[ ! -e "$RES" ]]; then
    echo "resource0=unavailable"
    echo "note=this platform device does not export an mmap-able resource0 sysfs file"

    LOG="$(dmesg 2>/dev/null | grep 'A14 Fn-lock GENI data path:' | tail -n 1 || true)"
    if [[ -n "$LOG" ]]; then
        echo "mode_source=kernel-driver-log"
        echo "$LOG"
        if grep -q 'FIFO_IF_DISABLE=1' <<<"$LOG"; then
            echo "FIFO_IF_DISABLE=1"
            echo "controller_transport=GPI-only (FIFO interface disabled by hardware)"
            echo "fnlock_datapath_hypothesis=WINDOWS_FIFO_VS_LINUX_SE_DMA_NOT_APPLICABLE"
        elif grep -q 'FIFO_IF_DISABLE=0' <<<"$LOG"; then
            echo "FIFO_IF_DISABLE=0"
            echo "controller_transport=FIFO-capable"
            echo "fnlock_datapath_hypothesis=WINDOWS_FIFO_VS_LINUX_SE_DMA_APPLICABLE"
        else
            echo "FIFO_IF_DISABLE=unknown"
        fi
        echo 'A14_FNLOCK_GENI_MODE_DIAG=COMPLETE'
        exit 0
    fi

    echo "mode_source=unavailable-on-current-module"
    echo "next_step=use a14-fnlock-geni-windows-fifo-ab.sh; that module reads GENI_IF_DISABLE_RO directly from mapped controller MMIO and logs the result"
    echo 'A14_FNLOCK_GENI_MODE_DIAG=NEEDS_KERNEL_LOG_PROBE'
    exit 0
fi

python3 - "$RES" <<'PY'
import mmap
import os
import struct
import sys

path = sys.argv[1]
regs = (
    ("SE_GENI_STATUS",          0x040),
    ("GENI_SER_M_CLK_CFG",     0x048),
    ("GENI_IF_DISABLE_RO",     0x064),
    ("SE_GENI_DMA_MODE_EN",    0x258),
    ("SE_I2C_SCL_COUNTERS",    0x278),
    ("SE_GENI_M_CMD0",         0x600),
    ("SE_GENI_M_IRQ_STATUS",   0x610),
)

fd = os.open(path, os.O_RDONLY | getattr(os, "O_SYNC", 0))
try:
    mm = mmap.mmap(fd, 0x1000, flags=mmap.MAP_SHARED, prot=mmap.PROT_READ)
    try:
        values = {}
        for name, off in regs:
            value = struct.unpack_from("<I", mm, off)[0]
            values[name] = value
            print(f"{name}@0x{off:03x}=0x{value:08x}")
    finally:
        mm.close()
finally:
    os.close(fd)

fifo_disabled = bool(values["GENI_IF_DISABLE_RO"] & 1)
dma_mode = bool(values["SE_GENI_DMA_MODE_EN"] & 1)
print(f"FIFO_IF_DISABLE={1 if fifo_disabled else 0}")
print(f"CURRENT_SE_DMA_MODE={1 if dma_mode else 0}")
if fifo_disabled:
    print("controller_transport=GPI-only (FIFO interface disabled by hardware)")
    print("fnlock_datapath_hypothesis=WINDOWS_FIFO_VS_LINUX_SE_DMA_NOT_APPLICABLE")
else:
    print("controller_transport=FIFO-capable")
    print("fnlock_datapath_hypothesis=WINDOWS_FIFO_VS_LINUX_SE_DMA_APPLICABLE")
    print("note=Linux non-GPI transfers >=32 bytes normally select SE-DMA; Windows qci2c non-GPI path uses GENI FIFO and keeps SE_GENI_DMA_MODE_EN cleared")
PY

echo 'A14_FNLOCK_GENI_MODE_DIAG=COMPLETE'
