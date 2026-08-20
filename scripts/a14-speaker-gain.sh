#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS Zenbook A14 UX3407RA WSA884x speaker gain calibration.
#
# Important topology detail:
#   * SpkrLeft/Right PA Volume are the normal ALSA/PipeWire speaker-volume
#     controls.  UCM remaps them into the stereo "Speakers Volume" element,
#     so PipeWire continuously owns/reprograms them.  Do NOT use those as a
#     fixed board-gain offset.
#   * WSA_RX0/1 Digital Volume live one stage earlier in the LPASS WSA macro.
#     UCM initializes them to user value 84, corresponding to 0 dB.  They are
#     not the PlaybackMixerElem used by PipeWire for the normal volume slider.
#
# This helper therefore leaves PA volume under PipeWire control and applies a
# small, symmetric digital offset to WSA_RX0/1.  Default test is +3 dB.
set -euo pipefail

ACTION="${1:-status}"
REQUESTED_DB="${2:-3}"
CARD_EXPECT="X1E80100-ASUS-Zenbook-A14"
DIGITAL_ZERO=84
DEFAULT_DB=3
MIN_DB=0
MAX_DB=6

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

for c in amixer awk grep cat; do need "$c"; done

find_card(){
    local id name p
    while read -r id _; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        name="$(cat "/proc/asound/card${id}/id" 2>/dev/null || true)"
        if [[ "$name" == X1E80100ASUSZen ]]; then
            printf '%s\n' "$id"
            return 0
        fi
    done < <(awk '/^[[:space:]]*[0-9]+ \[/ { gsub(/^[[:space:]]+/, "", $0); split($0,a," "); print a[1], a[2] }' /proc/asound/cards 2>/dev/null)

    for p in /proc/asound/card[0-9]*/id; do
        [[ -r "$p" ]] || continue
        id="${p%/id}"; id="${id##*card}"
        if grep -Fq "$CARD_EXPECT" /proc/asound/cards 2>/dev/null; then
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
ctl_meta(){
    amixer -c "$CARD" cget "name='$1'" 2>/dev/null | awk '/; type=/{print; exit}' | sed 's/^[[:space:]]*//'
}

PA_LEFT='SpkrLeft PA Volume'
PA_RIGHT='SpkrRight PA Volume'
DIG0='WSA_RX0 Digital Volume'
DIG1='WSA_RX1 Digital Volume'

for c in \
    "$PA_LEFT" "$PA_RIGHT" "$DIG0" "$DIG1" \
    'SpkrLeft COMP Switch' 'SpkrRight COMP Switch' \
    'SpkrLeft BOOST Switch' 'SpkrRight BOOST Switch' \
    'SpkrLeft DAC Switch' 'SpkrRight DAC Switch' \
    'SpkrLeft PBR Switch' 'SpkrRight PBR Switch'; do
    ctl_exists "$c" || die "required A14 speaker mixer control missing: $c"
done

pa_db(){
    # WSA884x PA TLV is -9 dB + 1.5 dB per exposed ALSA step.
    local raw="$1"
    awk -v v="$raw" 'BEGIN { printf "%.1f dB", -9.0 + (1.5 * v) }'
}

digital_db(){
    # SOC_SINGLE_S8_TLV exposes -84..+40 dB as user values 0..124,
    # therefore exposed user value 84 is 0 dB.
    local raw="$1"
    awk -v v="$raw" -v z="$DIGITAL_ZERO" 'BEGIN { printf "%+.1f dB", v-z }'
}

verify_protection(){
    local c l r
    for c in COMP BOOST DAC PBR; do
        l="$(ctl_value "SpkrLeft $c Switch")"
        r="$(ctl_value "SpkrRight $c Switch")"
        case "$l" in 1|on) ;; *) die "speaker '$c' is not enabled on left amp (L=$l); refusing gain change" ;; esac
        case "$r" in 1|on) ;; *) die "speaker '$c' is not enabled on right amp (R=$r); refusing gain change" ;; esac
    done
}

show_status(){
    local pl pr d0 d1
    pl="$(ctl_value "$PA_LEFT")"
    pr="$(ctl_value "$PA_RIGHT")"
    d0="$(ctl_value "$DIG0")"
    d1="$(ctl_value "$DIG1")"

    say "A14_SPEAKER_GAIN_STATUS=OK"
    say "card=$CARD"
    say "card_name=$CARD_EXPECT"
    say "pa_volume_owner=PipeWire_ALSA_normal_volume"
    say "left_pa_raw=$pl"
    say "right_pa_raw=$pr"
    say "left_pa_gain=$(pa_db "$pl")"
    say "right_pa_gain=$(pa_db "$pr")"
    say "wsa_rx0_raw=$d0"
    say "wsa_rx1_raw=$d1"
    say "wsa_rx0_gain=$(digital_db "$d0")"
    say "wsa_rx1_gain=$(digital_db "$d1")"
    say "wsa_digital_zero_raw=$DIGITAL_ZERO"
    say "default_extra_gain=${DEFAULT_DB}dB"
    say "pa_meta=$(ctl_meta "$PA_LEFT")"
    say "digital_meta=$(ctl_meta "$DIG0")"
    for c in COMP BOOST DAC PBR; do
        say "left_${c,,}=$(ctl_value "SpkrLeft $c Switch")"
        say "right_${c,,}=$(ctl_value "SpkrRight $c Switch")"
    done
}

set_digital_gain(){
    local db="$1" target before0 before1 after0 after1
    [[ "$db" =~ ^[0-9]+$ ]] || die "extra gain must be an integer number of dB"
    (( db >= MIN_DB && db <= MAX_DB )) ||
        die "refusing +${db} dB; staged A14 test range is +${MIN_DB}..+${MAX_DB} dB"

    verify_protection
    before0="$(ctl_value "$DIG0")"
    before1="$(ctl_value "$DIG1")"

    # Refuse to stack our offset on an unknown pre-existing digital boost.
    # A previously applied value from this helper is allowed so apply/test is
    # deterministic rather than cumulative.
    if (( before0 < DIGITAL_ZERO || before0 > DIGITAL_ZERO + MAX_DB ||
          before1 < DIGITAL_ZERO || before1 > DIGITAL_ZERO + MAX_DB )); then
        die "unexpected WSA digital baseline (RX0=$before0 RX1=$before1); expected $DIGITAL_ZERO..$((DIGITAL_ZERO + MAX_DB))"
    fi

    target=$((DIGITAL_ZERO + db))
    say "before_wsa_rx0_raw=$before0"
    say "before_wsa_rx1_raw=$before1"
    say "before_wsa_rx0_gain=$(digital_db "$before0")"
    say "before_wsa_rx1_gain=$(digital_db "$before1")"

    amixer -q -c "$CARD" cset "name='$DIG0'" "$target"
    amixer -q -c "$CARD" cset "name='$DIG1'" "$target"

    after0="$(ctl_value "$DIG0")"
    after1="$(ctl_value "$DIG1")"
    [[ "$after0" == "$target" ]] || die "WSA_RX0 digital gain did not latch (wanted=$target got=$after0)"
    [[ "$after1" == "$target" ]] || die "WSA_RX1 digital gain did not latch (wanted=$target got=$after1)"

    say "A14_SPEAKER_GAIN_APPLIED=1"
    say "extra_gain=+${db}dB"
    say "wsa_rx0_raw=$after0"
    say "wsa_rx1_raw=$after1"
    say "wsa_rx0_gain=$(digital_db "$after0")"
    say "wsa_rx1_gain=$(digital_db "$after1")"
    say "pa_volume_controls_untouched=yes"
    say "pipewire_volume_slider_preserved=yes"
    say "left_right_locked=yes"
}

restore_gain(){
    amixer -q -c "$CARD" cset "name='$DIG0'" "$DIGITAL_ZERO"
    amixer -q -c "$CARD" cset "name='$DIG1'" "$DIGITAL_ZERO"
    [[ "$(ctl_value "$DIG0")" == "$DIGITAL_ZERO" ]] || die "WSA_RX0 restore did not latch"
    [[ "$(ctl_value "$DIG1")" == "$DIGITAL_ZERO" ]] || die "WSA_RX1 restore did not latch"
    say "A14_SPEAKER_GAIN_RESTORED=1"
    say "wsa_rx0_raw=$DIGITAL_ZERO"
    say "wsa_rx1_raw=$DIGITAL_ZERO"
    say "digital_gain=+0.0dB"
    say "pa_volume_controls_untouched=yes"
}

case "$ACTION" in
    status)
        show_status
        ;;
    apply)
        set_digital_gain "$DEFAULT_DB"
        ;;
    test)
        set_digital_gain "$REQUESTED_DB"
        ;;
    restore)
        restore_gain
        ;;
    *)
        die "usage: $0 {status|apply|test [0..6 dB]|restore}"
        ;;
esac
