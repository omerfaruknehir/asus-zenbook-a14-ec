#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Build a test-only full-F0 + GPIO97/98 cam_mclk + SSC discriminator payload.
# No live pin, SSC, clock or CPAS state is changed here.
set -Eeuo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
release=${A14_KERNEL_RELEASE:-$(uname -r)}
work=${A14_AOS_F0_ICP_OWNER_WORK:-"$HOME/Downloads/a14-aos-f0-icp-owner-diag-$release"}
ssc_stage=${A14_AOS_F0_SSC_STAGE:-"$work/ssc-handshake-artifacts"}
mclk_stage=${A14_AOS_F0_MCLK_STAGE:-"$work/mclk-handshake-artifacts"}
aos_src="$repo/kernel/aos"
overlay_dts="$work/a14-f0-mclk97-98-overlay.dts"
overlay_dtbo="$work/a14-f0-mclk97-98-overlay.dtbo"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for tool in bash cp dtc fdtget find grep modinfo rm sha256sum sort strings uname xargs; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this builder as your normal user, not with sudo"

printf '%s\n' 'A14 full-F0 + MCLK97/98 + SSC discriminator build'
printf '%s\n' '=================================================='
printf 'kernel_release=%s\n' "$release"
printf 'work=%s\n' "$work"
printf 'mclk_stage=%s\n' "$mclk_stage"
printf '%s\n' 'build_only=true'
printf '%s\n' 'live_pin_changes=false'
printf '%s\n' 'direct_tlmm_mmio=false'
printf '%s\n' 'direct_cpas_mmio=false'
printf '%s\n' 'automatic_ssc_activation=false'

printf '\n%s\n' '===== BUILD / RESUME FULL-F0 SSC BASE ====='
bash "$repo/scripts/a14-aos-f0-ssc-handshake-build.sh"
[ -d "$ssc_stage" ] || fail "SSC discriminator stage is missing: $ssc_stage"
[ -s "$ssc_stage/qcom_ssc_hpd.ko" ] || fail "staged HPD module is missing"
[ -s "$aos_src/qcom_a14_f0_mclk_diag.ko" ] || fail "MCLK diagnostic module was not built"
case "$(modinfo -F vermagic "$aos_src/qcom_a14_f0_mclk_diag.ko")" in
    "$release "*) ;;
    *) fail "MCLK diagnostic module vermagic mismatch" ;;
esac
modinfo_text=$(modinfo "$aos_src/qcom_a14_f0_mclk_diag.ko")
grep -Fq 'ASUS Zenbook A14 CAMP F0 MCLK pinctrl diagnostic' <<<"$modinfo_text" || \
    fail "MCLK diagnostic module identity check failed"
grep -aFq 'manual activation only' "$aos_src/qcom_a14_f0_mclk_diag.ko" || \
    fail "MCLK diagnostic module lacks inert-probe marker"
grep -aFq 'idle-gpio-pulldown-2mA' "$aos_src/qcom_a14_f0_mclk_diag.ko" || \
    fail "MCLK diagnostic module lacks explicit restore marker"
printf '%s\n' 'mclk_diagnostic_module=validated'

printf '\n%s\n' '===== BUILD SYMBOLIC GPIO97/98 PINCTRL OVERLAY ====='
cat > "$overlay_dts" <<'DTS'
/dts-v1/;
/plugin/;

/ {
    fragment@0 {
        target = <&tlmm>;

        __overlay__ {
            a14_aos_mclk97_98_active: a14-aos-mclk97-98-active-state {
                pins {
                    pins = "gpio97", "gpio98";
                    function = "cam_mclk";
                    bias-disable;
                    drive-strength = <6>;
                };
            };

            a14_aos_mclk97_98_idle: a14-aos-mclk97-98-idle-state {
                pins {
                    pins = "gpio97", "gpio98";
                    function = "gpio";
                    bias-pull-down;
                    drive-strength = <2>;
                };
            };
        };
    };

    fragment@1 {
        target-path = "/";

        __overlay__ {
            a14_aos_f0_mclk_diag: a14-aos-f0-mclk-diag {
                compatible = "asus,a14-aos-f0-mclk-diag";
                pinctrl-names = "aos-f0-mclk-active", "aos-f0-mclk-idle";
                pinctrl-0 = <&a14_aos_mclk97_98_active>;
                pinctrl-1 = <&a14_aos_mclk97_98_idle>;
                status = "okay";
            };
        };
    };
};
DTS

dtc -@ -I dts -O dtb -o "$overlay_dtbo" "$overlay_dts"
[ -s "$overlay_dtbo" ] || fail "MCLK pinctrl overlay was not produced"
fdtget -t s "$overlay_dtbo" /__fixups__ tlmm >/dev/null || \
    fail "MCLK overlay lacks symbolic tlmm fixup"
[ "$(fdtget -t s "$overlay_dtbo" /fragment@0/__overlay__/a14-aos-mclk97-98-active-state/pins function)" = cam_mclk ] || \
    fail "active overlay function is not cam_mclk"
read -r -a active_pins <<<"$(fdtget -t s "$overlay_dtbo" /fragment@0/__overlay__/a14-aos-mclk97-98-active-state/pins pins)"
[ "${#active_pins[@]}" -eq 2 ] && [ "${active_pins[0]}" = gpio97 ] && [ "${active_pins[1]}" = gpio98 ] || \
    fail "active overlay does not target exactly gpio97/gpio98"
[ "$(fdtget -t u "$overlay_dtbo" /fragment@0/__overlay__/a14-aos-mclk97-98-active-state/pins drive-strength)" = 6 ] || \
    fail "active overlay drive strength is not 6 mA"
[ "$(fdtget -t s "$overlay_dtbo" /fragment@0/__overlay__/a14-aos-mclk97-98-idle-state/pins function)" = gpio ] || \
    fail "idle overlay function is not gpio"
[ "$(fdtget -t u "$overlay_dtbo" /fragment@0/__overlay__/a14-aos-mclk97-98-idle-state/pins drive-strength)" = 2 ] || \
    fail "idle overlay drive strength is not 2 mA"
[ "$(fdtget -t s "$overlay_dtbo" /fragment@1/__overlay__/a14-aos-f0-mclk-diag compatible)" = asus,a14-aos-f0-mclk-diag ] || \
    fail "diagnostic platform-device compatible is missing"
printf '%s\n' 'mclk_overlay=validated-gpio97-98-only'
printf '%s\n' 'active_state=cam_mclk-no-pull-6mA'
printf '%s\n' 'idle_state=gpio-pulldown-2mA'

printf '\n%s\n' '===== ASSEMBLE MCLK TEST-ONLY PAYLOAD ====='
rm -rf "$mclk_stage"
cp -a "$ssc_stage" "$mclk_stage"
cp "$aos_src/qcom_a14_f0_mclk_diag.ko" "$mclk_stage/qcom_a14_f0_mclk_diag.ko"
cp "$overlay_dtbo" "$mclk_stage/a14-f0-mclk97-98-overlay.dtbo"
cat >> "$mclk_stage/BUILD-INFO.txt" <<'EOF_INFO'
mclk97_98_handshake_discriminator=true
mclk97_98_module_staged=true
mclk97_98_overlay_staged=true
mclk97_98_probe_inert=true
mclk97_98_active_state=cam_mclk-no-pull-6mA
mclk97_98_idle_state=gpio-pulldown-2mA
gpio99_untouched=true
direct_tlmm_mmio=false
direct_cpas_mmio=false
automatic_ssc_activation=false
EOF_INFO
(
    cd "$mclk_stage"
    rm -f SHA256SUMS
    find . -maxdepth 1 -type f ! -name SHA256SUMS -print0 |
        sort -z | xargs -0 sha256sum > SHA256SUMS
    sha256sum -c SHA256SUMS
)

printf '\n%s\n' '===== RESULT ====='
printf '%s\n' 'build_result=success'
printf 'mclk_stage=%s\n' "$mclk_stage"
printf '%s\n' 'live_pin_changes=false'
printf '%s\n' 'gpio97_98_only=true'
printf '%s\n' 'gpio99_untouched=true'
printf '%s\n' 'direct_tlmm_mmio=false'
printf '%s\n' 'direct_cpas_mmio=false'
printf '\nInstall/update the isolated one-shot boot with:\n'
printf '  bash %q\n' "$repo/scripts/a14-aos-f0-mclk-handshake-install.sh"
