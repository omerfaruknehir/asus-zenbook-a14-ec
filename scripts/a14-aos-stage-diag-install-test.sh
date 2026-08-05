#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Install the diagnostic CAMSS module in an isolated, manually selected boot.
set -Eeuo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
release=${A14_KERNEL_RELEASE:-$(uname -r)}
stage=${A14_AOS_DIAG_STAGE:-"$HOME/Downloads/a14-aos-diag-$release/artifacts"}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this script as your normal user, not with sudo"
[ -s "$stage/qcom-camss.ko" ] || fail "diagnostic CAMSS artifact is missing"
[ -s "$stage/BUILD-INFO.txt" ] || fail "diagnostic BUILD-INFO.txt is missing"
grep -Fqx 'diagnostic_only=true' "$stage/BUILD-INFO.txt" || \
    fail "the selected artifact directory is not diagnostic-only"
grep -Fqx 'ssc_activation_allowed=false' "$stage/BUILD-INFO.txt" || \
    fail "the selected artifact does not prohibit SSC activation"

case " $(cat /proc/cmdline) " in
    *' a14_aos_cpas_test=1 '*)
        fail "return to the normal boot before installing another test entry"
        ;;
esac

grep -wq 'qcom_camss_aon_acquire' /proc/kallsyms && \
    fail "patched CAMSS is already loaded; the current boot must use the stock module"

printf '%s\n' 'A14 AON diagnostic boot installer'
printf '%s\n' '================================='
printf 'kernel_release=%s\n' "$release"
printf 'diagnostic_stage=%s\n' "$stage"
printf 'ssc_activation_allowed=false\n'
printf 'default_boot_must_remain_normal=true\n'

# Reuse the validated installer while correcting its legacy unprivileged
# grub.cfg readback checks. Keep the temporary copy beside the original so its
# repository-path resolution remains unchanged.
tmp_installer=$(mktemp "$repo/scripts/.a14-aos-diag-install.XXXXXX")
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
    fail "the underlying isolated-boot installation failed with status $installer_status"

bash "$repo/scripts/a14-aos-stage-verify-install.sh" |
    sed '/One-shot test boot command:/,+1d'

printf '\n%s\n' '===== DIAGNOSTIC ENTRY READY ====='
printf '%s\n' 'installation=validated'
printf '%s\n' 'do_not_use_grub_reboot=true'
printf '%s\n' 'boot_selection=manual-grub-menu'
printf '%s\n' 'default_boot_unchanged=true'
printf '%s\n' 'persistent_module_override=false'
printf '\nReboot normally and manually select from the GRUB menu:\n'
printf '  ASUS Zenbook A14 AOS CPAS test (%s)\n' "$release"
printf '\nDo not run the SSC --activate test in this diagnostic boot.\n'
