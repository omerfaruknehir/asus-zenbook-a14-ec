#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Install the already-built Windows-matched INIT576 payload into the existing
# isolated Stage-C boot entry. This wrapper does not activate SSC or MMIO.
set -Eeuo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
release=${A14_KERNEL_RELEASE:-$(uname -r)}
work=${A14_AOS_F0_ICP_OWNER_WORK:-"$HOME/Downloads/a14-aos-f0-icp-owner-diag-$release"}
stage=${A14_AOS_F0_SSC_WIRE_STAGE:-"$work/ssc-wireexact-artifacts"}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this installer as your normal user, not with sudo"
[ -s "$stage/BUILD-INFO.txt" ] || fail "wire-exact BUILD-INFO is missing: $stage"
grep -Fqx 'windows_matched_init576=true' "$stage/BUILD-INFO.txt" || \
    fail "stage is not the Windows-matched INIT576 build"
grep -Fqx 'handshake_restart_count=5' "$stage/BUILD-INFO.txt" || \
    fail "stage does not contain restart-count 5"
[ -s "$stage/qcom_ssc_hpd.ko" ] || fail "wire-exact HPD module is missing"

printf '%s\n' 'A14 Windows-matched INIT576 one-shot installer'
printf '%s\n' '==============================================='
printf 'stage=%s\n' "$stage"
printf '%s\n' 'handshake_restart_count=5'
printf '%s\n' 'cpas_ownership_mux_access=false'
printf '%s\n' 'ssc_activation_during_install=false'

A14_AOS_F0_ICP_OWNER_STAGE="$stage" \
    bash "$repo/scripts/a14-aos-f0-icp-owner-diag-install-test.sh"

printf '\n%s\n' 'wire_exact_install_result=success'
printf '%s\n' 'Use the existing one-shot GRUB entry: a14-f0-icp-owner-test'
printf '%s\n' 'After booting it, run: bash ./scripts/a14-aos-f0-ssc-wireexact-run.sh'
