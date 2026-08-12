#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Reversible A/B test for the malformed A14 SSC secure sensor database.
#
# The active database is replaced atomically with the known-good Stage 15 copy,
# then only the reverse-filesystem service is started. Any ADSP crash, service
# exit, non-running ADSP, or malformed post-test database triggers an automatic
# rollback to the exact pre-test files and leaves the service inactive.
set -Eeuo pipefail
umask 077

unit=a14-ssc-hexagonrpcd.service
runtime=/var/lib/a14-ssc/runtime
current=$runtime/sensors/registry/sns_secure_database.bin
reference=/var/lib/a14-ssc/backups/stage15-20260801-213632/var__lib__a14-ssc__runtime/sensors/registry/sns_secure_database.bin
fstemp=$runtime/sensors/fstempfile
parsed_list=$runtime/sensors/parsed_file_list.csv
backup_root=/var/lib/a14-ssc/backups
report=${A14_SNS_DB_AB_REPORT:-"$HOME/Downloads/a14-sns-secure-db-ab-test.txt"}
observe_seconds=${A14_SNS_DB_AB_SECONDS:-15}

expected_current_hash=70d31a82ae7f7eae9f2daa97dcde3cd97b9db16183a313c01be870b02dfa3218
expected_current_size=34816
expected_reference_hash=9046e639c13f8c78a9e68d577b8e19bc8e8ff5781a309e334362dd84b3383311
expected_reference_size=46430
expected_fstemp_hash=a036e1d2120c6ba2b3c3089a63cc03b8e303c5e74e1f533cc8e1d061d27bb4e7
expected_fstemp_size=485
expected_parsed_hash=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
expected_parsed_size=0

backup_dir=
mutation_started=false
test_complete=false
rollback_running=false

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for tool in awk cat cp date dirname grep id install journalctl mktemp mv python3 rm \
        sha256sum sleep stat sudo sync systemctl tail tee; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run as your normal user, not with sudo"
case "$observe_seconds" in
    *[!0-9]*|'') fail "A14_SNS_DB_AB_SECONDS must be an integer" ;;
esac
[ "$observe_seconds" -ge 8 ] && [ "$observe_seconds" -le 60 ] || \
    fail "observation must be 8..60 seconds"
case " $(cat /proc/cmdline) " in
    *' a14_aos_f0_icp_owner_test=1 '*)
        fail "run this A/B only from the normal boot, not the AOS one-shot boot"
        ;;
    *) ;;
esac

hash_file() {
    sudo sha256sum "$1" | awk '{print $1}'
}

size_file() {
    sudo stat -c %s "$1"
}

crash_count() {
    sudo journalctl -k -b --no-pager -o cat 2>/dev/null | \
        grep -Ec 'remoteproc remoteproc0: handling crash #[0-9]+' || true
}

adsp_state() {
    cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null || printf unavailable
}

state_line() {
    local rp=/sys/class/remoteproc/remoteproc0
    printf 'adsp_state=%s adsp_firmware=%s\n' \
        "$(adsp_state)" \
        "$(cat "$rp/firmware" 2>/dev/null || printf unavailable)"
}

db_structure() {
    sudo python3 - "$1" <<'PY'
import sys

with open(sys.argv[1], "rb") as stream:
    blob = stream.read()

records = 0
offset = 0
while offset < len(blob):
    start = offset
    if len(blob) - offset < 32:
        print(f"partial-record-stream:records={records}:offset={start}:bytes={len(blob)-start}")
        break
    offset += 32
    path_end = blob.find(b"\0", offset)
    if path_end < 0:
        print(f"partial-record-stream:records={records}:offset={start}:bytes={len(blob)-start}")
        break
    try:
        blob[offset:path_end].decode("ascii")
    except UnicodeDecodeError:
        print(f"invalid-record-stream:records={records}:offset={start}")
        break
    records += 1
    offset = path_end + 1
else:
    print(f"complete-record-stream:records={records}:size={len(blob)}")
PY
}

describe_file() {
    local label=$1 path=$2
    printf '%s\n' "--- $label ---"
    sudo stat -c 'path=%n size=%s blocks=%b mtime=%y ctime=%z birth=%w mode=%a owner=%U:%G' "$path"
    sudo sha256sum "$path"
}

require_exact_file() {
    local label=$1 path=$2 expected_hash=$3 expected_size=$4
    local actual_hash actual_size
    sudo test -f "$path" || fail "$label is missing or not a regular file: $path"
    sudo test ! -L "$path" || fail "$label must not be a symbolic link: $path"
    actual_size=$(size_file "$path")
    actual_hash=$(hash_file "$path")
    [ "$actual_size" = "$expected_size" ] || \
        fail "$label size changed: expected $expected_size, found $actual_size"
    [ "$actual_hash" = "$expected_hash" ] || \
        fail "$label hash changed: expected $expected_hash, found $actual_hash"
}

atomic_replace_from() {
    local source=$1 destination=$2 expected_hash=$3
    local destination_dir base temporary actual_hash
    destination_dir=$(dirname "$destination")
    base=${destination##*/}
    temporary=$(sudo mktemp --tmpdir="$destination_dir" ".${base}.a14-ab.XXXXXX") || return 1
    if ! sudo cp --archive --reflink=auto -- "$source" "$temporary"; then
        sudo rm -f -- "$temporary"
        return 1
    fi
    actual_hash=$(hash_file "$temporary")
    if [ "$actual_hash" != "$expected_hash" ]; then
        printf 'temporary_hash_mismatch=%s expected=%s actual=%s\n' \
            "$temporary" "$expected_hash" "$actual_hash" >&2
        sudo rm -f -- "$temporary"
        return 1
    fi
    sudo sync "$temporary" || {
        sudo rm -f -- "$temporary"
        return 1
    }
    sudo mv -fT -- "$temporary" "$destination" || {
        sudo rm -f -- "$temporary"
        return 1
    }
    sudo sync "$destination_dir"
}

wait_for_adsp_recovery() {
    local waited=0
    while [ "$(adsp_state)" != running ] && [ "$waited" -lt 20 ]; do
        sleep 1
        waited=$((waited + 1))
    done
    printf 'adsp_recovery_wait_seconds=%s\n' "$waited"
    state_line
}

rollback_baseline() {
    local rollback_ok=true
    [ "$rollback_running" = false ] || return 1
    rollback_running=true

    printf '\n%s\n' '===== AUTOMATIC ROLLBACK ====='
    printf 'rollback_start=%s\n' "$(date --iso-8601=ns)"
    if ! sudo systemctl stop "$unit"; then
        printf '%s\n' 'rollback_service_stop=false'
        rollback_ok=false
    else
        printf '%s\n' 'rollback_service_stop=true'
    fi

    if ! atomic_replace_from \
            "$backup_dir/sns_secure_database.bin.baseline" \
            "$current" "$expected_current_hash"; then
        printf '%s\n' 'rollback_database_restore=false'
        rollback_ok=false
    else
        printf '%s\n' 'rollback_database_restore=true'
    fi
    if ! atomic_replace_from \
            "$backup_dir/fstempfile.baseline" \
            "$fstemp" "$expected_fstemp_hash"; then
        printf '%s\n' 'rollback_fstemp_restore=false'
        rollback_ok=false
    else
        printf '%s\n' 'rollback_fstemp_restore=true'
    fi
    if ! atomic_replace_from \
            "$backup_dir/parsed_file_list.csv.baseline" \
            "$parsed_list" "$expected_parsed_hash"; then
        printf '%s\n' 'rollback_parsed_list_restore=false'
        rollback_ok=false
    else
        printf '%s\n' 'rollback_parsed_list_restore=true'
    fi

    wait_for_adsp_recovery
    printf 'service_active_after_rollback=%s\n' \
        "$(systemctl is-active "$unit" 2>/dev/null || true)"
    printf 'database_hash_after_rollback=%s\n' "$(hash_file "$current")"
    printf 'fstemp_hash_after_rollback=%s\n' "$(hash_file "$fstemp")"
    printf 'parsed_list_hash_after_rollback=%s\n' "$(hash_file "$parsed_list")"

    [ "$(systemctl is-active "$unit" 2>/dev/null || true)" = inactive ] || rollback_ok=false
    [ "$(hash_file "$current")" = "$expected_current_hash" ] || rollback_ok=false
    [ "$(hash_file "$fstemp")" = "$expected_fstemp_hash" ] || rollback_ok=false
    [ "$(hash_file "$parsed_list")" = "$expected_parsed_hash" ] || rollback_ok=false

    rollback_running=false
    [ "$rollback_ok" = true ]
}

cleanup_on_exit() {
    local status=$?
    trap - EXIT
    if [ "$mutation_started" = true ] && [ "$test_complete" = false ]; then
        set +e
        printf '\n%s\n' 'Unexpected exit after mutation; attempting fail-safe rollback.'
        if rollback_baseline; then
            printf '%s\n' 'fail_safe_rollback=complete'
        else
            printf '%s\n' 'fail_safe_rollback=INCOMPLETE-MANUAL-RECOVERY-REQUIRED'
        fi
    fi
    exit "$status"
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

sudo -v
exec > >(tee "$report") 2>&1

printf '%s\n' 'A14 SSC secure sensor-database A/B test'
printf '%s\n' '========================================'
printf 'timestamp=%s\n' "$(date --iso-8601=ns)"
printf 'unit=%s\n' "$unit"
printf 'current=%s\n' "$current"
printf 'reference=%s\n' "$reference"
printf 'observation_seconds=%s\n' "$observe_seconds"
printf '%s\n' 'planned_replacement=sns_secure_database.bin-only'
printf '%s\n' 'fstempfile_planned_change=false'
printf '%s\n' 'parsed_file_list_planned_change=false'
printf '%s\n' 'firmware_changes=false'
printf '%s\n' 'module_reload=false'
printf '%s\n' 'remoteproc_manual_control=false'
printf '%s\n' 'service_enablement_change=false'
printf '%s\n' 'reboot=false'

printf '\n%s\n' '===== FAIL-CLOSED PREFLIGHT ====='
active_before=$(systemctl is-active "$unit" 2>/dev/null || true)
enabled_before=$(systemctl is-enabled "$unit" 2>/dev/null || true)
printf 'service_active_before=%s\n' "$active_before"
printf 'service_enabled_before=%s\n' "$enabled_before"
[ "$active_before" = inactive ] || \
    fail "$unit must already be inactive; found: $active_before"
[ "$enabled_before" = enabled ] || \
    fail "$unit enablement differs from the captured baseline; found: $enabled_before"
[ -e /dev/fastrpc-adsp ] || fail "/dev/fastrpc-adsp is missing"
[ "$(adsp_state)" = running ] || fail "ADSP must be running before the test"

require_exact_file active-database "$current" \
    "$expected_current_hash" "$expected_current_size"
require_exact_file stage15-reference "$reference" \
    "$expected_reference_hash" "$expected_reference_size"
require_exact_file fstempfile "$fstemp" \
    "$expected_fstemp_hash" "$expected_fstemp_size"
require_exact_file parsed-file-list "$parsed_list" \
    "$expected_parsed_hash" "$expected_parsed_size"

[ "$(sudo stat -c '%u:%g:%a' "$current")" = 0:0:600 ] || \
    fail "active database metadata is not root:root mode 600"
[ "$(sudo stat -c '%u:%g:%a' "$reference")" = 0:0:600 ] || \
    fail "reference database metadata is not root:root mode 600"

current_structure=$(db_structure "$current")
reference_structure=$(db_structure "$reference")
printf 'current_structure=%s\n' "$current_structure"
printf 'reference_structure=%s\n' "$reference_structure"
case "$current_structure" in
    partial-record-stream:records=295:offset=34813:bytes=3) ;;
    *) fail "active database no longer has the analyzed partial-record structure" ;;
esac
case "$reference_structure" in
    complete-record-stream:records=392:size=46430) ;;
    *) fail "Stage 15 database no longer has the analyzed complete-record structure" ;;
esac
state_line

printf '\n%s\n' '===== BASELINE FILES ====='
describe_file active-database "$current"
describe_file stage15-reference "$reference"
describe_file fstempfile "$fstemp"
describe_file parsed-file-list "$parsed_list"

crashes_before=$(crash_count)
printf '\n%s\n' '===== BASELINE RUNTIME ====='
printf 'adsp_crashes_before=%s\n' "$crashes_before"
state_line
cat /proc/asound/cards 2>/dev/null || true

tag=$(date +%Y%m%d-%H%M%S)
backup_dir=$backup_root/sns-db-ab-$tag
sudo test ! -e "$backup_dir" || fail "backup destination already exists: $backup_dir"
sudo install -d -m 700 "$backup_dir"
sudo cp --archive --reflink=auto -- "$current" \
    "$backup_dir/sns_secure_database.bin.baseline"
sudo cp --archive --reflink=auto -- "$fstemp" \
    "$backup_dir/fstempfile.baseline"
sudo cp --archive --reflink=auto -- "$parsed_list" \
    "$backup_dir/parsed_file_list.csv.baseline"

printf '\n%s\n' '===== ROLLBACK SNAPSHOT ====='
printf 'backup_dir=%s\n' "$backup_dir"
sudo stat -c 'path=%n size=%s mode=%a owner=%U:%G mtime=%y' \
    "$backup_dir/sns_secure_database.bin.baseline" \
    "$backup_dir/fstempfile.baseline" \
    "$backup_dir/parsed_file_list.csv.baseline"
sudo sha256sum \
    "$backup_dir/sns_secure_database.bin.baseline" \
    "$backup_dir/fstempfile.baseline" \
    "$backup_dir/parsed_file_list.csv.baseline"
[ "$(hash_file "$backup_dir/sns_secure_database.bin.baseline")" = \
    "$expected_current_hash" ] || fail "database rollback snapshot verification failed"
[ "$(hash_file "$backup_dir/fstempfile.baseline")" = \
    "$expected_fstemp_hash" ] || fail "fstemp rollback snapshot verification failed"
[ "$(hash_file "$backup_dir/parsed_file_list.csv.baseline")" = \
    "$expected_parsed_hash" ] || fail "parsed-list rollback snapshot verification failed"

# Close the gap between preflight and replacement: abort if any live file moved.
require_exact_file active-database "$current" \
    "$expected_current_hash" "$expected_current_size"
require_exact_file fstempfile "$fstemp" \
    "$expected_fstemp_hash" "$expected_fstemp_size"
require_exact_file parsed-file-list "$parsed_list" \
    "$expected_parsed_hash" "$expected_parsed_size"
[ "$(systemctl is-active "$unit" 2>/dev/null || true)" = inactive ] || \
    fail "$unit changed state during preflight"

printf '\n%s\n' '===== ATOMIC DATABASE REPLACEMENT ====='
mutation_started=true
atomic_replace_from "$reference" "$current" "$expected_reference_hash" || \
    fail "atomic database replacement failed"
printf 'replacement_time=%s\n' "$(date --iso-8601=ns)"
printf 'database_hash_after_replacement=%s\n' "$(hash_file "$current")"
printf 'database_structure_after_replacement=%s\n' "$(db_structure "$current")"
printf 'fstemp_hash_after_replacement=%s\n' "$(hash_file "$fstemp")"
printf 'parsed_list_hash_after_replacement=%s\n' "$(hash_file "$parsed_list")"
[ "$(hash_file "$current")" = "$expected_reference_hash" ] || \
    fail "installed database did not retain the reference hash"
[ "$(hash_file "$fstemp")" = "$expected_fstemp_hash" ] || \
    fail "fstempfile changed before service start"
[ "$(hash_file "$parsed_list")" = "$expected_parsed_hash" ] || \
    fail "parsed file list changed before service start"

printf '\n%s\n' '===== START SERVICE AND OBSERVE ====='
test_start=$(date --iso-8601=seconds)
printf 'test_start=%s\n' "$test_start"
failure_reason=
if ! sudo systemctl start "$unit"; then
    failure_reason=service-start-command-failed
fi

elapsed=0
while [ -z "$failure_reason" ] && [ "$elapsed" -lt "$observe_seconds" ]; do
    sleep 1
    elapsed=$((elapsed + 1))
    crashes_now=$(crash_count)
    service_now=$(systemctl is-active "$unit" 2>/dev/null || true)
    adsp_now=$(adsp_state)
    printf 'sample=%s service=%s adsp=%s crashes=%s\n' \
        "$elapsed" "$service_now" "$adsp_now" "$crashes_now"
    if [ "$crashes_now" -gt "$crashes_before" ]; then
        failure_reason=new-adsp-crash
    elif [ "$crashes_now" -lt "$crashes_before" ]; then
        failure_reason=adsp-crash-counter-reset
    elif [ "$service_now" != active ]; then
        failure_reason=reverse-fs-service-not-active
    elif [ "$adsp_now" != running ]; then
        failure_reason=adsp-not-running
    fi
done

post_structure=$(db_structure "$current")
case "$post_structure" in
    complete-record-stream:*) ;;
    *) [ -n "$failure_reason" ] || failure_reason=post-test-database-malformed ;;
esac

if [ -n "$failure_reason" ]; then
    printf '\n%s\n' '===== TEST FAILURE ====='
    printf 'failure_reason=%s\n' "$failure_reason"
    if rollback_baseline; then
        rollback_result=complete
        mutation_started=false
        test_complete=true
    else
        rollback_result=INCOMPLETE-MANUAL-RECOVERY-REQUIRED
    fi
    printf 'rollback_result=%s\n' "$rollback_result"
else
    test_complete=true
    mutation_started=false
fi

printf '\n%s\n' '===== EVENTS SINCE TEST START ====='
sudo journalctl -k -b --since "$test_start" --no-pager -o short-monotonic 2>/dev/null | \
    grep -Ei 'sensor_process|sns_registry|sns_secure|sns_rps|remoteproc0|audio_pd|charger_pd|qcom-apm|gprsvc|snd-x1e80100|soundwire' || true
sudo journalctl -u "$unit" -b --since "$test_start" --no-pager -o short-monotonic 2>/dev/null | \
    grep -E 'Starting|Started|Could not|Broken pipe|Main process|Deactivated|Failed|sns_secure_database' | \
    tail -n 160 || true

printf '\n%s\n' '===== FINAL STATE ====='
crashes_after=$(crash_count)
printf 'adsp_crashes_after=%s\n' "$crashes_after"
if [ "$crashes_after" -ge "$crashes_before" ]; then
    printf 'new_adsp_crashes=%s\n' "$((crashes_after - crashes_before))"
else
    printf '%s\n' 'new_adsp_crashes=unknown-counter-reset'
fi
printf 'service_active_after=%s\n' "$(systemctl is-active "$unit" 2>/dev/null || true)"
printf 'service_enabled_after=%s\n' "$(systemctl is-enabled "$unit" 2>/dev/null || true)"
state_line
cat /proc/asound/cards 2>/dev/null || true
describe_file final-database "$current"
printf 'final_database_structure=%s\n' "$(db_structure "$current")"
describe_file final-fstempfile "$fstemp"
describe_file final-parsed-file-list "$parsed_list"

printf '\n%s\n' '===== RESULT ====='
if [ -z "$failure_reason" ]; then
    printf '%s\n' 'result=stage15-database-stable-no-adsp-crash'
    printf '%s\n' 'database_left=stage15-reference-or-valid-runtime-update'
    printf '%s\n' 'service_left=active'
    exit_status=0
else
    printf 'result=test-failed-%s\n' "$failure_reason"
    printf 'rollback_result=%s\n' "$rollback_result"
    printf '%s\n' 'service_left=inactive'
    exit_status=2
fi
printf 'backup_dir=%s\n' "$backup_dir"
printf 'report=%s\n' "$report"
printf '%s\n' 'firmware_changes=false'
printf '%s\n' 'module_reload=false'
printf '%s\n' 'remoteproc_manual_control=false'
printf '%s\n' 'service_enablement_change=false'
printf '%s\n' 'reboot=false'
exit "$exit_status"
