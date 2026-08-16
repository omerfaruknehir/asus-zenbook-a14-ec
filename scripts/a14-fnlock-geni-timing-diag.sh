#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' '===== A14 FN-LOCK GENI TIMING DIAGNOSTIC ====='
printf 'kernel=%s\n' "$(uname -r)"
printf 'machine=%s\n' "$(uname -m)"

CONFIG="/boot/config-$(uname -r)"
if [[ -r "$CONFIG" ]]; then
    grep -E '^CONFIG_(I2C_QCOM_GENI|COMMON_CLK_X1E80100|COMMON_CLK_QCOM)=' "$CONFIG" || true
else
    printf 'kernel_config=unavailable\n'
fi

printf '%s\n' '----- controller -----'
DEV=''
for candidate in \
    /sys/bus/platform/devices/a80000.i2c \
    /sys/devices/platform/soc@0/ac0000.geniqup/a80000.i2c; do
    if [[ -e "$candidate" ]]; then
        DEV="$candidate"
        break
    fi
done
if [[ -z "$DEV" ]]; then
    DEV="$(find /sys/devices/platform -maxdepth 8 -type d -name 'a80000.i2c' -print -quit 2>/dev/null || true)"
fi
if [[ -n "$DEV" ]]; then
    printf 'controller_path=%s\n' "$(readlink -f "$DEV")"
    printf 'driver=%s\n' "$(basename "$(readlink -f "$DEV/driver" 2>/dev/null || echo unknown)")"
    if [[ -r "$DEV/power/runtime_status" ]]; then
        printf 'runtime_status=%s\n' "$(cat "$DEV/power/runtime_status")"
    fi
else
    printf 'controller_path=NOT_FOUND\n'
fi

printf '%s\n' '----- module/config -----'
if modinfo i2c_qcom_geni >/dev/null 2>&1; then
    printf 'i2c_qcom_geni_modinfo=present\n'
    modinfo -F filename i2c_qcom_geni 2>/dev/null || true
else
    printf 'i2c_qcom_geni_modinfo=not-a-loadable-module-or-not-installed\n'
fi
lsmod | grep -E '(^|_)(i2c_qcom_geni|qcom_geni)( |$)' || true

printf '%s\n' '----- clock framework -----'
sudo mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
CLK_SUMMARY=/sys/kernel/debug/clk/clk_summary
if [[ -r "$CLK_SUMMARY" ]]; then
    printf '%s\n' '[matching clk_summary lines]'
    grep -Ei 'gcc_qupv3_wrap1_s0(_clk|_clk_src)?|qupv3.*wrap1.*s0' "$CLK_SUMMARY" || true
else
    printf 'clk_summary=unavailable\n'
fi

for name in gcc_qupv3_wrap1_s0_clk gcc_qupv3_wrap1_s0_clk_src; do
    d="/sys/kernel/debug/clk/$name"
    if [[ -d "$d" ]]; then
        printf '[%s]\n' "$name"
        for attr in clk_rate clk_accuracy clk_enable_count clk_prepare_count; do
            if [[ -r "$d/$attr" ]]; then
                printf '%s=%s\n' "$attr" "$(cat "$d/$attr")"
            fi
        done
    fi
done

printf '%s\n' '----- recent controller/HID messages -----'
sudo dmesg --ctime | grep -E 'a80000\.i2c|i2c_hid_of 4-0015|0B05:0220|geni.?i2c' | tail -n 80 || true

printf '%s\n' '----- interpretation -----'
printf '%s\n' 'Linux 7.1.5 chooses the 32-MHz timing table only when the live SE clock rate is exactly 32000000 Hz.'
printf '%s\n' 'Any other rate selects its 19.2-MHz table; on this platform the expected useful discriminator is 19200000 versus 32000000.'
printf '%s\n' 'Windows qci2c8380 400-kHz/19.2-MHz counters: div=2 high=5 low=12 cycle=24 (0x00503018).'
printf '%s\n' 'Linux 7.1.5 400-kHz/19.2-MHz counters:       div=2 high=5 low=11 cycle=22 (0x00502c16).'
printf '%s\n' 'A14_FNLOCK_GENI_TIMING_DIAG=COMPLETE'
