#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Run the full-F0/no-CPAS SSC discriminator with only GPIO97/98 additionally
# selected as cam_mclk/no-pull/6mA through Linux pinctrl.
set -Eeuo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
release=${A14_KERNEL_RELEASE:-$(uname -r)}
work=${A14_AOS_F0_ICP_OWNER_WORK:-"$HOME/Downloads/a14-aos-f0-icp-owner-diag-$release"}
stage=${A14_AOS_F0_MCLK_STAGE:-"$work/mclk-handshake-artifacts"}
report=${A14_AOS_F0_MCLK_REPORT:-"$HOME/Downloads/a14-aos-f0-mclk-handshake-report.txt"}
klog=${A14_AOS_F0_MCLK_KLOG:-"$HOME/Downloads/a14-aos-f0-mclk-handshake-kernel.log"}
marker=${A14_AOS_F0_MCLK_MARKER:-"$HOME/Downloads/a14-aos-f0-mclk-handshake-last-run.txt"}
attr=
diag_loaded=false
active_selected=false
tmp_camera=

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
find_tlmm_debug() {
    local file
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        if sudo grep -Eq '^pin 97 \(GPIO_97\):|^pin 98 \(GPIO_98\):' "$file" 2>/dev/null; then
            dirname "$file"
            return 0
        fi
    done < <(sudo find /sys/kernel/debug/pinctrl \
        -mindepth 2 -maxdepth 2 -type f -name pinmux-pins -print 2>/dev/null || true)
    return 1
}
show_pins() {
    local ctrl=$1
    printf '%s\n' '--- pinmux 97/98 ---'
    sudo grep -E '^pin (97|98) \(GPIO_(97|98)\):' "$ctrl/pinmux-pins" 2>/dev/null || true
    if [ -r "$ctrl/pinconf-groups" ] || sudo test -r "$ctrl/pinconf-groups" 2>/dev/null; then
        printf '%s\n' '--- pinconf 97/98 ---'
        sudo grep -E '^(97 \(gpio97\)|98 \(gpio98\)):' "$ctrl/pinconf-groups" 2>/dev/null || true
    fi
}
cleanup() {
    local rc=$?
    set +e
    if [ -n "$attr" ] && [ "$active_selected" = true ]; then
        sudo sh -c 'printf "0\n" > "$1"' sh "$attr" 2>/dev/null || true
        active_selected=false
    fi
    if [ "$diag_loaded" = true ]; then
        sudo rmmod qcom_a14_f0_mclk_diag 2>/dev/null || true
        diag_loaded=false
    fi
    [ -z "$tmp_camera" ] || rm -f "$tmp_camera"
    exit "$rc"
}
trap cleanup EXIT INT TERM

for tool in bash cam cat dirname find fuser grep insmod lsmod mktemp rmmod seq \
            sleep sudo timeout uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this runner as your normal user, not with sudo"
case " $(cat /proc/cmdline) " in
    *' a14_aos_f0_icp_owner_test=1 '*) ;;
    *) fail "this is not the isolated full-F0 owner test boot" ;;
esac
[ -s "$stage/qcom_a14_f0_mclk_diag.ko" ] || fail "MCLK diagnostic module is missing: $stage/qcom_a14_f0_mclk_diag.ko"
[ -s "$stage/qcom_ssc_hpd.ko" ] || fail "HPD diagnostic module is missing: $stage/qcom_ssc_hpd.ko"
if grep -Eq '^qcom_a14_f0_mclk_diag[[:space:]]' /proc/modules; then
    fail "MCLK diagnostic module is already loaded; start from a clean test boot"
fi
if grep -Eq '^qcom_ssc_hpd[[:space:]]' /proc/modules; then
    fail "HPD module is already loaded; clean it up before this test"
fi
if ! grep -qsE '[[:space:]]/sys/kernel/debug[[:space:]]+debugfs[[:space:]]' /proc/mounts; then
    fail "debugfs is not mounted; refusing to run without read-back verification"
fi

printf '%s\n' 'A14 full-F0 + GPIO97/98 MCLK + SSC discriminator'
printf '%s\n' '====================================================='
printf 'kernel_release=%s\n' "$release"
printf 'stage=%s\n' "$stage"
printf '%s\n' 'gpio97_98_active=cam_mclk-no-pull-6mA'
printf '%s\n' 'gpio97_98_restore=gpio-pulldown-2mA'
printf '%s\n' 'gpio99_untouched=true'
printf '%s\n' 'direct_tlmm_mmio=false'
printf '%s\n' 'direct_cpas_mmio=false'

sudo -v
ctrl=$(find_tlmm_debug) || fail "X1E TLMM pinctrl debugfs controller was not found"
printf 'tlmm_debug=%s\n' "$ctrl"

printf '\n%s\n' '===== VERIFY OBSERVED BASELINE ====='
baseline_mux=$(sudo grep -E '^pin (97|98) \(GPIO_(97|98)\):' "$ctrl/pinmux-pins" 2>/dev/null || true)
printf '%s\n' "$baseline_mux"
[ "$(grep -c 'UNCLAIMED' <<<"$baseline_mux")" -eq 2 ] || \
    fail "GPIO97/98 are not both unclaimed at baseline"
baseline_conf=$(sudo grep -E '^(97 \(gpio97\)|98 \(gpio98\)):' "$ctrl/pinconf-groups" 2>/dev/null || true)
printf '%s\n' "$baseline_conf"
[ "$(grep -c 'input bias pull down' <<<"$baseline_conf")" -eq 2 ] || \
    fail "GPIO97/98 baseline is not pull-down"
[ "$(grep -c 'drive strength (2 mA)' <<<"$baseline_conf")" -eq 2 ] || \
    fail "GPIO97/98 baseline is not 2 mA"

users=$(sudo fuser /dev/video* /dev/media* /dev/v4l-subdev* 2>/dev/null || true)
if [ -n "$users" ]; then
    sudo fuser -v /dev/video* /dev/media* /dev/v4l-subdev* 2>&1 || true
    fail "camera/media nodes are busy before MCLK activation"
fi

tmp_camera=$(mktemp)
sudo timeout 25 cam -l >"$tmp_camera" 2>&1 || { cat "$tmp_camera"; fail "pre-MCLK camera enumeration failed"; }
cat "$tmp_camera"
grep -Eq '^[[:space:]]*1: .*camera|^[[:space:]]*1:' "$tmp_camera" || fail "pre-MCLK camera 1 is missing"
grep -Eq '^[[:space:]]*2: .*camera|^[[:space:]]*2:' "$tmp_camera" || fail "pre-MCLK camera 2 is missing"
rm -f "$tmp_camera"; tmp_camera=

printf '\n%s\n' '===== LOAD INERT MCLK DIAGNOSTIC ====='
sudo insmod "$stage/qcom_a14_f0_mclk_diag.ko"
diag_loaded=true
for _ in $(seq 1 40); do
    attr=$(find /sys/bus/platform/drivers/qcom-a14-f0-mclk-diag \
        -maxdepth 2 -type f -name a14_f0_mclk_active -print -quit 2>/dev/null || true)
    [ -n "$attr" ] && break
    sleep 0.05
done
[ -n "$attr" ] || fail "MCLK diagnostic sysfs attribute did not appear"
printf 'mclk_control=%s\n' "$attr"
[ "$(cat "$attr")" = 0 ] || fail "MCLK diagnostic was unexpectedly active after probe"
printf '%s\n' 'probe_inert=validated'

printf '\n%s\n' '===== SELECT WINDOWS-F0 MCLK STATE FOR GPIO97/98 ====='
sudo sh -c 'printf "1\n" > "$1"' sh "$attr"
active_selected=true
[ "$(cat "$attr")" = 1 ] || fail "MCLK diagnostic did not report active state"
sleep 0.05
show_pins "$ctrl"
active_mux=$(sudo grep -E '^pin (97|98) \(GPIO_(97|98)\):' "$ctrl/pinmux-pins" 2>/dev/null || true)
[ "$(grep -c 'function cam_mclk' <<<"$active_mux")" -eq 2 ] || \
    fail "GPIO97/98 did not both switch to cam_mclk"
active_conf=$(sudo grep -E '^(97 \(gpio97\)|98 \(gpio98\)):' "$ctrl/pinconf-groups" 2>/dev/null || true)
[ "$(grep -c 'input bias disabled' <<<"$active_conf")" -eq 2 ] || \
    fail "GPIO97/98 did not both switch to no-pull"
[ "$(grep -c 'drive strength (6 mA)' <<<"$active_conf")" -eq 2 ] || \
    fail "GPIO97/98 did not both switch to 6 mA"
printf '%s\n' 'mclk97_98_active_state=validated'
printf '%s\n' 'gpio99_untouched=true'

printf '\n%s\n' '===== RUN EXISTING FULL-F0 / NO-CPAS SSC DISCRIMINATOR ====='
set +e
A14_AOS_F0_SSC_STAGE="$stage" \
A14_AOS_F0_SSC_REPORT="$report" \
A14_AOS_F0_SSC_KLOG="$klog" \
A14_AOS_F0_SSC_MARKER="$marker" \
    bash "$repo/scripts/a14-aos-f0-ssc-handshake-run.sh"
handshake_rc=$?
set -e
printf 'handshake_runner_status=%s\n' "$handshake_rc"

printf '\n%s\n' '===== RESTORE GPIO97/98 BEFORE MODULE REMOVE ====='
sudo sh -c 'printf "0\n" > "$1"' sh "$attr"
active_selected=false
[ "$(cat "$attr")" = 0 ] || fail "MCLK diagnostic did not report idle state"
sleep 0.05
show_pins "$ctrl"
idle_mux=$(sudo grep -E '^pin (97|98) \(GPIO_(97|98)\):' "$ctrl/pinmux-pins" 2>/dev/null || true)
[ "$(grep -c 'function gpio' <<<"$idle_mux")" -eq 2 ] || \
    fail "GPIO97/98 did not both switch back to GPIO mode before unload"
idle_conf=$(sudo grep -E '^(97 \(gpio97\)|98 \(gpio98\)):' "$ctrl/pinconf-groups" 2>/dev/null || true)
[ "$(grep -c 'input bias pull down' <<<"$idle_conf")" -eq 2 ] || \
    fail "GPIO97/98 idle state is not pull-down"
[ "$(grep -c 'drive strength (2 mA)' <<<"$idle_conf")" -eq 2 ] || \
    fail "GPIO97/98 idle state is not 2 mA"

sudo rmmod qcom_a14_f0_mclk_diag
diag_loaded=false
attr=
sleep 0.05
released_mux=$(sudo grep -E '^pin (97|98) \(GPIO_(97|98)\):' "$ctrl/pinmux-pins" 2>/dev/null || true)
printf '%s\n' "$released_mux"
[ "$(grep -c 'UNCLAIMED' <<<"$released_mux")" -eq 2 ] || \
    fail "GPIO97/98 were not released after diagnostic unload"
printf '%s\n' 'mclk97_98_restore=validated'

printf '\n%s\n' '===== FINAL CAMERA ENUMERATION ====='
tmp_camera=$(mktemp)
sudo timeout 25 cam -l >"$tmp_camera" 2>&1 || { cat "$tmp_camera"; fail "post-MCLK camera enumeration failed"; }
cat "$tmp_camera"
grep -Eq '^[[:space:]]*1:' "$tmp_camera" || fail "post-MCLK camera 1 is missing"
grep -Eq '^[[:space:]]*2:' "$tmp_camera" || fail "post-MCLK camera 2 is missing"
rm -f "$tmp_camera"; tmp_camera=
printf '%s\n' 'camera_restore=validated'

result=unknown
if [ -r "$report" ]; then
    if grep -Fq 'discriminator_result=handshake-ack-with-full-f0-no-mux' "$report"; then
        result=handshake-ack-with-mclk97-98
    elif grep -Fq 'discriminator_result=handshake-timeout-full-f0-no-mux' "$report"; then
        result=handshake-timeout-with-mclk97-98
    elif grep -Fq 'discriminator_result=handshake-rejected-full-f0-no-mux' "$report"; then
        result=handshake-rejected-with-mclk97-98
    elif [ "$handshake_rc" -ne 0 ]; then
        result=runner-error
    fi
fi

printf '\n%s\n' '===== RESULT ====='
printf 'result=%s\n' "$result"
printf 'handshake_runner_status=%s\n' "$handshake_rc"
printf 'report=%s\n' "$report"
printf 'kernel_log=%s\n' "$klog"
printf 'marker=%s\n' "$marker"
printf '%s\n' 'gpio97_98_restored=true'
printf '%s\n' 'gpio99_untouched=true'
printf '%s\n' 'direct_tlmm_mmio=false'
printf '%s\n' 'direct_cpas_mmio=false'

# Preserve the nested runner's failure status after all reversible cleanup and
# validation has completed.
exit "$handshake_rc"
