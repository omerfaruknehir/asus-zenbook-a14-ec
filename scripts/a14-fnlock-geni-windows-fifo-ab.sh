#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-status}"
KVER="$(uname -r)"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="/var/tmp/a14-fnlock-geni-windows-fifo-${KVER}"
SOURCE_URL="https://raw.githubusercontent.com/gregkh/linux/v7.1.5/drivers/i2c/busses/i2c-qcom-geni.c"
EXPECTED_BLOB_SHA1="a482a4c60744a5dece929da8a5e3a8e7219c8566"
INSTALL_DIR="/lib/modules/${KVER}/updates/a14"
INSTALL_MODULE="${INSTALL_DIR}/i2c-qcom-geni.ko"
CONF="/etc/modprobe.d/a14-fnlock-geni-windows-fifo.conf"
OLD_TIMING_CONF="/etc/modprobe.d/a14-fnlock-geni-windows-timing.conf"

say() { printf '%s\n' "$*"; }
die() { say "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
need_root() { [[ ${EUID} -eq 0 ]] || die "action '$ACTION' must be run as root"; }

check_kernel() {
    [[ -d "/lib/modules/${KVER}/build" ]] || die "kernel headers/build tree missing: /lib/modules/${KVER}/build"
    case "$KVER" in
        7.1.5-070105-generic) ;;
        *) die "this diagnostic is pinned to 7.1.5-070105-generic; running kernel is $KVER" ;;
    esac
}

fetch_source() {
    mkdir -p "$WORK"
    local orig="$WORK/i2c-qcom-geni.c.orig"

    if [[ ! -s "$orig" ]]; then
        if command -v curl >/dev/null 2>&1; then
            curl -fL --retry 3 --connect-timeout 20 -o "$orig" "$SOURCE_URL"
        elif command -v wget >/dev/null 2>&1; then
            wget -O "$orig" "$SOURCE_URL"
        else
            die "curl or wget is required to fetch the pinned v7.1.5 source"
        fi
    fi

    local actual
    actual="$(git hash-object "$orig")"
    [[ "$actual" == "$EXPECTED_BLOB_SHA1" ]] || {
        rm -f "$orig"
        die "pinned source verification failed: git-blob=$actual expected=$EXPECTED_BLOB_SHA1"
    }
    say "source_blob_sha1=$actual"
}

patch_source() {
    cp -f "$WORK/i2c-qcom-geni.c.orig" "$WORK/i2c-qcom-geni.c"

    python3 - "$WORK/i2c-qcom-geni.c" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

include_anchor = '#include <linux/units.h>\n'
param_block = r'''

/*
 * ASUS Zenbook A14 UX3407RA Fn-lock data-path A/B.
 *
 * Captured Windows qci2c8380.sys uses the GENI FIFO path when the hardware
 * FIFO interface is available and keeps SE_GENI_DMA_MODE_EN cleared. Linux
 * v7.1.5 opportunistically selects internal SE-DMA for non-GPI messages at
 * least 32 bytes long. The HID-over-I2C Fn-lock SET_FEATURE write is 73 bytes.
 *
 * This diagnostic changes only 73-byte writes to slave 0x15 on the physical
 * GENI controller at 0x00a80000, and only in Linux's non-GPI path. It does not
 * alter the global timing tables, GPI mode, or any other controller/device.
 */
static bool a14_windows_fifo;
module_param(a14_windows_fifo, bool, 0644);
MODULE_PARM_DESC(a14_windows_fifo,
                 "UX3407RA diagnostic: force 73-byte writes to 0x15 on GENI 0x00a80000 through FIFO instead of SE-DMA");
'''

if param_block.strip() not in s:
    if s.count(include_anchor) != 1:
        raise SystemExit(f'include anchor count={s.count(include_anchor)}')
    s = s.replace(include_anchor, include_anchor + param_block, 1)

func_anchor = '''static int geni_i2c_tx_one_msg(struct geni_i2c_dev *gi2c, struct i2c_msg *msg,\n\t\t\t\tu32 m_param)\n{\n'''
func_end_anchor = '\nstatic void i2c_gpi_cb_result('
helper = '''static bool a14_fnlock_i2c_target(struct geni_i2c_dev *gi2c)\n{\n\tstruct platform_device *pdev = to_platform_device(gi2c->se.dev);\n\tstruct resource *res;\n\n\tres = platform_get_resource(pdev, IORESOURCE_MEM, 0);\n\treturn res && res->start == 0x00a80000;\n}\n\n'''
if helper not in s:
    if s.count(func_anchor) != 1:
        raise SystemExit(f'tx function anchor count={s.count(func_anchor)}')
    s = s.replace(func_anchor, helper + func_anchor, 1)

old_dma = '''\tdma_buf = gi2c->no_dma ? NULL : i2c_get_dma_safe_msg_buf(msg, 32);\n\tif (dma_buf)\n\t\tgeni_se_select_mode(se, GENI_SE_DMA);\n\telse\n\t\tgeni_se_select_mode(se, GENI_SE_FIFO);\n'''
new_dma = '''\tbool a14_force_fifo = a14_windows_fifo &&\n\t\ta14_fnlock_i2c_target(gi2c) &&\n\t\tmsg->addr == 0x15 && len == 73;\n\n\tdma_buf = (gi2c->no_dma || a14_force_fifo) ? NULL :\n\t\ti2c_get_dma_safe_msg_buf(msg, 32);\n\tif (dma_buf)\n\t\tgeni_se_select_mode(se, GENI_SE_DMA);\n\telse\n\t\tgeni_se_select_mode(se, GENI_SE_FIFO);\n\n\tif (a14_force_fifo)\n\t\tdev_info_ratelimited(gi2c->se.dev,\n\t\t\t"A14 Fn-lock Windows FIFO A/B: addr=0x%02x len=%zu forced=FIFO (SE-DMA bypassed)\\n",\n\t\t\tmsg->addr, len);\n'''

# The stock source has the same DMA-selection sequence in both RX and TX.
# Restrict replacement to geni_i2c_tx_one_msg() so reads remain byte-for-byte
# stock and this A/B changes only the Fn-lock write data path.
if s.count(func_anchor) != 1:
    raise SystemExit(f'tx function anchor after helper count={s.count(func_anchor)}')
tx_start = s.index(func_anchor)
try:
    tx_end = s.index(func_end_anchor, tx_start)
except ValueError:
    raise SystemExit('tx function end anchor missing')
tx = s[tx_start:tx_end]
if new_dma not in tx:
    if tx.count(old_dma) != 1:
        raise SystemExit(f'TX SE-DMA selection anchor count={tx.count(old_dma)}')
    tx = tx.replace(old_dma, new_dma, 1)
    s = s[:tx_start] + tx + s[tx_end:]

probe_old = '''\tif (desc && desc->no_dma_support) {\n\t\tfifo_disable = false;\n\t\tgi2c->no_dma = true;\n\t} else {\n\t\tfifo_disable = readl_relaxed(gi2c->se.base + GENI_IF_DISABLE_RO) & FIFO_IF_DISABLE;\n\t}\n\n\tif (fifo_disable) {\n'''
probe_new = '''\tif (desc && desc->no_dma_support) {\n\t\tfifo_disable = false;\n\t\tgi2c->no_dma = true;\n\t} else {\n\t\tfifo_disable = readl_relaxed(gi2c->se.base + GENI_IF_DISABLE_RO) & FIFO_IF_DISABLE;\n\t}\n\n\tif (a14_fnlock_i2c_target(gi2c))\n\t\tdev_info(gi2c->se.dev,\n\t\t\t "A14 Fn-lock GENI data path: GENI_IF_DISABLE_RO=0x%08x FIFO_IF_DISABLE=%u windows_fifo=%u\\n",\n\t\t\t readl_relaxed(gi2c->se.base + GENI_IF_DISABLE_RO),\n\t\t\t fifo_disable ? 1 : 0, a14_windows_fifo ? 1 : 0);\n\n\tif (fifo_disable) {\n'''
if probe_new not in s:
    if s.count(probe_old) != 1:
        raise SystemExit(f'probe FIFO-mode anchor count={s.count(probe_old)}')
    s = s.replace(probe_old, probe_new, 1)

# Strong post-transform guards: exactly one force site, it is in the TX
# function, and the RX function still retains its original DMA-selection path.
if s.count('A14 Fn-lock Windows FIFO A/B:') != 1:
    raise SystemExit('unexpected number of FIFO A/B log sites')
if s.count('bool a14_force_fifo =') != 1:
    raise SystemExit('unexpected number of FIFO force predicates')
rx_start = s.index('static int geni_i2c_rx_one_msg(')
rx_end = s.index(func_anchor, rx_start)
rx = s[rx_start:rx_end]
if rx.count(old_dma) != 1:
    raise SystemExit('RX DMA-selection path was unexpectedly changed')

# The timing A/B is already disproven. Refuse any source that also contains its
# Windows timing tuple globally; this experiment must change only the data path.
linux_tuple = '{ I2C_MAX_FAST_MODE_FREQ, 2,  5, 11, 22 },'
if linux_tuple not in s:
    raise SystemExit('expected stock v7.1.5 19.2MHz/400kHz tuple missing')
if '{ I2C_MAX_FAST_MODE_FREQ, 2,  5, 12, 24 },' in s:
    raise SystemExit('refusing source with globally modified Windows timing tuple')

p.write_text(s)
PY

    cat > "$WORK/Makefile" <<'EOF'
obj-m := i2c-qcom-geni.o
EOF
}

build_module() {
    check_kernel
    need git
    need make
    need python3
    need modinfo
    fetch_source
    patch_source

    make -C "/lib/modules/${KVER}/build" M="$WORK" clean >/dev/null
    make -C "/lib/modules/${KVER}/build" M="$WORK" modules
    [[ -s "$WORK/i2c-qcom-geni.ko" ]] || die "module build did not produce i2c-qcom-geni.ko"

    local vermagic
    vermagic="$(modinfo -F vermagic "$WORK/i2c-qcom-geni.ko")"
    say "built_module=$WORK/i2c-qcom-geni.ko"
    say "built_vermagic=$vermagic"
    [[ "$vermagic" == "$KVER "* || "$vermagic" == "$KVER"* ]] ||
        die "module vermagic does not match running kernel"
    modinfo "$WORK/i2c-qcom-geni.ko" | grep -E '^(filename|license|description|parm|vermagic):' || true
}

install_module() {
    need_root
    build_module
    need depmod
    command -v update-initramfs >/dev/null 2>&1 || die "update-initramfs not found"

    install -d -m 0755 "$INSTALL_DIR"
    install -m 0644 "$WORK/i2c-qcom-geni.ko" "$INSTALL_MODULE"

    # Do not carry the already-disproven timing parameter into this module.
    rm -f "$OLD_TIMING_CONF"
    cat > "$CONF" <<'EOF'
# UX3407RA Fn-lock diagnostic A/B. In the non-GPI path, force only the exact
# 73-byte HID-over-I2C write to keyboard address 0x15 on controller 0x00a80000
# through GENI FIFO instead of Linux's opportunistic internal SE-DMA path.
options i2c-qcom-geni a14_windows_fifo=1
EOF

    depmod -a "$KVER"
    local resolved
    resolved="$(modinfo -k "$KVER" -n i2c-qcom-geni)"
    say "resolved_module=$resolved"
    if [[ "$resolved" != "$INSTALL_MODULE" ]]; then
        rm -f "$INSTALL_MODULE" "$CONF"
        depmod -a "$KVER"
        die "depmod did not select the FIFO A/B module; restored stock resolution"
    fi

    update-initramfs -u -k "$KVER"
    say "A14_FNLOCK_GENI_WINDOWS_FIFO_AB=INSTALLED"
    say "A reboot is required. The stock module remains untouched at its kernel/ path."
}

remove_module() {
    need_root
    need depmod
    command -v update-initramfs >/dev/null 2>&1 || die "update-initramfs not found"

    rm -f "$INSTALL_MODULE" "$CONF" "$OLD_TIMING_CONF"
    rmdir "$INSTALL_DIR" 2>/dev/null || true
    depmod -a "$KVER"
    update-initramfs -u -k "$KVER"
    say "stock_module=$(modinfo -k "$KVER" -n i2c-qcom-geni 2>/dev/null || true)"
    say "A14_FNLOCK_GENI_WINDOWS_FIFO_AB=REMOVED"
    if [[ -d /sys/module/i2c_qcom_geni ]]; then
        say "The currently loaded module is unchanged until reboot."
    fi
}

status() {
    say "===== A14 FN-LOCK GENI WINDOWS FIFO A/B STATUS ====="
    say "kernel=$KVER"
    say "resolved_module=$(modinfo -k "$KVER" -n i2c-qcom-geni 2>/dev/null || echo unavailable)"
    say "override_file=$([[ -f "$INSTALL_MODULE" ]] && echo present || echo absent)"
    say "modprobe_conf=$([[ -f "$CONF" ]] && echo present || echo absent)"
    say "old_timing_conf=$([[ -f "$OLD_TIMING_CONF" ]] && echo present || echo absent)"
    if [[ -r /sys/module/i2c_qcom_geni/parameters/a14_windows_fifo ]]; then
        say "loaded_a14_windows_fifo=$(cat /sys/module/i2c_qcom_geni/parameters/a14_windows_fifo)"
    else
        say "loaded_a14_windows_fifo=parameter-unavailable-on-currently-loaded-module"
    fi
    say "----- relevant dmesg -----"
    dmesg 2>/dev/null | grep -E 'A14 Fn-lock GENI data path|A14 Fn-lock Windows FIFO A/B|a80000\.i2c|0B05:0220' | tail -n 80 || true
}

case "$ACTION" in
    build) build_module ;;
    install) install_module ;;
    remove|rollback|uninstall) remove_module ;;
    status) status ;;
    *)
        cat >&2 <<EOF
Usage: sudo bash ${0#$ROOT/} {install|status|remove}
       bash ${0#$ROOT/} build
EOF
        exit 2
        ;;
esac
