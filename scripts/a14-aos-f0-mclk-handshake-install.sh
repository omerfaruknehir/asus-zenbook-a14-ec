#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Install/update the existing one-shot Stage-C boot with an additional
# GPIO97/98 pinctrl diagnostic overlay.  The normal/default boot is untouched.
set -Eeuo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
release=${A14_KERNEL_RELEASE:-$(uname -r)}
work=${A14_AOS_F0_ICP_OWNER_WORK:-"$HOME/Downloads/a14-aos-f0-icp-owner-diag-$release"}
stage=${A14_AOS_F0_MCLK_STAGE:-"$work/mclk-handshake-artifacts"}
install_work=${A14_AOS_F0_MCLK_INSTALL_WORK:-"$HOME/Downloads/a14-aos-f0-mclk-test-boot-$release"}
base_dtb=${A14_AOS_BASE_DTB:-"/boot/dtb-$release-hm1092-v6-ir-cci"}
test_dtb="/boot/dtb-$release-f0-icp-owner-hm1092-test"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for tool in bash fdtoverlay fdtget grep install mkdir readlink sha256sum sudo uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this installer as your normal user, not with sudo"
[ -r "$base_dtb" ] || fail "base DTB is missing: $base_dtb"
[ -s "$stage/a14-f0-icp-owner-overlay.dtbo" ] || fail "Stage-C overlay is missing"
[ -s "$stage/a14-f0-mclk97-98-overlay.dtbo" ] || fail "MCLK97/98 overlay is missing"
[ -s "$stage/qcom_a14_f0_mclk_diag.ko" ] || fail "MCLK diagnostic module is missing"
[ -s "$stage/SHA256SUMS" ] || fail "staged checksums are missing"

printf '%s\n' 'A14 full-F0 + MCLK97/98 one-shot installer'
printf '%s\n' '==============================================='
printf 'kernel_release=%s\n' "$release"
printf 'stage=%s\n' "$stage"
printf 'base_dtb=%s\n' "$base_dtb"
printf '%s\n' 'default_boot_unchanged=true'
printf '%s\n' 'persistent_pin_override=false'
printf '%s\n' 'automatic_pin_activation=false'
printf '%s\n' 'automatic_ssc_activation=false'
printf '%s\n' 'direct_tlmm_mmio=false'
printf '%s\n' 'direct_cpas_mmio=false'

printf '\n%s\n' '===== VERIFY MCLK PAYLOAD ====='
(
    cd "$stage"
    sha256sum -c SHA256SUMS
)
grep -Fqx 'mclk97_98_handshake_discriminator=true' "$stage/BUILD-INFO.txt" || \
    fail "payload is not the MCLK97/98 discriminator"
grep -Fqx 'mclk97_98_probe_inert=true' "$stage/BUILD-INFO.txt" || \
    fail "payload does not guarantee inert probe"
grep -Fqx 'gpio99_untouched=true' "$stage/BUILD-INFO.txt" || \
    fail "payload does not explicitly leave GPIO99 untouched"
grep -Fqx 'direct_tlmm_mmio=false' "$stage/BUILD-INFO.txt" || \
    fail "payload allows direct TLMM MMIO"
grep -Fqx 'direct_cpas_mmio=false' "$stage/BUILD-INFO.txt" || \
    fail "payload allows direct CPAS MMIO"
printf '%s\n' 'mclk_payload=validated'

printf '\n%s\n' '===== INSTALL EXISTING ISOLATED OWNER BOOT ====='
A14_AOS_F0_ICP_OWNER_STAGE="$stage" \
    bash "$repo/scripts/a14-aos-f0-icp-owner-diag-install-test.sh"

printf '\n%s\n' '===== MERGE MCLK97/98 OVERLAY INTO TEST DTB ====='
mkdir -p "$install_work"
tlmm_path=$(fdtget -t s "$base_dtb" /__symbols__ tlmm 2>/dev/null || true)
[ -n "$tlmm_path" ] || fail "base DTB lacks __symbols__/tlmm; symbolic MCLK merge is unsafe"
printf 'tlmm_symbol=%s\n' "$tlmm_path"

merged="$install_work/dtb-$release-f0-icp-owner-plus-mclk97-98-test"
fdtoverlay -i "$base_dtb" -o "$merged" \
    "$stage/a14-f0-icp-owner-overlay.dtbo" \
    "$stage/a14-f0-mclk97-98-overlay.dtbo"
[ -s "$merged" ] || fail "combined test DTB was not produced"

camss_node=/soc@0/isp@acb7000
read -r -a clock_names <<<"$(fdtget -t s "$merged" "$camss_node" clock-names)"
[ "${#clock_names[@]}" -eq 31 ] || fail "combined DTB has ${#clock_names[@]} CAMSS clocks, expected 31"
[ "${clock_names[29]}" = icp_ahb ] || fail "combined DTB clock 29 is not icp_ahb"
[ "${clock_names[30]}" = icp ] || fail "combined DTB clock 30 is not icp"

[ "$(fdtget -t s "$merged" /a14-aos-f0-mclk-diag compatible)" = asus,a14-aos-f0-mclk-diag ] || \
    fail "combined DTB lacks MCLK diagnostic platform device"
read -r -a names <<<"$(fdtget -t s "$merged" /a14-aos-f0-mclk-diag pinctrl-names)"
[ "${#names[@]}" -eq 2 ] && \
[ "${names[0]}" = aos-f0-mclk-active ] && \
[ "${names[1]}" = aos-f0-mclk-idle ] || \
    fail "diagnostic pinctrl state names are invalid"

active="$tlmm_path/a14-aos-mclk97-98-active-state/pins"
idle="$tlmm_path/a14-aos-mclk97-98-idle-state/pins"
read -r -a active_pins <<<"$(fdtget -t s "$merged" "$active" pins)"
read -r -a idle_pins <<<"$(fdtget -t s "$merged" "$idle" pins)"
[ "${#active_pins[@]}" -eq 2 ] && [ "${active_pins[0]}" = gpio97 ] && [ "${active_pins[1]}" = gpio98 ] || \
    fail "active merged state does not target exactly GPIO97/98"
[ "${#idle_pins[@]}" -eq 2 ] && [ "${idle_pins[0]}" = gpio97 ] && [ "${idle_pins[1]}" = gpio98 ] || \
    fail "idle merged state does not target exactly GPIO97/98"
[ "$(fdtget -t s "$merged" "$active" function)" = cam_mclk ] || fail "active merged function is not cam_mclk"
[ "$(fdtget -t u "$merged" "$active" drive-strength)" = 6 ] || fail "active merged drive is not 6 mA"
fdtget "$merged" "$active" bias-disable >/dev/null || fail "active merged state lacks bias-disable"
[ "$(fdtget -t s "$merged" "$idle" function)" = gpio ] || fail "idle merged function is not gpio"
[ "$(fdtget -t u "$merged" "$idle" drive-strength)" = 2 ] || fail "idle merged drive is not 2 mA"
fdtget "$merged" "$idle" bias-pull-down >/dev/null || fail "idle merged state lacks bias-pull-down"

if fdtget -t s "$merged" "$active" pins | grep -Fq gpio99 || \
   fdtget -t s "$merged" "$idle" pins | grep -Fq gpio99; then
    fail "combined test unexpectedly references GPIO99"
fi
printf '%s\n' 'combined_dtb=validated-full-f0-plus-mclk97-98'
printf '%s\n' 'gpio99_untouched=true'

printf '\n%s\n' '===== REPLACE ONLY THE ONE-SHOT TEST DTB ====='
merged_sha=$(sha256sum "$merged" | sed 's/[[:space:]].*$//')
sudo install -m 0644 "$merged" "$test_dtb"
installed_sha=$(sudo sha256sum "$test_dtb" | sed 's/[[:space:]].*$//')
[ "$merged_sha" = "$installed_sha" ] || fail "installed one-shot DTB differs from validated combined DTB"
printf '%s\n' 'test_dtb=validated-exact-hash'
printf '%s\n' 'normal_boot_dtb_unchanged=true'

printf '\n%s\n' '===== RESULT ====='
printf '%s\n' 'install_result=success'
printf 'test_dtb=%s\n' "$test_dtb"
printf '%s\n' 'automatic_pin_activation=false'
printf '%s\n' 'automatic_ssc_activation=false'
printf '%s\n' 'direct_tlmm_mmio=false'
printf '%s\n' 'direct_cpas_mmio=false'
printf '\nBoot the one-shot entry with:\n'
printf '%s\n' '  sudo grub-reboot a14-f0-icp-owner-test && sudo reboot'
printf '\nAfter boot, run the dedicated MCLK handshake runner; do not run the generic handshake runner directly.\n'
