#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Read-only comparison of the active A14 SSC secure sensor database with the
# pre-existing Stage 15 backup. It never copies, replaces, or edits either file.
set -Eeuo pipefail

current=${A14_SNS_DB_CURRENT:-/var/lib/a14-ssc/runtime/sensors/registry/sns_secure_database.bin}
reference=${A14_SNS_DB_REFERENCE:-/var/lib/a14-ssc/backups/stage15-20260801-213632/var__lib__a14-ssc__runtime/sensors/registry/sns_secure_database.bin}
report=${A14_SNS_DB_REPORT:-"$HOME/Downloads/a14-sns-secure-db-compare.txt"}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for tool in awk cmp date head id python3 sha256sum stat sudo tee; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
done
[ "${EUID:-$(id -u)}" -ne 0 ] || fail "run as your normal user, not with sudo"

sudo -v
sudo test -f "$current" || fail "active database is missing: $current"
sudo test -f "$reference" || fail "reference database is missing: $reference"

exec > >(tee "$report") 2>&1
printf '%s\n' 'A14 SSC secure sensor-database comparison'
printf '%s\n' '========================================='
printf 'timestamp=%s\n' "$(date --iso-8601=ns)"
printf 'current=%s\n' "$current"
printf 'reference=%s\n' "$reference"
printf '%s\n' 'state_changes_performed=false'

describe_file() {
    local label=$1 path=$2
    printf '\n%s\n' "===== ${label^^} ====="
    sudo stat -c 'path=%n size=%s blocks=%b mtime=%y ctime=%z birth=%w mode=%a owner=%U:%G' "$path"
    sudo sha256sum "$path"
    if command -v file >/dev/null 2>&1; then
        printf 'file_type='
        sudo file -b "$path"
    fi
}

describe_file current "$current"
describe_file reference "$reference"

current_size=$(sudo stat -c %s "$current")
reference_size=$(sudo stat -c %s "$reference")
current_hash=$(sudo sha256sum "$current" | awk '{print $1}')

printf '\n%s\n' '===== PREFIX TEST ====='
printf 'current_size=%s\n' "$current_size"
printf 'reference_size=%s\n' "$reference_size"

if [ "$current_size" -le "$reference_size" ]; then
    reference_prefix_hash=$(sudo head -c "$current_size" "$reference" | sha256sum | awk '{print $1}')
    printf 'current_sha256=%s\n' "$current_hash"
    printf 'reference_prefix_sha256=%s\n' "$reference_prefix_hash"
    if sudo cmp -s -n "$current_size" "$current" "$reference"; then
        prefix_match=true
    else
        prefix_match=false
    fi
else
    reference_prefix_hash=not-applicable
    prefix_match=false
    printf '%s\n' 'reference_prefix_sha256=not-applicable-current-is-larger'
fi
printf 'current_is_exact_reference_prefix=%s\n' "$prefix_match"

printf '\n%s\n' '===== RECORD-STRUCTURE TEST ====='
sudo python3 - "$current" "$reference" <<'PY'
import sys


def parse_records(blob):
    records = []
    offset = 0
    while offset < len(blob):
        record_start = offset
        if len(blob) - offset < 32:
            return records, (offset, blob[offset:])
        value = blob[offset:offset + 32]
        offset += 32
        path_end = blob.find(b"\0", offset)
        if path_end < 0:
            return records, (record_start, blob[record_start:])
        try:
            path = blob[offset:path_end].decode("ascii")
        except UnicodeDecodeError:
            return records, (record_start, blob[record_start:])
        records.append((record_start, value, path, path_end + 1))
        offset = path_end + 1
    return records, None


current_path, reference_path = sys.argv[1:]
with open(current_path, "rb") as stream:
    current = stream.read()
with open(reference_path, "rb") as stream:
    reference = stream.read()

current_records, current_partial = parse_records(current)
reference_records, reference_partial = parse_records(reference)

print(f"current_size_multiple_of_512={str(len(current) % 512 == 0).lower()}")
print(f"current_complete_records={len(current_records)}")
print(f"reference_complete_records={len(reference_records)}")
print(f"current_partial_record={str(current_partial is not None).lower()}")
print(f"reference_partial_record={str(reference_partial is not None).lower()}")

if current_partial is not None:
    partial_offset, partial = current_partial
    print(f"current_partial_offset={partial_offset}")
    print(f"current_partial_bytes={len(partial)}")
    print(f"current_partial_hex={partial.hex()}")
    print(
        "partial_matches_reference="
        f"{str(partial == reference[partial_offset:partial_offset + len(partial)]).lower()}"
    )

body_prefix = (
    len(current) >= 32
    and len(reference) >= len(current)
    and current[32:] == reference[32:len(current)]
)
print(f"body_after_first_32_is_exact_reference_prefix={str(body_prefix).lower()}")

common = min(len(current_records), len(reference_records))
common_paths = sum(
    current_records[index][2] == reference_records[index][2]
    for index in range(common)
)
common_values = sum(
    current_records[index][1] == reference_records[index][1]
    for index in range(common)
)
print(f"common_record_paths={common_paths}")
print(f"common_record_values={common_values}")

malformed_partial = (
    current_partial is not None
    and reference_partial is None
    and len(current) % 512 == 0
    and body_prefix
    and current_partial[1]
    == reference[current_partial[0]:current_partial[0] + len(current_partial[1])]
)
print(f"malformed_block_boundary_partial_write={str(malformed_partial).lower()}")
PY

printf '\n%s\n' '===== RESULT ====='
structure_result=$(sudo python3 - "$current" "$reference" <<'PY'
import sys


def partial_offset(blob):
    offset = 0
    while offset < len(blob):
        if len(blob) - offset < 32:
            return offset
        offset += 32
        path_end = blob.find(b"\0", offset)
        if path_end < 0:
            return offset - 32
        offset = path_end + 1
    return None


with open(sys.argv[1], "rb") as stream:
    current = stream.read()
with open(sys.argv[2], "rb") as stream:
    reference = stream.read()
offset = partial_offset(current)
reference_partial = partial_offset(reference)
valid = (
    offset is not None
    and reference_partial is None
    and len(current) % 512 == 0
    and current[32:] == reference[32:len(current)]
    and current[offset:] == reference[offset:len(current)]
)
print("malformed-partial" if valid else "other")
PY
)

if [ "$structure_result" = malformed-partial ]; then
    printf '%s\n' 'result=active-database-is-malformed-block-boundary-partial-write'
elif [ "$prefix_match" = true ] && [ "$current_size" -lt "$reference_size" ]; then
    printf '%s\n' 'result=active-database-is-truncated-reference-prefix'
    printf 'missing_tail_bytes=%s\n' "$((reference_size - current_size))"
elif [ "$current_hash" = "$(sudo sha256sum "$reference" | awk '{print $1}')" ]; then
    printf '%s\n' 'result=files-identical'
else
    printf '%s\n' 'result=files-differ-not-simple-prefix-truncation'
fi
printf 'report=%s\n' "$report"
printf '%s\n' 'state_changes_performed=false'
