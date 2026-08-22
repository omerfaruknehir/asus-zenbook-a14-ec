#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Read-only source-tree locator for A14 speaker-protection V2.
# The V2 transport must be layered on a source tree carrying the user's current
# A14 fixes; this script deliberately does not clone, patch, build or install.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
PATCH="$ROOT/patches/0001-a14-wsa-visense-transport-v1.patch"
KR="$(uname -r)"

say(){ printf '%s\n' "$*"; }

[[ -r "$PATCH" ]] || { echo "ERROR: patch missing: $PATCH" >&2; exit 1; }

say '===== A14 SPEAKER PROTECTION V2 SOURCE PREFLIGHT ====='
say "running_kernel=$KR"
say "patch=$PATCH"
say 'operation=READ_ONLY'
say 'gain_changes=false'
say 'module_changes=false'
say 'boot_changes=false'

# Build a small candidate set.  Do not recursively crawl the home directory.
declare -a candidates=()
add_candidate(){
    local p="$1" r
    [[ -n "$p" ]] || return 0
    [[ -d "$p" ]] || return 0
    r="$(readlink -f "$p" 2>/dev/null || printf '%s' "$p")"
    local x
    for x in "${candidates[@]:-}"; do [[ "$x" == "$r" ]] && return 0; done
    candidates+=("$r")
}

[[ -z "${A14_SPKPROT_SOURCE:-}" ]] || add_candidate "$A14_SPKPROT_SOURCE"
add_candidate "/lib/modules/$KR/source"

shopt -s nullglob
for p in \
    "$HOME"/Downloads/a14-*/source/linux-7.1.5 \
    "$HOME"/Downloads/a14-*/linux-7.1.5 \
    "$HOME"/Downloads/linux-7.1.5 \
    "$HOME"/a14-*/linux-7.1.5; do
    add_candidate "$p"
done
shopt -u nullglob

if ((${#candidates[@]} == 0)); then
    say 'result=NO_SOURCE_CANDIDATES'
    say 'next=set A14_SPKPROT_SOURCE to the source tree used for the current kernel'
    exit 3
fi

required=(
    Documentation/devicetree/bindings/sound/qcom,wsa8840.yaml
    arch/arm64/boot/dts/qcom/x1-asus-zenbook-a14.dtsi
    drivers/soundwire/qcom.c
    sound/soc/codecs/lpass-wsa-macro.c
    sound/soc/codecs/wsa884x.c
    sound/soc/qcom/qdsp6/q6dsp-lpass-ports.c
    sound/soc/qcom/x1e80100.c
)

n=0
usable=0
for src in "${candidates[@]}"; do
    n=$((n+1))
    say
    say "===== CANDIDATE $n ====="
    say "source=$src"

    missing=0
    for rel in "${required[@]}"; do
        if [[ ! -s "$src/$rel" ]]; then
            say "missing=$rel"
            missing=1
        fi
    done
    if ((missing)); then
        say 'required_files=INCOMPLETE'
        continue
    fi
    say 'required_files=OK'

    if [[ -d "$src/.git" ]]; then
        head="$(git -C "$src" rev-parse HEAD 2>/dev/null || true)"
        desc="$(git -C "$src" describe --always --dirty 2>/dev/null || true)"
        say "git_head=$head"
        say "git_describe=$desc"
        status_count="$(git -C "$src" status --porcelain=v1 2>/dev/null | wc -l)"
        say "working_tree_changes=$status_count"

        set +e
        apply_out="$(git -C "$src" apply --check "$PATCH" 2>&1)"
        apply_rc=$?
        set -e
        if ((apply_rc == 0)); then
            say 'patch_apply_check=CLEAN'
            usable=$((usable+1))
        else
            # A modified A14 tree may need 3-way context.  This remains read-only.
            set +e
            apply3_out="$(git -C "$src" apply --3way --check "$PATCH" 2>&1)"
            apply3_rc=$?
            set -e
            if ((apply3_rc == 0)); then
                say 'patch_apply_check=THREE_WAY_CLEAN'
                usable=$((usable+1))
            else
                say 'patch_apply_check=CONFLICT'
                say 'patch_error_begin'
                printf '%s\n' "$apply_out" | tail -n 25
                [[ -z "${apply3_out:-}" ]] || printf '%s\n' "$apply3_out" | tail -n 25
                say 'patch_error_end'
            fi
        fi
    else
        say 'git_repo=no'
        set +e
        dry_out="$(cd "$src" && patch --dry-run -p1 < "$PATCH" 2>&1)"
        dry_rc=$?
        set -e
        if ((dry_rc == 0)); then
            say 'patch_apply_check=CLEAN_NON_GIT'
            usable=$((usable+1))
        else
            say 'patch_apply_check=CONFLICT_NON_GIT'
            printf '%s\n' "$dry_out" | tail -n 25
        fi
    fi

    # Fingerprint the existing A14 safety policy without changing it.
    if grep -Fq 'snd_soc_limit_volume(card, "WSA WSA_RX0 Digital Volume", 81);' \
        "$src/sound/soc/qcom/x1e80100.c"; then
        say 'digital_gain_cap_81=PRESENT'
    else
        say 'digital_gain_cap_81=NOT_FOUND'
    fi
    if grep -Fq 'snd_soc_limit_volume(card, "SpkrLeft PA Volume", 6);' \
        "$src/sound/soc/qcom/x1e80100.c"; then
        say 'pa_gain_cap_6=PRESENT'
    else
        say 'pa_gain_cap_6=NOT_FOUND'
    fi
done

say
say '===== RESULT ====='
say "candidate_count=${#candidates[@]}"
say "patchable_candidate_count=$usable"
if ((usable == 1)); then
    say 'result=ONE_PATCHABLE_SOURCE'
elif ((usable > 1)); then
    say 'result=MULTIPLE_PATCHABLE_SOURCES_NEED_IDENTITY_CHECK'
else
    say 'result=NO_PATCHABLE_SOURCE'
fi
say 'safety=NO_WRITES_PERFORMED'
