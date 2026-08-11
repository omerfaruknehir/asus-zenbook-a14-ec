#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Run the existing full-F0/no-mux discriminator with the Windows-matched
# INIT576 restart counter. All hardware sequencing remains in the proven runner.
set -Eeuo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
release=${A14_KERNEL_RELEASE:-$(uname -r)}
work=${A14_AOS_F0_ICP_OWNER_WORK:-"$HOME/Downloads/a14-aos-f0-icp-owner-diag-$release"}
stage=${A14_AOS_F0_SSC_WIRE_STAGE:-"$work/ssc-wireexact-artifacts"}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this script as your normal user, not with sudo"
[ -s "$stage/BUILD-INFO.txt" ] || fail "wire-exact stage is missing: $stage"
grep -Fqx 'windows_matched_init576=true' "$stage/BUILD-INFO.txt" || \
    fail "stage is not marked as Windows-matched INIT576"
grep -Fqx 'handshake_restart_count=5' "$stage/BUILD-INFO.txt" || \
    fail "stage does not contain restart-count 5"

printf '%s\n' 'A14 Windows-matched INIT576 full-F0 discriminator'
printf '%s\n' '================================================='
printf '%s\n' 'handshake_sensor_name=ov02c10'
printf '%s\n' 'handshake_restart_count=5'
printf '%s\n' 'handshake_camera_id=2'
printf '%s\n' 'single_protocol_change=restart_count_0_to_5'
printf '%s\n' 'cpas_ownership_mux_access=false'
printf '%s\n' 'direct_cpas_mmio=false'

A14_AOS_F0_SSC_STAGE="$stage" \
A14_AOS_F0_SSC_REPORT="$HOME/Downloads/a14-aos-f0-ssc-wireexact-report.txt" \
A14_AOS_F0_SSC_KLOG="$HOME/Downloads/a14-aos-f0-ssc-wireexact-kernel.log" \
A14_AOS_F0_SSC_MARKER="$HOME/Downloads/a14-aos-f0-ssc-wireexact-last-run.txt" \
    bash "$repo/scripts/a14-aos-f0-ssc-handshake-run.sh"
