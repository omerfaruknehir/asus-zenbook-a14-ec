#!/usr/bin/env bash
set -euo pipefail

MESA_VERSION="${A14_MESA_VERSION:-26.2.0}"
PREFIX="/usr/local"
MULTIARCH="aarch64-linux-gnu"
LIBDIR="lib/${MULTIARCH}"
STATE_DIR="/var/lib/asus-zenbook-a14-ec/mesa"
STATE_FILE="${STATE_DIR}/manifest-${MESA_VERSION}.txt"
LD_CONF="/etc/ld.so.conf.d/00-a14-mesa.conf"
VK_OVERRIDE="/etc/vulkan/icd.d/50_a14_turnip.json"
WORK_ROOT="${A14_MESA_WORKDIR:-/var/tmp/a14-mesa-${MESA_VERSION}}"
ARCHIVE="mesa-${MESA_VERSION}.tar.xz"
ARCHIVE_URL="https://archive.mesa3d.org/${ARCHIVE}"
SIG_URL="${ARCHIVE_URL}.sig"
KEYS_URL="https://docs.mesa3d.org/release-maintainers-keys.asc"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

require_host() {
    [ "$(uname -m)" = "aarch64" ] || die "This updater is intentionally limited to the A14 ARM64 host."
    [ -r /etc/os-release ] || die "Cannot identify the distribution."
    # shellcheck disable=SC1091
    . /etc/os-release
    [ "${ID:-}" = "ubuntu" ] || die "Expected Ubuntu, found ${ID:-unknown}."
    [ "${VERSION_ID:-}" = "26.04" ] || die "Expected Ubuntu 26.04, found ${VERSION_ID:-unknown}."
}

ensure_deb_src() {
    if apt-cache showsrc mesa >/dev/null 2>&1; then
        return 0
    fi

    local ubuntu_sources=/etc/apt/sources.list.d/ubuntu.sources
    [ -r "$ubuntu_sources" ] || die "Mesa source metadata is unavailable and $ubuntu_sources is missing."

    local tmp
    tmp=$(mktemp)
    sed -E 's/^Types:[[:space:]]*deb[[:space:]]*$/Types: deb deb-src/' "$ubuntu_sources" >"$tmp"
    sudo install -m 0644 "$tmp" /etc/apt/sources.list.d/a14-mesa-build-deps.sources
    rm -f "$tmp"
    sudo apt-get update

    apt-cache showsrc mesa >/dev/null 2>&1 || die "Could not enable Ubuntu source metadata for Mesa build dependencies."
}

install_build_deps() {
    sudo apt-get update
    sudo apt-get install -y \
        build-essential ca-certificates curl gnupg xz-utils \
        meson ninja-build pkg-config \
        python3-mako python3-packaging python3-yaml \
        bison flex mesa-utils vulkan-tools
    ensure_deb_src
    sudo apt-get build-dep -y mesa
}

verify_release() {
    local gnupg="$WORK_ROOT/gnupg"
    rm -rf "$gnupg"
    mkdir -m 0700 -p "$gnupg"
    curl -fL --retry 3 -o "$WORK_ROOT/$ARCHIVE" "$ARCHIVE_URL"
    curl -fL --retry 3 -o "$WORK_ROOT/$ARCHIVE.sig" "$SIG_URL"
    curl -fL --retry 3 -o "$WORK_ROOT/release-maintainers-keys.asc" "$KEYS_URL"
    gpg --homedir "$gnupg" --batch --import "$WORK_ROOT/release-maintainers-keys.asc" >/dev/null 2>&1
    gpg --homedir "$gnupg" --batch --verify "$WORK_ROOT/$ARCHIVE.sig" "$WORK_ROOT/$ARCHIVE"
}

stage_paths() {
    STAGE_PREFIX="$WORK_ROOT/stage$PREFIX"
    STAGE_LIB="$STAGE_PREFIX/$LIBDIR"
    STAGE_DRI="$STAGE_LIB/dri/msm_dri.so"
    STAGE_TURNIP="$STAGE_LIB/libvulkan_freedreno.so"
    STAGE_EGL="$STAGE_LIB/libEGL_mesa.so.0"
    STAGE_GBM="$STAGE_LIB/libgbm.so.1"
}

stage_ready() {
    stage_paths
    [ -e "$STAGE_DRI" ] && \
    [ -f "$STAGE_TURNIP" ] && \
    [ -e "$STAGE_EGL" ] && \
    [ -e "$STAGE_GBM" ]
}

validate_stage() {
    stage_paths
    [ -e "$STAGE_DRI" ] || die "Mesa stage does not contain a usable msm_dri.so"
    [ -f "$STAGE_TURNIP" ] || die "Mesa stage does not contain Turnip libvulkan_freedreno.so"
    [ -e "$STAGE_EGL" ] || die "Mesa stage does not contain libEGL_mesa.so.0"
    [ -e "$STAGE_GBM" ] || die "Mesa stage does not contain libgbm.so.1"

    # Mesa 26.2's Gallium DRIL install intentionally makes msm_dri.so a symlink
    # to libdril_dri.so. `find -type f` therefore rejects a perfectly valid
    # build. Follow the link instead and make sure the resulting object exists.
    if [ -L "$STAGE_DRI" ]; then
        local target
        target=$(readlink "$STAGE_DRI")
        [ -n "$target" ] || die "Mesa msm_dri.so symlink has an empty target"
        say "Mesa DRI stage: msm_dri.so -> $target"
    fi
}

build_mesa() {
    local src="$WORK_ROOT/mesa-$MESA_VERSION"
    local build="$WORK_ROOT/build"
    local stage="$WORK_ROOT/stage"

    rm -rf "$src" "$build" "$stage"
    tar -C "$WORK_ROOT" -xf "$WORK_ROOT/$ARCHIVE"

    meson setup "$build" "$src" \
        --prefix="$PREFIX" \
        --libdir="$LIBDIR" \
        -Dplatforms=x11,wayland \
        -Dgallium-drivers=freedreno \
        -Dvulkan-drivers=freedreno \
        -Dfreedreno-kmds=msm \
        -Dglvnd=enabled \
        -Degl=enabled \
        -Dgbm=enabled \
        -Dgles1=enabled \
        -Dgles2=enabled \
        -Dopengl=true \
        -Dllvm=disabled

    meson compile -C "$build" -j"$(nproc)"
    mkdir -p "$stage"
    DESTDIR="$stage" meson install -C "$build"
    validate_stage
}

remove_previous_custom() {
    if [ ! -r "$STATE_FILE" ]; then
        return 0
    fi
    say "Removing the previous A14 Mesa ${MESA_VERSION} /usr/local install first..."
    tac "$STATE_FILE" | while IFS= read -r path; do
        case "$path" in
            /usr/local/*) sudo rm -f -- "$path" ;;
        esac
    done
    sudo rm -f "$VK_OVERRIDE" "$LD_CONF"
    sudo ldconfig
    sudo rm -f "$STATE_FILE"
}

install_stage() {
    local stage="$WORK_ROOT/stage"
    local stage_prefix="$stage$PREFIX"
    [ -d "$stage_prefix" ] || die "Staged /usr/local tree is missing."
    validate_stage

    remove_previous_custom

    local manifest="$WORK_ROOT/install-manifest.txt"
    find "$stage_prefix" \( -type f -o -type l \) -printf '/usr/local/%P\n' | sort -u >"$manifest"
    [ -s "$manifest" ] || die "Mesa staging manifest is empty."

    while IFS= read -r path; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            die "Refusing to overwrite a pre-existing /usr/local file: $path"
        fi
    done <"$manifest"

    sudo mkdir -p "$STATE_DIR"
    sudo cp -a "$stage_prefix/." "$PREFIX/"
    sudo install -m 0644 "$manifest" "$STATE_FILE"

    printf '%s\n' "$PREFIX/$LIBDIR" | sudo tee "$LD_CONF" >/dev/null

    local vk_json
    vk_json=$(find "$stage_prefix/share/vulkan/icd.d" -maxdepth 1 -type f -name '*freedreno*.json' -print -quit 2>/dev/null || true)
    if [ -n "$vk_json" ]; then
        sudo mkdir -p /etc/vulkan/icd.d
        sudo install -m 0644 "$vk_json" "$VK_OVERRIDE"
    fi

    sudo ldconfig
}

status() {
    require_host
    say "Packaged Mesa:"
    dpkg-query -W -f='${Package}\t${Version}\n' libegl-mesa0 libgbm1 libgl1-mesa-dri mesa-vulkan-drivers 2>/dev/null || true
    say
    say "Active OpenGL renderer:"
    glxinfo -B 2>/dev/null | grep -E 'OpenGL vendor|OpenGL renderer|OpenGL (core profile )?version' || true
    say
    say "Active Vulkan driver:"
    vulkaninfo --summary 2>/dev/null | grep -E 'driverName|driverInfo|deviceName|apiVersion' | head -n 20 || true
    say
    if [ -r "$STATE_FILE" ]; then
        say "A14 Mesa ${MESA_VERSION}: installed under /usr/local"
    else
        say "A14 Mesa ${MESA_VERSION}: no managed /usr/local install recorded"
    fi
}

rollback() {
    require_host
    [ -r "$STATE_FILE" ] || die "No managed Mesa ${MESA_VERSION} install is recorded."
    tac "$STATE_FILE" | while IFS= read -r path; do
        case "$path" in
            /usr/local/*) sudo rm -f -- "$path" ;;
        esac
    done
    sudo rm -f "$VK_OVERRIDE" "$LD_CONF"
    sudo ldconfig
    sudo rm -f "$STATE_FILE"
    say "Mesa ${MESA_VERSION} override removed. Ubuntu's packaged Mesa will be used after a full logout/login."
}

install() {
    require_host
    mkdir -p "$WORK_ROOT"

    # A previous run may have completed all 1505 build targets and only failed
    # the old regular-file-only msm_dri.so check. Reuse that complete staged
    # tree instead of burning time recompiling it.
    if stage_ready; then
        say "Found a complete staged Mesa ${MESA_VERSION} build; reusing it."
        validate_stage
    else
        install_build_deps
        verify_release
        build_mesa
    fi

    install_stage
    say
    say "Mesa ${MESA_VERSION} Freedreno + Turnip installed under /usr/local."
    say "Ubuntu's packaged Mesa was not overwritten."
    say "Log out completely and log back in before judging GNOME/Wayland performance."
    say "Then run: $0 status"
    say "Rollback: $0 rollback"
}

case "${1:-install}" in
    install) install ;;
    status) status ;;
    rollback) rollback ;;
    *) die "Usage: $0 [install|status|rollback]" ;;
esac
