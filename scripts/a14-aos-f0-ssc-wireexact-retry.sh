#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Retry only the harmless pre-handshake discovery portion of the Windows-matched
# INIT576 discriminator. Never retries once the full-F0 hold or INIT attempt has
# started in this boot.
set -Eeuo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
release=${A14_KERNEL_RELEASE:-$(uname -r)}
work=${A14_AOS_F0_ICP_OWNER_WORK:-"$HOME/Downloads/a14-aos-f0-icp-owner-diag-$release"}
report="$HOME/Downloads/a14-aos-f0-ssc-wireexact-report.txt"
marker="$HOME/Downloads/a14-aos-f0-ssc-wireexact-last-run.txt"
max_attempts=${A14_AOS_WIRE_DISCOVERY_ATTEMPTS:-3}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for tool in bash cat grep journalctl lsmod rm seq sleep sudo uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run this script as your normal user, not with sudo"
case " $(cat /proc/cmdline) " in
    *' a14_aos_f0_icp_owner_test=1 '*) ;;
    *) fail "this is not the isolated full-F0 owner test boot" ;;
esac
case "$max_attempts" in
    *[!0-9]*|'') fail "attempt count must be an integer" ;;
esac
[ "$max_attempts" -ge 1 ] && [ "$max_attempts" -le 5 ] || fail "attempt count must be 1..5"

boot_id=$(cat /proc/sys/kernel/random/boot_id)

print_ssc_log() {
    printf '\n%s\n' '===== CURRENT SSC/QMI DIAGNOSTICS ====='
    sudo journalctl -k -b -n 220 --no-pager -o short-monotonic | \
        grep -E 'qcom-ssc-hpd|qcom_ssc_hpd|SSC datatype|SSC QMI|discovery failed|failed to connect SSC|waiting for SSC|service disappeared' || true
}

safe_clear_prehandshake_marker() {
    [ -s "$marker" ] || return 0
    grep -Fqx "boot_id=$boot_id" "$marker" || return 0

    # A completed/returned discriminator or any report that reached the F0 hold
    # is not retryable in the same boot. This helper is only for the failure
    # observed before SUID discovery completed.
    if grep -Eq '^status=returned$|^handshake_attempted=true$' "$marker"; then
        fail "the wire-exact discriminator already reached/returned from its handshake phase in this boot"
    fi
    if [ -s "$report" ] && \
       grep -Eq '^===== ESTABLISH FULL-F0 OWNER HOLD =====$|^===== ATTEMPT REAL SSC CAMERA HANDSHAKE =====$' "$report"; then
        fail "the previous run reached the full-F0/handshake phase; refusing an in-boot retry"
    fi

    printf '%s\n' 'previous_marker=pre-handshake-only'
    rm -f "$marker"
}

printf '%s\n' 'A14 Windows-matched INIT576 discovery retry'
printf '%s\n' '============================================='
printf 'boot_id=%s\n' "$boot_id"
printf 'max_attempts=%s\n' "$max_attempts"
printf '%s\n' 'restart_count=5'
printf '%s\n' 'cpas_ownership_mux_access=false'
printf '%s\n' 'direct_cpas_mmio=false'
printf '%s\n' 'retry_scope=pre-handshake-discovery-only'

safe_clear_prehandshake_marker
print_ssc_log

for attempt in $(seq 1 "$max_attempts"); do
    if grep -Eq '^qcom_ssc_hpd[[:space:]]' /proc/modules; then
        fail "qcom_ssc_hpd remained loaded before retry attempt $attempt"
    fi

    printf '\n===== WIRE-EXACT ATTEMPT %s/%s =====\n' "$attempt" "$max_attempts"
    rm -f "$report"

    set +e
    bash "$repo/scripts/a14-aos-f0-ssc-wireexact-run.sh"
    rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
        printf 'retry_result=runner-returned-success\n'
        exit 0
    fi

    # Never automatically retry after the real discriminator boundary.
    if [ -s "$report" ] && \
       grep -Eq '^===== ESTABLISH FULL-F0 OWNER HOLD =====$|^===== ATTEMPT REAL SSC CAMERA HANDSHAKE =====$' "$report"; then
        print_ssc_log
        fail "runner reached the full-F0/handshake phase and returned status $rc; no automatic retry"
    fi

    if [ -s "$report" ] && \
       grep -Eq 'SUID was not discovered|HPD IIO device did not appear' "$report"; then
        printf 'attempt_%s_result=pre-handshake-discovery-failed\n' "$attempt"
        print_ssc_log
        safe_clear_prehandshake_marker
        if [ "$attempt" -lt "$max_attempts" ]; then
            printf '%s\n' 'retrying_after_seconds=1'
            sleep 1
            continue
        fi
        fail "SSC discovery did not stabilize after $max_attempts pre-handshake attempts"
    fi

    print_ssc_log
    fail "wire-exact runner failed before handshake with unexpected status $rc"
done

fail "unreachable retry state"
