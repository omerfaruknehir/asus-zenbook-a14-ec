#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-status}"
KVER="$(uname -r)"
WORK="/var/tmp/a14-fnlock-hidi2c-skip-probe-${KVER}"
SRC="${WORK}/drivers/hid/i2c-hid"
INSTALL_DIR="/lib/modules/${KVER}/updates/a14"
INSTALL_MODULE="${INSTALL_DIR}/i2c-hid.ko"
CONF="/etc/modprobe.d/a14-fnlock-hidi2c-skip-probe.conf"

# Previous controller-level A/Bs are disproven. This experiment must restore
# the stock GENI module/config so the only changed variable is first-contact
# HID-over-I2C enumeration behavior.
OLD_GENI_MODULE="${INSTALL_DIR}/i2c-qcom-geni.ko"
OLD_GENI_TIMING_CONF="/etc/modprobe.d/a14-fnlock-geni-windows-timing.conf"
OLD_GENI_FIFO_CONF="/etc/modprobe.d/a14-fnlock-geni-windows-fifo.conf"

BASE_URL="https://raw.githubusercontent.com/gregkh/linux/v7.1.5"
CORE_URL="${BASE_URL}/drivers/hid/i2c-hid/i2c-hid-core.c"
DMI_URL="${BASE_URL}/drivers/hid/i2c-hid/i2c-hid-dmi-quirks.c"
HEADER_URL="${BASE_URL}/drivers/hid/i2c-hid/i2c-hid.h"
HID_IDS_URL="${BASE_URL}/drivers/hid/hid-ids.h"

CORE_SHA1="3adb16366e93941118bf83d0fed3a98b75ed2524"
DMI_SHA1="210f17c3a0be05f47b78b7839ac9f3a0b28be5eb"
HEADER_SHA1="1724a435c783aaeecf59334c66e6d21eeebc54b2"
HID_IDS_SHA1="426ff78c1c033d6b9ced1e5790aa6a39807ee309"

say() { printf '%s\n' "$*"; }
die() { say "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
need_root() { [[ ${EUID} -eq 0 ]] || die "action '$ACTION' must be run as root"; }

kernel_config() {
    if [[ -r "/boot/config-${KVER}" ]]; then
        printf '%s\n' "/boot/config-${KVER}"
    elif [[ -r /proc/config.gz ]]; then
        printf '%s\n' /proc/config.gz
    else
        return 1
    fi
}

config_get() {
    local key="$1" cfg
    cfg="$(kernel_config)" || return 1
    if [[ "$cfg" == /proc/config.gz ]]; then
        zgrep -m1 "^${key}=" "$cfg" || true
    else
        grep -m1 "^${key}=" "$cfg" || true
    fi
}

check_kernel() {
    [[ -d "/lib/modules/${KVER}/build" ]] ||
        die "kernel headers/build tree missing: /lib/modules/${KVER}/build"
    case "$KVER" in
        7.1.5-070105-generic) ;;
        *) die "this diagnostic is pinned to 7.1.5-070105-generic; running kernel is $KVER" ;;
    esac

    local core_cfg of_cfg
    core_cfg="$(config_get CONFIG_I2C_HID_CORE)"
    of_cfg="$(config_get CONFIG_I2C_HID_OF)"
    say "${core_cfg:-CONFIG_I2C_HID_CORE=unknown}"
    say "${of_cfg:-CONFIG_I2C_HID_OF=unknown}"
    [[ "$core_cfg" == "CONFIG_I2C_HID_CORE=m" ]] ||
        die "I2C HID core is not modular; refusing an external replacement"
}

fetch_one() {
    local url="$1" dest="$2" expected="$3" actual
    mkdir -p "$(dirname "$dest")"
    if [[ ! -s "$dest" ]]; then
        if command -v curl >/dev/null 2>&1; then
            curl -fL --retry 3 --connect-timeout 20 -o "$dest" "$url"
        elif command -v wget >/dev/null 2>&1; then
            wget -O "$dest" "$url"
        else
            die "curl or wget is required to fetch pinned v7.1.5 sources"
        fi
    fi

    actual="$(git hash-object "$dest")"
    if [[ "$actual" != "$expected" ]]; then
        rm -f "$dest"
        die "source verification failed for $dest: git-blob=$actual expected=$expected"
    fi
    say "source_blob_sha1[$(basename "$dest")]=$actual"
}

fetch_sources() {
    mkdir -p "$SRC"
    fetch_one "$CORE_URL" "$SRC/i2c-hid-core.c.orig" "$CORE_SHA1"
    fetch_one "$DMI_URL" "$SRC/i2c-hid-dmi-quirks.c" "$DMI_SHA1"
    fetch_one "$HEADER_URL" "$SRC/i2c-hid.h" "$HEADER_SHA1"
    fetch_one "$HID_IDS_URL" "$WORK/drivers/hid/hid-ids.h" "$HID_IDS_SHA1"
}

patch_source() {
    cp -f "$SRC/i2c-hid-core.c.orig" "$SRC/i2c-hid-core.c"

    python3 - "$SRC/i2c-hid-core.c" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

probe_func = '''static int i2c_hid_probe_address(struct i2c_hid *ihid)\n{\n'''
helper = r'''/*
 * ASUS Zenbook A14 UX3407RA Fn-lock cold-boot enumeration A/B.
 *
 * Windows HIDI2C begins enumeration with the HID descriptor address/write
 * and descriptor read. Linux v7.1.5 first performs an extra raw
 * i2c_smbus_read_byte() address-presence probe. This opt-in diagnostic skips
 * only that first raw probe for the physical a80000.i2c controller at 0x15.
 * All later Linux HID-over-I2C power/reset/report and GENI behavior remains
 * stock for this experiment.
 */
static bool a14_skip_initial_probe;
module_param(a14_skip_initial_probe, bool, 0644);
MODULE_PARM_DESC(a14_skip_initial_probe,
                 "UX3407RA diagnostic: skip Linux raw pre-HID-descriptor I2C address probe on a80000.i2c/0x15");

static bool a14_fnlock_hidi2c_target(struct i2c_hid *ihid)
{
	struct i2c_client *client = ihid->client;
	struct device *parent;

	if (!client || client->addr != 0x15 || !client->adapter)
		return false;

	parent = client->adapter->dev.parent;
	return parent && !strcmp(dev_name(parent), "a80000.i2c");
}

'''

if helper not in s:
    if s.count(probe_func) != 1:
        raise SystemExit(f'probe function anchor count={s.count(probe_func)}')
    s = s.replace(probe_func, helper + probe_func, 1)

old = '''\tret = i2c_hid_probe_address(ihid);\n\tif (ret < 0) {\n\t\ti2c_hid_dbg(ihid, "nothing at this address: %d\\n", ret);\n\t\treturn -ENXIO;\n\t}\n'''
new = '''\tif (a14_skip_initial_probe && a14_fnlock_hidi2c_target(ihid)) {\n\t\tdev_info(&client->dev,\n\t\t\t "A14 Fn-lock Windows enumeration A/B: skipping Linux raw initial i2c_smbus_read_byte() probe on a80000.i2c addr=0x15\\n");\n\t} else {\n\t\tret = i2c_hid_probe_address(ihid);\n\t\tif (ret < 0) {\n\t\t\ti2c_hid_dbg(ihid, "nothing at this address: %d\\n", ret);\n\t\t\treturn -ENXIO;\n\t\t}\n\t}\n'''

if new not in s:
    if s.count(old) != 1:
        raise SystemExit(f'initial address-probe callsite count={s.count(old)}')
    s = s.replace(old, new, 1)

# Guard the experiment's scope. Do not silently modify Linux's power/reset
# sequence in the same A/B.
if s.count('A14 Fn-lock Windows enumeration A/B:') != 1:
    raise SystemExit('unexpected number of A14 enumeration log sites')
if s.count('a14_skip_initial_probe') < 4:
    raise SystemExit('A14 skip-probe instrumentation incomplete')
if 'msleep(60);' not in s:
    raise SystemExit('stock Linux 60-ms POWER_ON delay unexpectedly changed')
if 'if (!(ihid->quirks & I2C_HID_QUIRK_NO_WAKEUP_AFTER_RESET))' not in s:
    raise SystemExit('stock Linux post-reset POWER_ON path unexpectedly changed')

p.write_text(s)
PY

    cat > "$SRC/Makefile" <<'EOF'
obj-m := i2c-hid.o
i2c-hid-y := i2c-hid-core.o
i2c-hid-$(CONFIG_DMI) += i2c-hid-dmi-quirks.o
EOF
}

build_module() {
    check_kernel
    need git
    need make
    need python3
    need modinfo
    fetch_sources
    patch_source

    make -C "/lib/modules/${KVER}/build" M="$SRC" clean >/dev/null
    make -C "/lib/modules/${KVER}/build" M="$SRC" modules
    [[ -s "$SRC/i2c-hid.ko" ]] || die "module build did not produce i2c-hid.ko"

    local vermagic
    vermagic="$(modinfo -F vermagic "$SRC/i2c-hid.ko")"
    say "built_module=$SRC/i2c-hid.ko"
    say "built_vermagic=$vermagic"
    [[ "$vermagic" == "$KVER "* || "$vermagic" == "$KVER"* ]] ||
        die "module vermagic does not match running kernel"

    modinfo "$SRC/i2c-hid.ko" |
        grep -E '^(filename|license|description|parm|vermagic):' || true
}

restore_stock_geni_for_next_boot() {
    rm -f "$OLD_GENI_MODULE" "$OLD_GENI_TIMING_CONF" "$OLD_GENI_FIFO_CONF"
}

install_module() {
    need_root
    build_module
    need depmod
    command -v update-initramfs >/dev/null 2>&1 || die "update-initramfs not found"

    install -d -m 0755 "$INSTALL_DIR"

    # Build first, then remove the disproven GENI A/Bs only once we know the
    # replacement HID module is valid.
    restore_stock_geni_for_next_boot
    install -m 0644 "$SRC/i2c-hid.ko" "$INSTALL_MODULE"

    cat > "$CONF" <<'EOF'
# UX3407RA Fn-lock cold-boot enumeration A/B.
# Change one variable only: omit Linux's raw pre-HID-descriptor SMBus byte-read
# probe on controller a80000.i2c, address 0x15.
options i2c-hid a14_skip_initial_probe=1
EOF

    depmod -a "$KVER"

    local hid_resolved geni_resolved
    hid_resolved="$(modinfo -k "$KVER" -n i2c-hid)"
    geni_resolved="$(modinfo -k "$KVER" -n i2c-qcom-geni)"
    say "resolved_i2c_hid=$hid_resolved"
    say "resolved_i2c_qcom_geni=$geni_resolved"

    if [[ "$hid_resolved" != "$INSTALL_MODULE" ]]; then
        rm -f "$INSTALL_MODULE" "$CONF"
        depmod -a "$KVER"
        die "depmod did not select the A/B i2c-hid module; restored stock HID resolution"
    fi

    if [[ "$geni_resolved" == "$OLD_GENI_MODULE" ]]; then
        rm -f "$INSTALL_MODULE" "$CONF"
        depmod -a "$KVER"
        die "GENI experiment still resolves from updates/a14; refusing mixed A/B"
    fi

    update-initramfs -u -k "$KVER"
    say "A14_FNLOCK_HIDI2C_SKIP_PROBE_AB=INSTALLED"
    say "Use a full power-off/power-on for the test, not only a warm reboot."
}

remove_module() {
    need_root
    need depmod
    command -v update-initramfs >/dev/null 2>&1 || die "update-initramfs not found"

    rm -f "$INSTALL_MODULE" "$CONF"
    restore_stock_geni_for_next_boot
    rmdir "$INSTALL_DIR" 2>/dev/null || true
    depmod -a "$KVER"
    update-initramfs -u -k "$KVER"

    say "stock_i2c_hid=$(modinfo -k "$KVER" -n i2c-hid 2>/dev/null || true)"
    say "stock_i2c_qcom_geni=$(modinfo -k "$KVER" -n i2c-qcom-geni 2>/dev/null || true)"
    say "A14_FNLOCK_HIDI2C_SKIP_PROBE_AB=REMOVED"
    say "Currently loaded modules are unchanged until the next boot."
}

status() {
    say "===== A14 FN-LOCK HIDI2C SKIP-PROBE A/B STATUS ====="
    say "kernel=$KVER"
    say "resolved_i2c_hid=$(modinfo -k "$KVER" -n i2c-hid 2>/dev/null || echo unavailable)"
    say "resolved_i2c_qcom_geni=$(modinfo -k "$KVER" -n i2c-qcom-geni 2>/dev/null || echo unavailable)"
    say "hidi2c_override_file=$([[ -f "$INSTALL_MODULE" ]] && echo present || echo absent)"
    say "hidi2c_modprobe_conf=$([[ -f "$CONF" ]] && echo present || echo absent)"
    say "old_geni_override=$([[ -f "$OLD_GENI_MODULE" ]] && echo present || echo absent)"
    say "old_timing_conf=$([[ -f "$OLD_GENI_TIMING_CONF" ]] && echo present || echo absent)"
    say "old_fifo_conf=$([[ -f "$OLD_GENI_FIFO_CONF" ]] && echo present || echo absent)"

    if [[ -r /sys/module/i2c_hid/parameters/a14_skip_initial_probe ]]; then
        say "loaded_a14_skip_initial_probe=$(cat /sys/module/i2c_hid/parameters/a14_skip_initial_probe)"
    else
        say "loaded_a14_skip_initial_probe=parameter-unavailable-on-currently-loaded-module"
    fi

    say "----- relevant dmesg -----"
    dmesg 2>/dev/null |
        grep -E 'A14 Fn-lock Windows enumeration A/B|A14 Fn-lock GENI|Windows qci2c timing|Windows FIFO A/B|hid-over-i2c 0B05:0220|Fn-lock hardware' |
        tail -n 120 || true
}

case "$ACTION" in
    build) build_module ;;
    install) install_module ;;
    remove|rollback|uninstall) remove_module ;;
    status) status ;;
    *)
        cat >&2 <<EOF
Usage: sudo bash ${0##*/} {install|status|remove}
       bash ${0##*/} build
EOF
        exit 2
        ;;
esac
