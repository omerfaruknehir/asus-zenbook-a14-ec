#!/bin/sh

# Read-only diagnostic capture for intermittent GNOME Shell rendering corruption
# on the ASUS Zenbook A14. Run while corruption is visible, before logging out.

out=${1:-"$HOME/Downloads/a14-gnome-gpu-corruption-diag.txt"}
mkdir -p "$(dirname -- "$out")" 2>/dev/null || true

section() {
    printf '\n===== %s =====\n' "$1"
}

run() {
    printf '+ %s\n' "$*"
    "$@" 2>&1 || true
}

{
    section "CAPTURE"
    date --iso-8601=seconds 2>/dev/null || date
    printf 'output=%s\n' "$out"

    section "SYSTEM"
    run uname -a
    if [ -r /etc/os-release ]; then
        cat /etc/os-release
    fi
    printf 'XDG_SESSION_TYPE=%s\n' "${XDG_SESSION_TYPE:-}"
    printf 'XDG_CURRENT_DESKTOP=%s\n' "${XDG_CURRENT_DESKTOP:-}"
    printf 'WAYLAND_DISPLAY=%s\n' "${WAYLAND_DISPLAY:-}"

    section "GNOME / MUTTER"
    run gnome-shell --version
    run dpkg-query -W -f='${Package}\t${Version}\n' gnome-shell gnome-shell-common mutter libmutter-14-0 libmutter-15-0 libmutter-16-0 libmutter-17-0 libmutter-18-0 libmutter-19-0 libmutter-20-0 2>/dev/null
    if command -v gnome-extensions >/dev/null 2>&1; then
        printf '%s\n' '-- enabled extensions --'
        gnome-extensions list --enabled 2>&1 || true
    fi
    if command -v gsettings >/dev/null 2>&1; then
        printf '%s\n' '-- mutter settings --'
        gsettings list-recursively org.gnome.mutter 2>&1 || true
        printf '%s\n' '-- shell settings --'
        gsettings get org.gnome.shell enabled-extensions 2>&1 || true
    fi

    section "MESA / RENDERER"
    run dpkg-query -W -f='${Package}\t${Version}\n' libgl1-mesa-dri libegl-mesa0 libgbm1 mesa-vulkan-drivers mesa-utils 2>/dev/null
    if command -v glxinfo >/dev/null 2>&1; then
        glxinfo -B 2>&1 || true
    fi
    if command -v eglinfo >/dev/null 2>&1; then
        eglinfo -B 2>&1 || true
    fi
    printf '%s\n' '-- relevant environment --'
    env | grep -E '^(MESA|LIBGL|EGL|GBM|DRI|FD_|TU_|IR3_|MUTTER|CLUTTER|COGL)=' || true

    section "DRM DEVICES"
    ls -l /dev/dri 2>&1 || true
    for uevent in /sys/class/drm/card*/device/uevent; do
        [ -r "$uevent" ] || continue
        printf '%s\n' "--- $uevent"
        cat "$uevent" 2>&1 || true
    done

    section "GPU DEVFREQ"
    for d in /sys/class/devfreq/*; do
        [ -d "$d" ] || continue
        name=$(basename -- "$d")
        case "$name" in
            *gpu*|*adreno*|*3d*) ;;
            *) continue ;;
        esac
        printf '%s\n' "--- $d"
        for f in name governor cur_freq min_freq max_freq available_frequencies; do
            [ -r "$d/$f" ] || continue
            printf '%s=' "$f"
            cat "$d/$f" 2>/dev/null || true
        done
    done

    section "KERNEL GPU / DRM LOG"
    journalctl -k -b --no-pager 2>&1 | grep -Ei 'drm|msm|gpu|adreno|freedreno|iommu|smmu|uche|fault|hang|timeout|recover|reset|fence|gmu|a[0-9]+xx' || true

    section "GNOME SHELL / MUTTER LOG"
    journalctl -b --no-pager 2>&1 | grep -Ei 'gnome-shell|mutter|cogl|clutter|egl|opengl|gles|freedreno|adreno|msm|gpu|texture|shader|render|framebuffer|dma-buf|dmabuf' || true

    section "DEVCOREDUMP INVENTORY"
    found=false
    for d in /sys/class/devcoredump/devcd*; do
        [ -e "$d" ] || continue
        found=true
        printf '%s\n' "--- $d"
        ls -l "$d" 2>&1 || true
        [ -r "$d/uevent" ] && cat "$d/uevent" 2>&1 || true
        [ -e "$d/data" ] && stat "$d/data" 2>&1 || true
    done
    [ "$found" = true ] || printf '%s\n' 'none'

    section "MSM DEBUGFS INVENTORY"
    if [ -d /sys/kernel/debug/dri ]; then
        find /sys/kernel/debug/dri -maxdepth 2 -type f \( -name show -o -name state -o -name clients -o -name gem_names \) -print 2>/dev/null || true
    else
        printf '%s\n' '/sys/kernel/debug/dri unavailable (debugfs may not be mounted or readable)'
    fi

    section "A14 PROFILE"
    if command -v asus-a14-control >/dev/null 2>&1; then
        asus-a14-control status 2>&1 || true
    fi

    section "END"
    date --iso-8601=seconds 2>/dev/null || date
} >"$out"

printf 'A14 GNOME/GPU corruption diagnostic saved to: %s\n' "$out"
