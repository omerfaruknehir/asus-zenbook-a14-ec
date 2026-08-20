#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Build/install/audit the ASUS Zenbook A14 WSA884x VISENSE transport kernel.
# V1 is deliberately transport-only: it preserves upstream -3 dB digital and
# 0 dB PA safety caps.  It must not be used to raise speaker gain.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ACTION="${1:-status}"
BASE_KVER="${A14_SPKPROT_BASE_KVER:-7.1.5-070105-generic}"
BASE_TAG="v7.1.5"
BASE_COMMIT="155b42bec9cbb6b8cdc47dd9bd09503a81fbe493"
LOCALVERSION="-a14-spkprot-v1"
EXPECTED_KREL="7.1.5${LOCALVERSION}"

owner_home() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then
        getent passwd "$SUDO_USER" | cut -d: -f6
    else
        printf '%s\n' "$HOME"
    fi
}

OWNER_HOME="$(owner_home)"
WORK="${A14_SPKPROT_WORK:-$OWNER_HOME/Downloads/a14-speaker-protection-kernel}"
SRC="$WORK/linux-7.1.5"
OUT="$WORK/build"
LOGDIR="$WORK/build-logs"
META="$WORK/meta.env"
DTB_REL="qcom/x1e80100-asus-zenbook-a14.dtb"
DTB_OUT="$OUT/arch/arm64/boot/dts/$DTB_REL"
DTB_INSTALL_DIR="/boot/a14-speaker-protection"
GRUB_SNIPPET="/etc/grub.d/41_a14_speaker_protection"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "this action requires sudo/root"; }
need_user(){ [[ ${EUID:-$(id -u)} -ne 0 ]] || die "build as the normal user, not root"; }

check_arch(){
    case "$(uname -m)" in aarch64|arm64) ;; *) die "native AArch64 build required; found $(uname -m)";; esac
}

check_build_deps(){
    local missing=() c
    for c in git python3 make gcc bc bison flex perl rsync pahole openssl cpio tee sha256sum; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if ((${#missing[@]})); then
        printf 'Missing build tools: %s\n' "${missing[*]}" >&2
        printf 'Ubuntu baseline: sudo apt install build-essential bc bison flex libssl-dev libelf-dev dwarves rsync cpio git python3\n' >&2
        exit 1
    fi
}

kernel_config_source(){
    [[ -r "/boot/config-$BASE_KVER" ]] && { printf '%s\n' "/boot/config-$BASE_KVER"; return; }
    [[ "$(uname -r)" == "$BASE_KVER" && -r /proc/config.gz ]] && { printf '%s\n' /proc/config.gz; return; }
    return 1
}

run_phase(){
    local label="$1" logfile="$2"; shift 2
    mkdir -p "$LOGDIR"
    : > "$logfile"
    say "===== $label ====="
    set +e
    "$@" 2>&1 | tee "$logfile" | python3 "$ROOT/scripts/a14-kbuild-progress.py" \
        --label "$label" --logfile "$logfile"
    local rc=${PIPESTATUS[0]}
    set -e
    (( rc == 0 )) || die "$label failed; inspect $logfile"
    say "A14_BUILD_PHASE_COMPLETE=$label"
}

prepare_source(){
    need_user
    check_arch
    check_build_deps
    mkdir -p "$WORK"

    if [[ ! -d "$SRC/.git" ]]; then
        say "Cloning exact stable Linux $BASE_TAG from GitHub..."
        git clone --filter=blob:none --no-checkout https://github.com/gregkh/linux.git "$SRC"
    fi
    git -C "$SRC" fetch --force --depth=1 origin "refs/tags/$BASE_TAG:refs/tags/$BASE_TAG"
    git -C "$SRC" checkout --detach "$BASE_TAG"
    local head
    head="$(git -C "$SRC" rev-parse HEAD)"
    [[ "$head" == "$BASE_COMMIT" ]] || die "$BASE_TAG resolved to unexpected commit $head"

    # Always reconstruct from pristine v7.1.5.  This workspace is dedicated to
    # speaker-protection V1 and is never shared with the ACPI/GPUCC tree.
    git -C "$SRC" reset --hard "$BASE_COMMIT"
    git -C "$SRC" clean -fdx
    python3 "$ROOT/scripts/apply-a14-speaker-protection-v1.py" "$SRC"

    rm -rf "$OUT" "$LOGDIR"
    mkdir -p "$OUT" "$LOGDIR"
    local cfg
    cfg="$(kernel_config_source)" || die "cannot find config for known-good $BASE_KVER"
    if [[ "$cfg" == *.gz ]]; then zcat "$cfg" > "$OUT/.config"; else cp "$cfg" "$OUT/.config"; fi

    "$SRC/scripts/config" --file "$OUT/.config" --set-str LOCALVERSION "$LOCALVERSION"
    "$SRC/scripts/config" --file "$OUT/.config" --disable LOCALVERSION_AUTO
    "$SRC/scripts/config" --set-str SYSTEM_TRUSTED_KEYS "" --file "$OUT/.config"
    "$SRC/scripts/config" --set-str SYSTEM_REVOCATION_KEYS "" --file "$OUT/.config"
    export LOCALVERSION=
    make -C "$SRC" O="$OUT" olddefconfig

    local krel
    krel="$(make -s -C "$SRC" O="$OUT" kernelrelease)"
    [[ "$krel" == "$EXPECTED_KREL" ]] || die "unexpected kernelrelease: $krel"
    cat > "$META" <<EOF
BASE_TAG='$BASE_TAG'
BASE_COMMIT='$BASE_COMMIT'
BASE_KVER='$BASE_KVER'
KREL='$krel'
SRC='$SRC'
OUT='$OUT'
EOF
    say "A14_SPEAKER_PROTECTION_V1_PREPARED=1"
    say "kernelrelease=$krel"
    say "source_commit=$head"
    say "digital_gain_cap=-3dB_PRESERVED"
    say "pa_gain_cap=0dB_PRESERVED"
}

build_kernel(){
    prepare_source
    local jobs="${A14_BUILD_JOBS:-$(nproc)}"
    export LOCALVERSION=

    run_phase "1/3 Kernel Image" "$LOGDIR/1-image.log" \
        make -C "$SRC" O="$OUT" -j"$jobs" Image
    run_phase "2/3 A14 DTB" "$LOGDIR/2-dtb.log" \
        make -C "$SRC" O="$OUT" -j"$jobs" "$DTB_REL"
    run_phase "3/3 Kernel modules" "$LOGDIR/3-modules.log" \
        make -C "$SRC" O="$OUT" -j"$jobs" modules

    [[ -s "$OUT/arch/arm64/boot/Image" ]] || die "kernel Image missing"
    [[ -s "$DTB_OUT" ]] || die "patched A14 DTB missing: $DTB_OUT"
    grep -Fq 'snd_soc_limit_volume(card, "WSA WSA_RX0 Digital Volume", 81);' "$SRC/sound/soc/qcom/x1e80100.c" || die "digital safety cap disappeared"
    grep -Fq 'snd_soc_limit_volume(card, "SpkrLeft PA Volume", 6);' "$SRC/sound/soc/qcom/x1e80100.c" || die "PA safety cap disappeared"

    say "A14_SPEAKER_PROTECTION_V1_BUILD=COMPLETE"
    say "kernelrelease=$EXPECTED_KREL"
    say "image_sha256=$(sha256sum "$OUT/arch/arm64/boot/Image" | awk '{print $1}')"
    say "dtb_sha256=$(sha256sum "$DTB_OUT" | awk '{print $1}')"
    say "visense_transport=BUILT"
    say "gain_limits=UNCHANGED"
    say "build_logs=$LOGDIR"
}

load_meta(){
    [[ -r "$META" ]] || die "missing $META; run '$0 build' first"
    # shellcheck disable=SC1090
    source "$META"
    [[ "${KREL:-}" == "$EXPECTED_KREL" ]] || die "metadata kernelrelease mismatch"
    [[ "${BASE_COMMIT:-}" == "$BASE_COMMIT" ]] || die "metadata source commit mismatch"
    [[ -s "$OUT/arch/arm64/boot/Image" ]] || die "built Image missing"
    [[ -s "$DTB_OUT" ]] || die "built A14 DTB missing"
}

build_a14_modules_for_kernel(){
    local modwork="$WORK/a14-modules-$KREL" jobs="${A14_BUILD_JOBS:-$(nproc)}"
    [[ -x "$ROOT/scripts/a14-kbuild-compat.sh" ]] || { say "A14 EC module helper absent; skipping repo external modules"; return 0; }
    rm -rf "$modwork"; mkdir -p "$modwork"
    git -C "$ROOT" archive HEAD | tar -x -C "$modwork"
    if [[ -x "$modwork/scripts/prepare-a14-ec.py" || -f "$modwork/scripts/prepare-a14-ec.py" ]]; then
        (cd "$modwork" && python3 scripts/prepare-a14-ec.py)
    fi
    # Preserve the committed HID implementation rather than carrying an
    # unrelated generated Fn-lock experiment into this audio kernel.
    git -C "$ROOT" show HEAD:hid_asus_ec.c > "$modwork/hid_asus_ec.c"
    A14_MODULE_DIR="$modwork" A14_BUILD_JOBS="$jobs" KDIR="$OUT" \
        sh "$modwork/scripts/a14-kbuild-compat.sh" "$KREL"
    [[ -s "$modwork/asus_zenbook_a14_ec.ko" ]] || die "A14 EC external module build failed"
    [[ -s "$modwork/hid_asus_ec.ko" ]] || die "A14 HID external module build failed"
    mkdir -p "/lib/modules/$KREL/updates/a14"
    install -m 0644 "$modwork/asus_zenbook_a14_ec.ko" "/lib/modules/$KREL/updates/a14/"
    install -m 0644 "$modwork/hid_asus_ec.ko" "/lib/modules/$KREL/updates/a14/"
    depmod -a "$KREL"
}

write_grub_entry(){
    need grub-probe; need grub-mkrelpath; need update-grub
    local kernel="/boot/vmlinuz-$KREL" initrd="/boot/initrd.img-$KREL" dtb="$DTB_INSTALL_DIR/$KREL.dtb"
    local boot_uuid kernel_path initrd_path dtb_path arg
    boot_uuid="$(grub-probe --target=fs_uuid "$kernel")"
    kernel_path="$(grub-mkrelpath "$kernel")"
    initrd_path="$(grub-mkrelpath "$initrd")"
    dtb_path="$(grub-mkrelpath "$dtb")"

    local -a args=()
    for arg in $(cat /proc/cmdline); do
        case "$arg" in BOOT_IMAGE=*|initrd=*|acpi=*|stubble.dtb_override=*) continue;; *) args+=("$arg");; esac
    done
    local cmdline="${args[*]} stubble.dtb_override=true"

    cat > "$GRUB_SNIPPET" <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry 'ASUS Zenbook A14 — Speaker Protection Transport v1 ($KREL)' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root $boot_uuid
    linux $kernel_path $cmdline
    devicetree $dtb_path
    initrd $initrd_path
}
EOF
    chmod 0755 "$GRUB_SNIPPET"
    update-grub
}

install_kernel(){
    need_root; check_arch; load_meta
    [[ "$(uname -r)" != "$KREL" ]] || die "refusing to reinstall currently running experimental kernel"
    need depmod; need update-initramfs
    export LOCALVERSION=

    make -C "$SRC" O="$OUT" modules_install
    ln -sfn "$OUT" "/lib/modules/$KREL/build"
    ln -sfn "$SRC" "/lib/modules/$KREL/source"
    install -m 0644 "$OUT/arch/arm64/boot/Image" "/boot/vmlinuz-$KREL"
    [[ -s "$OUT/System.map" ]] && install -m 0644 "$OUT/System.map" "/boot/System.map-$KREL"
    install -m 0644 "$OUT/.config" "/boot/config-$KREL"
    mkdir -p "$DTB_INSTALL_DIR"
    install -m 0644 "$DTB_OUT" "$DTB_INSTALL_DIR/$KREL.dtb"

    build_a14_modules_for_kernel
    rm -f "/boot/initrd.img-$KREL"
    update-initramfs -c -k "$KREL"
    write_grub_entry

    say "A14_SPEAKER_PROTECTION_V1_INSTALL=COMPLETE"
    say "kernel=/boot/vmlinuz-$KREL"
    say "initrd=/boot/initrd.img-$KREL"
    say "dtb=$DTB_INSTALL_DIR/$KREL.dtb"
    say "grub_entry=ASUS Zenbook A14 — Speaker Protection Transport v1 ($KREL)"
    say "known_good_kernel_preserved=$BASE_KVER"
    say "gain_limits=UNCHANGED"
}

find_card(){
    awk '/X1E80100-ASUS-Zenbook-A14/ {gsub(/^[[:space:]]+/, ""); print $1; exit}' /proc/asound/cards 2>/dev/null
}

ctl_value(){ amixer -c "$1" cget "name='$2'" 2>/dev/null | awk -F= '/: values=/{print $2; exit}'; }

audit_kernel(){
    say "===== A14 SPEAKER PROTECTION V1 AUDIT ====="
    say "running_kernel=$(uname -r)"
    [[ "$(uname -r)" == "$EXPECTED_KREL" ]] || die "boot $EXPECTED_KREL before V1 audit"
    need amixer
    local card
    card="$(find_card)"; [[ -n "$card" ]] || die "A14 ALSA card not found"
    say "card=$card"

    # Hard runtime safety assertions: V1 must still expose the upstream limits.
    local dmeta pmeta
    dmeta="$(amixer -c "$card" cget "name='WSA WSA_RX0 Digital Volume'" 2>/dev/null | grep '; type=' | head -1 || true)"
    pmeta="$(amixer -c "$card" cget "name='SpkrLeft PA Volume'" 2>/dev/null | grep '; type=' | head -1 || true)"
    say "digital_meta=${dmeta#*;}"
    say "pa_meta=${pmeta#*;}"
    grep -q 'max=81' <<<"$dmeta" || die "digital cap is not 81; refusing V1 validation"
    grep -q 'max=6' <<<"$pmeta" || die "PA cap is not 6; refusing V1 validation"

    say "left_visense=$(ctl_value "$card" 'SpkrLeft VISENSE Switch')"
    say "right_visense=$(ctl_value "$card" 'SpkrRight VISENSE Switch')"
    say "vi_mix1=$(ctl_value "$card" 'WSA WSA_AIF_VI Mixer WSA_SPKR_VI_1')"
    say "vi_mix2=$(ctl_value "$card" 'WSA WSA_AIF_VI Mixer WSA_SPKR_VI_2')"

    say "----- DAI / kernel evidence -----"
    dmesg 2>/dev/null | grep -E 'A14 WSA|WSA VI Protection|SPKR_VI|SoundWire VI' | tail -n 160 || true
    say "----- SoundWire devices -----"
    find /sys/bus/soundwire/devices -maxdepth 1 -mindepth 1 -printf '%f\n' 2>/dev/null | sort || true

    if dmesg 2>/dev/null | grep -Fq 'A14 WSA VI feedback prepared on WSA_CODEC_DMA_TX_0'; then
        say "A14_SPEAKER_PROTECTION_V1_TRANSPORT=READY"
        say "next_stage=AudioReach_SP_SPVI_A14_calibration"
    else
        say "A14_SPEAKER_PROTECTION_V1_TRANSPORT=NOT_YET_PROVEN"
        say "gain_unlock=REFUSED"
        say "Collect this output plus dmesg; do not remove the safety caps."
    fi
}

status_kernel(){
    say "A14_SPEAKER_PROTECTION_V1_STATUS"
    say "running_kernel=$(uname -r)"
    say "expected_kernel=$EXPECTED_KREL"
    say "source=$SRC"
    say "build_dir=$OUT"
    say "image=$([[ -f /boot/vmlinuz-$EXPECTED_KREL ]] && echo installed || echo absent)"
    say "dtb=$([[ -f "$DTB_INSTALL_DIR/$EXPECTED_KREL.dtb" ]] && echo installed || echo absent)"
    say "grub_entry=$([[ -f "$GRUB_SNIPPET" ]] && echo installed || echo absent)"
    say "v1_policy=VISENSE_transport_only;gain_caps_preserved"
}

remove_kernel(){
    need_root
    [[ "$(uname -r)" != "$EXPECTED_KREL" ]] || die "boot a known-good kernel before removing $EXPECTED_KREL"
    rm -f "/boot/vmlinuz-$EXPECTED_KREL" "/boot/System.map-$EXPECTED_KREL" "/boot/config-$EXPECTED_KREL" "/boot/initrd.img-$EXPECTED_KREL"
    rm -rf "/lib/modules/$EXPECTED_KREL" "$DTB_INSTALL_DIR/$EXPECTED_KREL.dtb"
    rm -f "$GRUB_SNIPPET"
    update-grub
    say "A14_SPEAKER_PROTECTION_V1_REMOVED=1"
}

case "$ACTION" in
    prepare) prepare_source;;
    build) build_kernel;;
    install) install_kernel;;
    audit) audit_kernel;;
    status) status_kernel;;
    remove|restore) remove_kernel;;
    *) die "usage: $0 {prepare|build|install|audit|status|remove}";;
esac
