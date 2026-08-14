#!/usr/bin/env python3
"""Build/install GNOME 50.x patches that make the stock Power Mode UI understand
all five ASUS Zenbook A14 profiles.

This intentionally patches the distro GNOME Shell and Control Center sources
instead of adding another fake settings panel. It keeps one Power Mode tile
and one Power Mode section, both backed by org.freedesktop.UPower.PowerProfiles.
"""

from __future__ import annotations

import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
WORK = Path.home() / "Downloads" / "a14-gnome-five-profile-build"
SHELL_PATCH = REPO / "userspace/gnome/patches/gnome-shell-50-a14-five-profiles.patch"
CC_PATCH = REPO / "userspace/gnome/patches/gnome-control-center-50-a14-five-profiles.patch"
ICON_DIR = REPO / "userspace/gnome/icons"
TARGET_PACKAGES = {
    "gnome-shell",
    "gnome-shell-common",
    "gnome-control-center",
    "gnome-control-center-data",
}


def run(argv: list[str], *, cwd: Path | None = None, check: bool = True,
        capture: bool = False) -> subprocess.CompletedProcess[str]:
    print("+ " + " ".join(shlex.quote(x) for x in argv), flush=True)
    return subprocess.run(
        argv,
        cwd=str(cwd) if cwd else None,
        text=True,
        check=check,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )


def output(argv: list[str], *, cwd: Path | None = None) -> str:
    p = run(argv, cwd=cwd, capture=True)
    return (p.stdout or "").strip()


def require(cmd: str) -> None:
    if shutil.which(cmd) is None:
        raise RuntimeError(f"missing required command: {cmd}")


def version_major(text: str) -> int | None:
    m = re.search(r"(?:^|\s)(\d+)(?:\.\d+)", text)
    return int(m.group(1)) if m else None


def find_source(prefix: str) -> Path:
    candidates = [
        p for p in WORK.glob(prefix + "-*")
        if p.is_dir() and (p / "debian/changelog").exists()
    ]
    if not candidates:
        raise RuntimeError(f"apt source did not create a {prefix}-* source directory")
    return max(candidates, key=lambda p: p.stat().st_mtime)


def patch_source(src: Path, patch_file: Path) -> None:
    reverse = subprocess.run(
        ["patch", "-p1", "--dry-run", "-R", "-i", str(patch_file)],
        cwd=src,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if reverse.returncode == 0:
        print(f"patch_current={patch_file.name}")
        return

    dry = subprocess.run(
        ["patch", "-p1", "--dry-run", "--forward", "-i", str(patch_file)],
        cwd=src,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if dry.returncode != 0:
        print(dry.stdout or "", file=sys.stderr)
        raise RuntimeError(f"patch does not apply cleanly: {patch_file.name}")
    run(["patch", "-p1", "--forward", "-i", str(patch_file)], cwd=src)


def localize_version(src: Path) -> None:
    version = output(["dpkg-parsechangelog", "-S", "Version"], cwd=src)
    if "+a14" in version:
        print(f"local_version=current:{version}")
        return
    distribution = output(["dpkg-parsechangelog", "-S", "Distribution"], cwd=src) or "UNRELEASED"
    new_version = version + "+a14.1"
    env = os.environ.copy()
    env.setdefault("DEBFULLNAME", "ASUS Zenbook A14 Linux support")
    env.setdefault("DEBEMAIL", "omerfaruknehir@gmail.com")
    print(f"+ dch --newversion {new_version} ...", flush=True)
    subprocess.run(
        ["dch", "--newversion", new_version, "--distribution", distribution,
         "ASUS Zenbook A14 five-profile Power Mode support."],
        cwd=src,
        env=env,
        check=True,
    )


def build_source(src: Path) -> None:
    jobs = str(max(1, os.cpu_count() or 1))
    run(["dpkg-buildpackage", "-b", "-uc", "-us", "-j" + jobs], cwd=src)


def package_name(deb: Path) -> str:
    try:
        return output(["dpkg-deb", "-f", str(deb), "Package"])
    except subprocess.CalledProcessError:
        return ""


def install_icons() -> None:
    dest = Path("/usr/share/icons/hicolor/scalable/status")
    run(["sudo", "install", "-d", "-m", "0755", str(dest)])
    for icon in (
        ICON_DIR / "a14-power-profile-quiet-symbolic.svg",
        ICON_DIR / "a14-power-profile-full-speed-symbolic.svg",
    ):
        run(["sudo", "install", "-m", "0644", str(icon), str(dest / icon.name)])
    if shutil.which("gtk-update-icon-cache"):
        run(["sudo", "gtk-update-icon-cache", "-f", "-t", "/usr/share/icons/hicolor"], check=False)


def main() -> int:
    for cmd in (
        "gnome-shell", "gnome-control-center", "apt-get", "dpkg-buildpackage",
        "dpkg-parsechangelog", "dpkg-deb", "patch", "dch", "sudo",
    ):
        require(cmd)

    shell_version = output(["gnome-shell", "--version"])
    cc_version = output(["gnome-control-center", "--version"])
    print(f"gnome_shell={shell_version}")
    print(f"gnome_control_center={cc_version}")

    if version_major(shell_version) != 50 or version_major(cc_version) != 50:
        raise RuntimeError("the current source patches are intentionally pinned to GNOME 50.x")

    if not SHELL_PATCH.is_file() or not CC_PATCH.is_file():
        raise RuntimeError("GNOME patch payload is missing from the repository")

    # Always start from freshly unpacked distro sources. A failed previous build
    # must never leave a half-patched source tree that changes the next result.
    if WORK.exists():
        shutil.rmtree(WORK)
    WORK.mkdir(parents=True, exist_ok=True)

    # Building distro sources is deliberate here: Shell imports powerProfiles.js
    # from resource:/// and Control Center compiles the profile enum into its
    # binary, so dropping replacement files under /usr/share is not sufficient.
    run(["sudo", "apt-get", "build-dep", "-y", "gnome-shell", "gnome-control-center"])
    run(["apt-get", "source", "gnome-shell", "gnome-control-center"], cwd=WORK)

    shell_src = find_source("gnome-shell")
    cc_src = find_source("gnome-control-center")
    print(f"gnome_shell_source={shell_src}")
    print(f"gnome_control_center_source={cc_src}")

    patch_source(shell_src, SHELL_PATCH)
    patch_source(cc_src, CC_PATCH)
    localize_version(shell_src)
    localize_version(cc_src)

    build_source(shell_src)
    build_source(cc_src)
    install_icons()

    debs: list[Path] = []
    for deb in sorted(WORK.glob("*.deb")):
        pkg = package_name(deb)
        if pkg in TARGET_PACKAGES:
            debs.append(deb)
            print(f"install_candidate={pkg}:{deb.name}")

    found = {package_name(d) for d in debs}
    required = {"gnome-shell", "gnome-shell-common", "gnome-control-center"}
    missing = required - found
    if missing:
        raise RuntimeError("missing built packages: " + ", ".join(sorted(missing)))

    run(["sudo", "apt-get", "install", "-y", *[str(d) for d in debs]])

    # The former A14 extension is now obsolete: patched stock GNOME Shell owns
    # the single Power Mode tile. Disable it in the current user session.
    if shutil.which("gnome-extensions"):
        run(["gnome-extensions", "disable", "asus-a14-modes@omerfaruknehir"], check=False)

    run(["sudo", "systemctl", "restart", "asus-zenbook-a14-ppd-bridge.service"], check=False)

    print("A14_GNOME_NATIVE_FIVE_PROFILE_INSTALL=PASS")
    print("logout_login_required=true")
    print("note=Wayland GNOME Shell must restart to load its rebuilt resource bundle")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"A14_GNOME_NATIVE_FIVE_PROFILE_INSTALL=FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
