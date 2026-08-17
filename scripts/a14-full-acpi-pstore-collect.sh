#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Collect persistent ramoops console data after the same-Image DT collector boot.
set -euo pipefail

KREL="7.1.5-a14-acpi-full0"
OWNER="${SUDO_USER:-$(id -un)}"
OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
[[ -n "$OWNER_HOME" ]] || OWNER_HOME="$HOME"
OUTROOT="$OWNER_HOME/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
DIR="$OUTROOT/a14-full-acpi-pstore-$STAMP"
ARCHIVE="$DIR.tar.xz"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"
for c in uname dmesg grep find cp tar mountpoint date getent; do need "$c"; done

[[ "$(uname -r)" == "$KREL" ]] || die "boot the PSTORE COLLECTOR entry first; running kernel is $(uname -r)"
[[ -d /proc/device-tree ]] || die "collector boot has no device tree"
cmdline="$(cat /proc/cmdline)"
grep -qE '(^| )acpi=off( |$)' <<<"$cmdline" || die "collector boot is not acpi=off"
grep -qE '(^| )reserve_mem=2M:1M:a14log( |$)' <<<"$cmdline" || die "collector lacks the a14log reserve_mem layout"
grep -qE '(^| )ramoops\.mem_name=a14log( |$)' <<<"$cmdline" || die "collector lacks ramoops.mem_name=a14log"
grep -qE '(^| )nokaslr( |$)' <<<"$cmdline" || die "collector lacks nokaslr; reserved RAM address may not match"

mkdir -p "$DIR/pstore-live" "$DIR/pstore-systemd"

{
    echo "A14_FULL_ACPI_PSTORE_COLLECTOR=METADATA"
    echo "timestamp=$(date --iso-8601=seconds)"
    echo "uname=$(uname -a)"
    echo "kernelrelease=$(uname -r)"
    echo "device_tree_present=true"
    echo "cmdline=$cmdline"
    echo "collector_acpi=off"
    echo "reserve_mem=2M:1M:a14log"
    echo "ramoops_mem_name=a14log"
    echo "nokaslr=true"
} > "$DIR/metadata.txt"

cat /proc/cmdline > "$DIR/proc-cmdline.txt"
cat /proc/iomem > "$DIR/proc-iomem.txt" 2>/dev/null || true
cp -a "/boot/config-$KREL" "$DIR/kernel-config.txt" 2>/dev/null || true
cp -a "/boot/System.map-$KREL" "$DIR/System.map" 2>/dev/null || true

dmesg > "$DIR/collector-dmesg.txt" 2>&1 || true
dmesg | grep -Ei 'a14|pstore|ramoops|reserve_mem|a14log|arm-smmu|smmu|iommu|iort|efi.*early|earlycon' \
    > "$DIR/collector-dmesg-focus.txt" 2>&1 || true
grep -Ei 'a14log|ramoops|persistent|reserved' /proc/iomem \
    > "$DIR/proc-iomem-focus.txt" 2>&1 || true

# pstore is normally mounted by systemd. Mount it only if the collector boot did
# not do so; never clear or unlink records here.
mkdir -p /sys/fs/pstore
if ! mountpoint -q /sys/fs/pstore; then
    mount -t pstore pstore /sys/fs/pstore 2>"$DIR/pstore-mount-error.txt" || true
fi

copy_records(){
    local src="$1" dst="$2"
    [[ -d "$src" ]] || return 0
    while IFS= read -r -d '' file; do
        cp -a -- "$file" "$dst/"
    done < <(find "$src" -maxdepth 1 -type f -print0 2>/dev/null)
}

copy_records /sys/fs/pstore "$DIR/pstore-live"
copy_records /var/lib/systemd/pstore "$DIR/pstore-systemd"

# Produce readable concatenations without modifying the originals.
{
    echo '===== /sys/fs/pstore ====='
    for f in "$DIR"/pstore-live/*; do
        [[ -f "$f" ]] || continue
        echo
        echo "===== $(basename "$f") ====="
        cat "$f" || true
    done
    echo
    echo '===== /var/lib/systemd/pstore ====='
    for f in "$DIR"/pstore-systemd/*; do
        [[ -f "$f" ]] || continue
        echo
        echo "===== $(basename "$f") ====="
        cat "$f" || true
    done
} > "$DIR/pstore-concatenated.txt" 2>&1

record_count="$(find "$DIR/pstore-live" "$DIR/pstore-systemd" -maxdepth 1 -type f 2>/dev/null | wc -l)"
focus_hits="$(grep -Eic 'A14|arm-smmu|smmu|iommu|probe1|device initcall|ACPI' "$DIR/pstore-concatenated.txt" 2>/dev/null || true)"
{
    echo "record_count=$record_count"
    echo "diagnostic_focus_hits=$focus_hits"
    if (( record_count == 0 )); then
        echo "previous_log_recovered=false"
        echo "note=no pstore record was exposed; RAM may have been cleared or reserve_mem may not have reused the same address"
    else
        echo "previous_log_recovered=true"
    fi
} > "$DIR/result.txt"

# Preserve the directory and archive; do not remove pstore files from either
# kernel pstore or systemd's archive.
tar -C "$OUTROOT" -cJf "$ARCHIVE" "$(basename "$DIR")"
chown -R "$OWNER":"$(id -gn "$OWNER")" "$DIR" "$ARCHIVE" 2>/dev/null || true

say "A14_FULL_ACPI_PSTORE_COLLECTION=COMPLETE"
say "directory=$DIR"
say "archive=$ARCHIVE"
say "record_count=$record_count"
say "diagnostic_focus_hits=$focus_hits"
if (( record_count == 0 )); then
    say "previous_log_recovered=false"
    say "reason_hint=RAM cleared or reserve_mem address was not preserved"
else
    say "previous_log_recovered=true"
    say "important_file=$DIR/pstore-concatenated.txt"
fi
