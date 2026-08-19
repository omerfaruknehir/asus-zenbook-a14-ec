#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Install only the one proven-broken runtime dependency needed by msm.ko on
# the ACPI kernel: mdt_loader.ko rebuilt against the current SCM-enabled Image.
set -euo pipefail

ACTION="${1:-status}"
KREL="7.1.5-a14-acpi-full0"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
WORK="${A14_74C9_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
OUT="$WORK/build"
BUILT="$OUT/drivers/soc/qcom/mdt_loader.ko"
STAMP="$WORK/gpu0-topology-v3.ready"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "install/restore requires sudo/root"; }

installed_path(){
    local p
    p="$(modinfo -k "$KREL" -n mdt_loader 2>/dev/null || true)"
    [[ -n "$p" && "$p" != builtin ]] || return 1
    readlink -f "$p"
}

verify_target(){
    local target="$1" root
    root="$(readlink -f "/lib/modules/$KREL")"
    [[ -n "$root" && -d "$root" ]] || die "cannot canonicalize module root"
    case "$target" in "$root"/*) ;; *) die "unexpected mdt_loader path: $target" ;; esac
}

pack_like(){
    local target="$1" src="$2" out="$3"
    case "$target" in
        *.ko) cp -f "$src" "$out" ;;
        *.ko.zst) need zstd; zstd -q -f -19 "$src" -o "$out" ;;
        *.ko.xz) need xz; xz -c -f "$src" >"$out" ;;
        *.ko.gz) need gzip; gzip -c -f "$src" >"$out" ;;
        *) die "unsupported mdt_loader compression: $target" ;;
    esac
}

install_fix(){
    need_root
    for c in modinfo readlink cp install depmod awk sha256sum; do need "$c"; done
    [[ "$(uname -r)" != "$KREL" ]] || die "boot normal DT kernel before replacing ACPI module"
    [[ -s "$BUILT" ]] || die "rebuilt mdt_loader.ko missing; V4 build must complete first"
    [[ -r "$STAMP" ]] || die "successful topology build stamp missing"

    local vermagic target backup suffix packed sha
    vermagic="$(modinfo -F vermagic "$BUILT" | awk '{print $1}')"
    [[ "$vermagic" == "$KREL" ]] || die "mdt_loader vermagic mismatch: $vermagic"
    target="$(installed_path)" || die "cannot locate installed mdt_loader for $KREL"
    verify_target "$target"
    backup="$target.pre-gpu0-topology-v4-scm-sync"
    [[ -e "$backup" ]] || cp -a "$target" "$backup"

    suffix="${target##*mdt_loader.ko}"
    packed="$WORK/mdt_loader.ko.gpu0-v4.install${suffix}"
    rm -f "$packed"
    pack_like "$target" "$BUILT" "$packed"
    install -m0644 "$packed" "$target"
    rm -f "$packed"
    depmod -a "$KREL"

    sha="$(sha256sum "$BUILT" | awk '{print $1}')"
    say "A14_GPU0_RUNTIME_DEPS_INSTALL=COMPLETE"
    say "reason=known_qcom_scm_pas_init_image_modversion_mismatch"
    say "installed_module=mdt_loader"
    say "installed_source_sha256=$sha"
    say "installed_path=$target"
    say "previous_module=$backup"
    say "other_dependency_modules_unchanged=true"
    say "depmod_updated=true"
    say "rebuild_required=false"
}

restore_fix(){
    need_root
    for c in modinfo readlink cp depmod; do need "$c"; done
    [[ "$(uname -r)" != "$KREL" ]] || die "boot normal DT kernel before restore"
    local target backup
    target="$(installed_path)" || die "cannot locate installed mdt_loader"
    verify_target "$target"
    backup="$target.pre-gpu0-topology-v4-scm-sync"
    [[ -s "$backup" ]] || die "mdt_loader backup missing"
    cp -a "$backup" "$target"
    depmod -a "$KREL"
    say "A14_GPU0_RUNTIME_DEPS_RESTORE=COMPLETE"
}

status_fix(){
    local target=""
    say "running_kernel=$(uname -r)"
    say "built_mdt_loader=$BUILT"
    if [[ -s "$BUILT" ]]; then
        say "built_vermagic=$(modinfo -F vermagic "$BUILT" 2>/dev/null | awk '{print $1}')"
    fi
    if target="$(installed_path 2>/dev/null)"; then
        say "installed_mdt_loader=$target"
        [[ -e "$target.pre-gpu0-topology-v4-scm-sync" ]] && say "backup_present=true" || say "backup_present=false"
    fi
}

case "$ACTION" in
    install) install_fix ;;
    restore) restore_fix ;;
    status) status_fix ;;
    *) die "usage: $0 {install|restore|status}" ;;
esac
