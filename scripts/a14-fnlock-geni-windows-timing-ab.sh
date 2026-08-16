#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-status}"
KVER="$(uname -r)"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="/var/tmp/a14-fnlock-geni-windows-timing-${KVER}"
SOURCE_URL="https://raw.githubusercontent.com/gregkh/linux/v7.1.5/drivers/i2c/busses/i2c-qcom-geni.c"
EXPECTED_BLOB_SHA1="a482a4c60744a5dece929da8a5e3a8e7219c8566"
INSTALL_DIR="/lib/modules/${KVER}/updates/a14"
INSTALL_MODULE="${INSTALL_DIR}/i2c-qcom-geni.ko"
CONF="/etc/modprobe.d/a14-fnlock-geni-windows-timing.conf"

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
 * ASUS Zenbook A14 UX3407RA Fn-lock transport A/B.
 *
 * The Windows X1E qci2c8380.sys driver programs the 19.2-MHz / 400-kHz
 * GENI timing tuple as div=2, high=5, low=12, cycle=24. Linux v7.1.5 uses
 * div=2, high=5, low=11, cycle=22. This opt-in diagnostic changes only the
 * physical GENI controller at 0x00a80000 and only when its live SE clock is
 * exactly 19.2 MHz and the requested bus rate is exactly 400 kHz.
 */
static bool a14_windows_timing;
module_param(a14_windows_timing, bool, 0644);
MODULE_PARM_DESC(a14_windows_timing,
                 "UX3407RA diagnostic: use Windows qci2c 19.2MHz/400kHz SCL counters on GENI 0x00a80000");
'''

if param_block.strip() not in s:
    if s.count(include_anchor) != 1:
        raise SystemExit(f'include anchor count={s.count(include_anchor)}')
    s = s.replace(include_anchor, include_anchor + param_block, 1)

old = '''static void qcom_geni_i2c_conf(struct geni_i2c_dev *gi2c)\n{\n\tconst struct geni_i2c_clk_fld *itr = gi2c->clk_fld;\n\tu32 val;\n\n\twritel_relaxed(0, gi2c->se.base + SE_GENI_CLK_SEL);\n\n\tval = (itr->clk_div << CLK_DIV_SHFT) | SER_CLK_EN;\n\twritel_relaxed(val, gi2c->se.base + GENI_SER_M_CLK_CFG);\n\n\tval = itr->t_high_cnt << HIGH_COUNTER_SHFT;\n\tval |= itr->t_low_cnt << LOW_COUNTER_SHFT;\n\tval |= itr->t_cycle_cnt;\n\twritel_relaxed(val, gi2c->se.base + SE_I2C_SCL_COUNTERS);\n}\n'''

new = '''static bool a14_fnlock_i2c_target(struct geni_i2c_dev *gi2c)\n{\n\tstruct platform_device *pdev = to_platform_device(gi2c->se.dev);\n\tstruct resource *res;\n\n\tres = platform_get_resource(pdev, IORESOURCE_MEM, 0);\n\treturn res && res->start == 0x00a80000;\n}\n\nstatic void qcom_geni_i2c_conf(struct geni_i2c_dev *gi2c)\n{\n\tconst struct geni_i2c_clk_fld *itr = gi2c->clk_fld;\n\tunsigned long source_rate = clk_get_rate(gi2c->se.clk);\n\tbool a14_target = a14_fnlock_i2c_target(gi2c);\n\tu32 val;\n\n\twritel_relaxed(0, gi2c->se.base + SE_GENI_CLK_SEL);\n\n\tval = (itr->clk_div << CLK_DIV_SHFT) | SER_CLK_EN;\n\twritel_relaxed(val, gi2c->se.base + GENI_SER_M_CLK_CFG);\n\n\tval = itr->t_high_cnt << HIGH_COUNTER_SHFT;\n\tval |= itr->t_low_cnt << LOW_COUNTER_SHFT;\n\tval |= itr->t_cycle_cnt;\n\twritel_relaxed(val, gi2c->se.base + SE_I2C_SCL_COUNTERS);\n\n\tif (!a14_target)\n\t\treturn;\n\n\tdev_info_once(gi2c->se.dev,\n\t\t      "A14 Fn-lock GENI timing: source=%luHz requested=%uHz linux(div=%u high=%u low=%u cycle=%u reg=0x%08x) override=%u\\n",\n\t\t      source_rate, gi2c->clk_freq_out, itr->clk_div,\n\t\t      itr->t_high_cnt, itr->t_low_cnt, itr->t_cycle_cnt, val,\n\t\t      a14_windows_timing ? 1 : 0);\n\n\tif (!a14_windows_timing)\n\t\treturn;\n\n\tif (source_rate != 19200000 ||\n\t    gi2c->clk_freq_out != I2C_MAX_FAST_MODE_FREQ) {\n\t\tdev_warn_once(gi2c->se.dev,\n\t\t\t      "A14 Fn-lock Windows timing NOT applied: requires source=19200000Hz requested=400000Hz\\n");\n\t\treturn;\n\t}\n\n\t/* Exact 400-kHz tuple recovered from qci2c8380.sys on this X1E system. */\n\tval = 5 << HIGH_COUNTER_SHFT;\n\tval |= 12 << LOW_COUNTER_SHFT;\n\tval |= 24;\n\twritel_relaxed(val, gi2c->se.base + SE_I2C_SCL_COUNTERS);\n\tdev_info_once(gi2c->se.dev,\n\t\t      "A14 Fn-lock Windows qci2c timing APPLIED: div=2 high=5 low=12 cycle=24 reg=0x%08x\\n",\n\t\t      val);\n}\n'''

if new not in s:
    if s.count(old) != 1:
        raise SystemExit(f'qcom_geni_i2c_conf anchor count={s.count(old)}')
    s = s.replace(old, new, 1)

# Guard against accidentally modifying Qualcomm's global timing tables. The A/B
# must remain scoped to only the UX3407RA keyboard controller at runtime.
linux_tuple = '{ I2C_MAX_FAST_MODE_FREQ, 2,  5, 11, 22 },'
if linux_tuple not in s:
    raise SystemExit('expected v7.1.5 global 19.2MHz/400kHz tuple missing')
if '{ I2C_MAX_FAST_MODE_FREQ, 2,  5, 12, 24 },' in s:
    raise SystemExit('refusing globally modified timing table')

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
    need modinfo
    command -v update-initramfs >/dev/null 2>&1 || die "update-initramfs not found"

    install -d -m 0755 "$INSTALL_DIR"
    install -m 0644 "$WORK/i2c-qcom-geni.ko" "$INSTALL_MODULE"
    cat > "$CONF" <<'EOF'
# UX3407RA Fn-lock diagnostic A/B. Only the GENI controller at 0x00a80000 is
# eligible, and the module additionally requires a live 19.2-MHz source and a
# 400-kHz requested bus before changing the SCL counters.
options i2c-qcom-geni a14_windows_timing=1
EOF

    depmod -a "$KVER"
    local resolved
    resolved="$(modinfo -k "$KVER" -n i2c-qcom-geni)"
    say "resolved_module=$resolved"
    if [[ "$resolved" != "$INSTALL_MODULE" ]]; then
        rm -f "$INSTALL_MODULE" "$CONF"
        depmod -a "$KVER"
        die "depmod did not select the A/B module; restored stock resolution"
    fi

    update-initramfs -u -k "$KVER"
    say "A14_FNLOCK_GENI_WINDOWS_TIMING_AB=INSTALLED"
    say "A reboot is required. The stock module remains untouched at its kernel/ path."
}

remove_module() {
    need_root
    need depmod
    command -v update-initramfs >/dev/null 2>&1 || die "update-initramfs not found"

    rm -f "$INSTALL_MODULE" "$CONF"
    rmdir "$INSTALL_DIR" 2>/dev/null || true
    depmod -a "$KVER"
    update-initramfs -u -k "$KVER"
    say "stock_module=$(modinfo -k "$KVER" -n i2c-qcom-geni 2>/dev/null || true)"
    say "A14_FNLOCK_GENI_WINDOWS_TIMING_AB=REMOVED"
    if [[ -d /sys/module/i2c_qcom_geni ]]; then
        say "The currently loaded module is unchanged until reboot."
    fi
}

status() {
    say "===== A14 FN-LOCK GENI WINDOWS TIMING A/B STATUS ====="
    say "kernel=$KVER"
    say "resolved_module=$(modinfo -k "$KVER" -n i2c-qcom-geni 2>/dev/null || echo unavailable)"
    say "override_file=$([[ -f "$INSTALL_MODULE" ]] && echo present || echo absent)"
    say "modprobe_conf=$([[ -f "$CONF" ]] && echo present || echo absent)"
    if [[ -r /sys/module/i2c_qcom_geni/parameters/a14_windows_timing ]]; then
        say "loaded_a14_windows_timing=$(cat /sys/module/i2c_qcom_geni/parameters/a14_windows_timing)"
    else
        say "loaded_a14_windows_timing=parameter-unavailable-on-currently-loaded-module"
    fi
    say "----- relevant dmesg -----"
    dmesg 2>/dev/null | grep -E 'A14 Fn-lock GENI timing|A14 Fn-lock Windows qci2c timing|a80000\.i2c|0B05:0220' | tail -n 60 || true
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
