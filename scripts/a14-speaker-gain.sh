#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS Zenbook A14 UX3407RA WSA884x speaker hardware-gain calibration.
#
# Upstream alsa-ucm-conf currently routes the A14 through the shared X1E80100
# two-speaker profile and programs both WSA884x PA controls to 12.  The WSA884x
# driver exposes PA gain in 1.5 dB steps.  This helper raises only the physical
# speaker PA controls, keeps left/right identical, and refuses to act unless the
# expected smart-amp protection/routing controls are present.
set -euo pipefail

ACTION="${1:-status}"
REQUESTED="${2:-14}"
CARD_EXPECT="X1E80100-ASUS-Zenbook-A14"
BASELINE=12
DEFAULT=14
MIN_SAFE=12
MAX_SAFE=16

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

need amixer
need awk
need grep

find_card(){
    local id name
    while read -r id _; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        name="$(cat "/proc/asound/card${id}/id" 2>/dev/null || true)"
        if [[ "$name" == X1E80100ASUSZen ]]; then
            printf '%s\n' "$id"
            return 0
        fi
    done < <(awk '/^[[:space:]]*[0-9]+ \[/ { gsub(/^[[:space:]]+/, "", $0); split($0,a," "); print a[1], a[2] }' /proc/asound/cards 2>/dev/null)

    # Fallback to long card-name matching if ALSA changes the short ID.
    for p in /proc/asound/card[0-9]*/id; do
        [[ -r "$p" ]] || continue
        id="${p%/id}"; id="${id##*card}"
        if grep -Fq 'X1E80100' "/proc/asound/card${id}/id" 2>/dev/null &&
           grep -Fq "$CARD_EXPECT" /proc/asound/cards 2>/dev/null; then
            printf '%s\n' "$id"
            return 0
        fi
    done
    return 1
}

CARD="$(find_card || true)"
[[ -n "$CARD" ]] || die "ASUS Zenbook A14 ALSA card not found"
grep -Fq "$CARD_EXPECT" /proc/asound/cards || die "refusing non-A14 card: expected '$CARD_EXPECT'"

ctl_exists(){ amixer -c "$CARD" cget "name='$1'" >/dev/null 2>&1; }
ctl_value(){
    amixer -c "$CARD" cget "name='$1'" 2>/dev/null | awk -F= '/: values=/{print $2; exit}'
}
ctl_db(){
    # Linux WSA884x exposes -9 dB base plus 1.5 dB per raw PA step.
    local name="$1" raw
    raw="$(ctl_value "$name")"
    awk -v v="$raw" 'BEGIN { printf "%.1f dB", -9.0 + (1.5 * v) }'
}

for c in \
    'SpkrLeft PA Volume' 'SpkrRight PA Volume' \
    'SpkrLeft COMP Switch' 'SpkrRight COMP Switch' \
    'SpkrLeft BOOST Switch' 'SpkrRight BOOST Switch' \
    'SpkrLeft DAC Switch' 'SpkrRight DAC Switch' \
    'SpkrLeft PBR Switch' 'SpkrRight PBR Switch'; do
    ctl_exists "$c" || die "required WSA884x mixer control missing: $c"
done

show_status(){
    local l r
    l="$(ctl_value 'SpkrLeft PA Volume')"
    r="$(ctl_value 'SpkrRight PA Volume')"
    say "A14_SPEAKER_GAIN_STATUS=OK"
    say "card=$CARD"
    say "card_name=$CARD_EXPECT"
    say "left_pa_raw=$l"
    say "right_pa_raw=$r"
    say "left_pa_gain=$(ctl_db 'SpkrLeft PA Volume')"
    say "right_pa_gain=$(ctl_db 'SpkrRight PA Volume')"
    say "upstream_baseline_raw=$BASELINE"
    say "upstream_baseline_gain=$(awk -v v="$BASELINE" 'BEGIN { printf "%.1f dB", -9.0 + 1.5*v }')"
    say "default_a14_raw=$DEFAULT"
    say "default_a14_gain=$(awk -v v="$DEFAULT" 'BEGIN { printf "%.1f dB", -9.0 + 1.5*v }')"
    for c in 'COMP' 'BOOST' 'DAC' 'PBR'; do
        say "left_${c,,}=$(ctl_value "SpkrLeft $c Switch")"
        say "right_${c,,}=$(ctl_value "SpkrRight $c Switch")"
    done
}

verify_protection(){
    local c l r
    for c in COMP BOOST DAC PBR; do
        l="$(ctl_value "SpkrLeft $c Switch")"
        r="$(ctl_value "SpkrRight $c Switch")"
        case "$l" in 1|on) ;; *) die "speaker protection/routing '$c' is not enabled on left amp (L=$l); refusing gain change" ;; esac
        case "$r" in 1|on) ;; *) die "speaker protection/routing '$c' is not enabled on right amp (R=$r); refusing gain change" ;; esac
    done
}

set_gain(){
    local level="$1"
    [[ "$level" =~ ^[0-9]+$ ]] || die "gain must be an integer raw PA value"
    (( level >= MIN_SAFE && level <= MAX_SAFE )) ||
        die "refusing PA value $level; staged A14 range is $MIN_SAFE..$MAX_SAFE"
    verify_protection

    say "before_left_raw=$(ctl_value 'SpkrLeft PA Volume')"
    say "before_right_raw=$(ctl_value 'SpkrRight PA Volume')"
    amixer -q -c "$CARD" cset "name='SpkrLeft PA Volume'" "$level"
    amixer -q -c "$CARD" cset "name='SpkrRight PA Volume'" "$level"

    [[ "$(ctl_value 'SpkrLeft PA Volume')" == "$level" ]] || die "left PA gain did not latch"
    [[ "$(ctl_value 'SpkrRight PA Volume')" == "$level" ]] || die "right PA gain did not latch"
    say "A14_SPEAKER_GAIN_APPLIED=1"
    say "pa_raw=$level"
    say "pa_gain=$(awk -v v="$level" 'BEGIN { printf "%.1f dB", -9.0 + 1.5*v }')"
    say "delta_from_upstream=$(awk -v v="$level" -v b="$BASELINE" 'BEGIN { printf "%+.1f dB", 1.5*(v-b) }')"
    say "pipewire_software_boost=not_used"
    say "left_right_locked=yes"
}

case "$ACTION" in
    status)
        show_status
        ;;
    apply)
        set_gain "$DEFAULT"
        ;;
    test)
        set_gain "$REQUESTED"
        ;;
    restore)
        # Restore the exact shared-UCM speaker PA setting. Do not require the
        # protection switches here: restore must remain available even if the
        # speaker route is currently inactive.
        amixer -q -c "$CARD" cset "name='SpkrLeft PA Volume'" "$BASELINE"
        amixer -q -c "$CARD" cset "name='SpkrRight PA Volume'" "$BASELINE"
        say "A14_SPEAKER_GAIN_RESTORED=1"
        say "pa_raw=$BASELINE"
        ;;
    *)
        die "usage: $0 {status|apply|test [12..16]|restore}"
        ;;
esac
