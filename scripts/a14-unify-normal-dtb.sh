#!/bin/sh

# Promote the already hardware-tested A14 RGB+IR DTB to the normal DTB path.
# This keeps the existing kernel/initrd/cmdline and therefore does not require
# a custom kernel or GRUB kernel entry.  The previous normal DTB is retained as
# a timestamped backup for rollback.

kernel=$(uname -r)
normal="/boot/dtb-$kernel"
camera="/boot/dtb-$kernel-a14-camera"
tmp="${TMPDIR:-/tmp}/a14-unify-dtb-$$"
ok=1
stamp=$(date +%Y%m%d-%H%M%S)
backup="$normal.before-a14-unified-$stamp"

say()
{
    printf '%s\n' "$*"
}

case "$kernel" in
    7.1.5-070105-generic) ;;
    *)
        say "ERROR: this validator/promoter is pinned to 7.1.5-070105-generic; running=$kernel"
        ok=0
        ;;
esac

if [ "$ok" -eq 1 ] && [ ! -r "$normal" ]; then
    say "ERROR: normal DTB missing: $normal"
    ok=0
fi
if [ "$ok" -eq 1 ] && [ ! -r "$camera" ]; then
    say "ERROR: RGB+IR DTB missing: $camera"
    ok=0
fi
if [ "$ok" -eq 1 ] && ! command -v dtc >/dev/null 2>&1; then
    say "ERROR: dtc is required for semantic validation"
    ok=0
fi

if [ "$ok" -eq 1 ]; then
    mkdir -p "$tmp" || ok=0
fi

if [ "$ok" -eq 1 ]; then
    say "===== DTB INPUT ====="
    say "kernel=$kernel"
    say "normal=$normal"
    say "camera=$camera"
    sha256sum "$normal" "$camera" 2>/dev/null || ok=0
fi

if [ "$ok" -eq 1 ]; then
    dtc -I dtb -O dts -s -o "$tmp/normal.dts" "$normal" 2>"$tmp/normal.warn"
    nrc=$?
    dtc -I dtb -O dts -s -o "$tmp/camera.dts" "$camera" 2>"$tmp/camera.warn"
    crc=$?
    say "normal_dtc_rc=$nrc"
    say "camera_dtc_rc=$crc"
    if [ "$nrc" -ne 0 ] || [ "$crc" -ne 0 ]; then
        ok=0
    fi
fi

if [ "$ok" -eq 1 ]; then
    say "===== RGB+IR SEMANTIC CHECK ====="
    for token in \
        'model = "ASUS Zenbook A14 (UX3407RA)"' \
        'asus,zenbook-a14-ux3407ra' \
        'qcom,x1e80100-camss' \
        'qcom,x1e80100-cci' \
        'ovti,ov02c10' \
        'himax,hm1092'
    do
        if grep -Fq "$token" "$tmp/camera.dts"; then
            say "PASS: $token"
        else
            say "ERROR: RGB+IR DTB missing semantic token: $token"
            ok=0
        fi
    done
fi

if [ "$ok" -eq 1 ]; then
    say "===== DELTA SUMMARY ====="
    diff -u "$tmp/normal.dts" "$tmp/camera.dts" >"$tmp/delta.diff" 2>/dev/null || true
    added=$(grep -c '^+' "$tmp/delta.diff" 2>/dev/null || true)
    removed=$(grep -c '^-' "$tmp/delta.diff" 2>/dev/null || true)
    say "decompiled_added_lines=${added:-0}"
    say "decompiled_removed_lines=${removed:-0}"
    say "camera_nodes_present=true"
fi

if [ "$ok" -eq 1 ]; then
    nhash=$(sha256sum "$normal" | awk '{print $1}')
    chash=$(sha256sum "$camera" | awk '{print $1}')
    if [ "$nhash" = "$chash" ]; then
        say "normal_dtb_already_unified=true"
    else
        say "===== INSTALL UNIFIED NORMAL DTB ====="
        if sudo cp -a "$normal" "$backup"; then
            say "backup=$backup"
        else
            say "ERROR: failed to back up normal DTB"
            ok=0
        fi

        if [ "$ok" -eq 1 ]; then
            if sudo install -m 0644 "$camera" "$normal"; then
                say "normal_dtb_replaced=true"
            else
                say "ERROR: failed to install RGB+IR DTB at normal path"
                ok=0
            fi
        fi
    fi
fi

if [ "$ok" -eq 1 ]; then
    say "===== VERIFY INSTALLED HASH ====="
    sha256sum "$normal" "$camera" 2>/dev/null
    nhash=$(sha256sum "$normal" | awk '{print $1}')
    chash=$(sha256sum "$camera" | awk '{print $1}')
    if [ "$nhash" != "$chash" ]; then
        say "ERROR: normal and RGB+IR DTB hashes differ after install"
        ok=0
    else
        say "normal_matches_rgb_ir=true"
    fi
fi

if [ "$ok" -eq 1 ]; then
    say "===== GRUB ====="
    if command -v update-grub >/dev/null 2>&1; then
        sudo update-grub
        grc=$?
        say "update_grub_rc=$grc"
        if [ "$grc" -ne 0 ]; then
            ok=0
        fi
    else
        say "update_grub=unavailable"
    fi
fi

rm -rf "$tmp" 2>/dev/null || true

say ""
if [ "$ok" -eq 1 ]; then
    say "A14_NORMAL_DTB_UNIFICATION=PASS"
    say "reboot_required=true"
    say "normal_boot_now_uses_rgb_ir_feature_dtb=true"
    if [ -e "$backup" ]; then
        say "rollback_backup=$backup"
    fi
else
    say "A14_NORMAL_DTB_UNIFICATION=FAIL"
    say "normal_boot_change_incomplete=true"
fi

true
