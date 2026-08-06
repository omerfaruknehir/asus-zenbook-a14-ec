#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Install the non-MMIO platform-power diagnostic in an isolated manual boot.
set -Eeuo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
release=${A14_KERNEL_RELEASE:-$(uname -r)}
stage=${A14_AOS_POWER_DIAG_STAGE:-"$HOME/Downloads/a14-aos-power-diag-$release/artifacts"}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this script as your normal user, not with sudo"
[ -s "$stage/qcom-camss.ko" ] || fail "power-diagnostic CAMSS artifact is missing"
[ -s "$stage/BUILD-INFO.txt" ] || fail "power-diagnostic BUILD-INFO.txt is missing"

grep -Fqx 'diagnostic_only=true' "$stage/BUILD-INFO.txt" || \
    fail "the selected artifact is not diagnostic-only"
grep -Fqx 'diagnostic_generation=platform-power-no-mmio-v1' "$stage/BUILD-INFO.txt" || \
    fail "the selected artifact is not the platform-power diagnostic"
grep -Fqx 'direct_cpas_mmio_allowed=false' "$stage/BUILD-INFO.txt" || \
    fail "the selected artifact does not prohibit direct CPAS MMIO"
grep -Fqx 'ssc_activation_allowed=false' "$stage/BUILD-INFO.txt" || \
    fail "the selected artifact does not prohibit SSC activation"

if strings "$stage/qcom-camss.ko" | grep -Eq \
    'AON-DIAG stage=3|ap-write-no-read|aon-switch-restore-no-read'; then
    fail "the selected CAMSS module contains a retired direct-MMIO diagnostic"
fi
strings "$stage/qcom-camss.ko" | grep -Fq \
    'AON-POWER-DIAG begin direct-mmio=false' || \
    fail "the selected CAMSS module lacks the non-MMIO power probe"

case " $(cat /proc/cmdline) " in
    *' a14_aos_cpas_test=1 '*)
        fail "return to the normal boot before installing another test entry"
        ;;
esac

grep -wq 'qcom_camss_aon_acquire' /proc/kallsyms && \
    fail "patched CAMSS is already loaded; the current boot must use the stock module"

printf '%s\n' 'A14 platform-power diagnostic boot installer'
printf '%s\n' '============================================'
printf 'kernel_release=%s\n' "$release"
printf 'diagnostic_stage=%s\n' "$stage"
printf 'direct_cpas_mmio_allowed=false\n'
printf 'ssc_activation_allowed=false\n'
printf 'default_boot_must_remain_normal=true\n'

tmp_installer=$(mktemp "$repo/scripts/.a14-aos-power-install.XXXXXX")
cleanup() {
    rm -f "$tmp_installer"
}
trap cleanup EXIT INT TERM

sed \
    -e 's/^grep -Fq "menuentry /sudo grep -Fq "menuentry /' \
    -e 's/^grep -Fq "devicetree /sudo grep -Fq "devicetree /' \
    -e 's/^grep -Fq "initrd /sudo grep -Fq "initrd /' \
    "$repo/scripts/a14-aos-stage-install-test.sh" > "$tmp_installer"
chmod 0755 "$tmp_installer"

set +e
set -o pipefail
A14_AOS_STAGE="$stage" bash "$tmp_installer" 2>&1 |
    sed '/One-shot test boot command:/,+3d'
installer_status=${PIPESTATUS[0]}
set +o pipefail
set -e
[ "$installer_status" -eq 0 ] || \
    fail "the isolated-boot installation failed with status $installer_status"

bash "$repo/scripts/a14-aos-stage-verify-install.sh" |
    sed '/One-shot test boot command:/,+1d'

printf '\n%s\n' '===== POWER-DIAGNOSTIC ENTRY READY ====='
printf '%s\n' 'installation=validated'
printf '%s\n' 'boot_selection=manual-grub-menu'
printf '%s\n' 'default_boot_unchanged=true'
printf '%s\n' 'persistent_module_override=false'
printf '\nReboot normally and manually select from the GRUB menu:\n'
printf '  ASUS Zenbook A14 AOS CPAS test (%s)\n' "$release"
printf '\nDo not load qcom_ssc_hpd or run an AOS activation command in this boot.\n'
