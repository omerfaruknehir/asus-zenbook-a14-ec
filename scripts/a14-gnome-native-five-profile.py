#!/usr/bin/env python3
"""Build/install narrowly-scoped GNOME 50.x A14 five-mode UI changes.

The kernel-facing A14 vocabulary is:

    Whisper / Quiet / Normal / Turbo / Full Speed

The PPD bridge uses standard internal names where possible so generic software
continues to work:

    power-saver -> Whisper
    quiet       -> Quiet
    balanced    -> Normal
    performance -> Turbo
    full-speed  -> Full Speed

Stock GNOME 50 filters unknown profile names and labels the standard three with
stock names. This builder patches only the distro GNOME Shell and Control Center
profile presentation so the existing Power Mode controls expose the five A14
modes with the correct names. Settings keeps its stock icon-free row styling;
Quick Settings keeps profile icons.
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
ICON_DIR = REPO / "userspace/gnome/icons"
NATIVE_UI_MARKER = Path("/usr/share/asus-zenbook-a14-ec/native-gnome-five-profile")
EXTENSION_UUID = "asus-a14-modes@omerfaruknehir"
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


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        print(f"semantic_edit_current={label}")
        return text
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one source anchor, found {count}")
    print(f"semantic_edit_applied={label}")
    return text.replace(old, new, 1)


def patch_shell_semantic(src: Path) -> None:
    path = src / "js/ui/status/powerProfiles.js"
    s = path.read_text(encoding="utf-8")

    s = replace_once(
        s,
        """const PROFILE_PARAMS = {\n    'performance': {\n""",
        """const PROFILE_PARAMS = {\n    'full-speed': {\n        name: C_('Power profile', 'Full Speed'),\n        iconName: 'a14-power-profile-full-speed-symbolic',\n    },\n\n    'performance': {\n""",
        "shell-full-speed-profile",
    )
    s = replace_once(
        s,
        """    'power-saver': {\n        name: C_('Power profile', 'Power Saver'),\n        iconName: 'power-profile-power-saver-symbolic',\n    },\n};\n""",
        """    'power-saver': {\n        name: C_('Power profile', 'Power Saver'),\n        iconName: 'power-profile-power-saver-symbolic',\n    },\n\n    'quiet': {\n        name: C_('Power profile', 'Quiet'),\n        iconName: 'a14-power-profile-quiet-symbolic',\n    },\n};\n""",
        "shell-quiet-profile",
    )

    # Keep PPD wire names standard while presenting the actual A14 modes.
    replacements = (
        ("name: C_('Power profile', 'Performance')", "name: C_('Power profile', 'Turbo')", "shell-turbo-label"),
        ("name: C_('Power profile', 'Balanced')", "name: C_('Power profile', 'Normal')", "shell-normal-label"),
        ("name: C_('Power profile', 'Power Saver')", "name: C_('Power profile', 'Whisper')", "shell-whisper-label"),
    )
    for old, new, label in replacements:
        s = replace_once(s, old, new, label)

    required = (
        "'full-speed': {", "'performance': {", "'balanced': {",
        "'power-saver': {", "'quiet': {",
        "C_('Power profile', 'Full Speed')",
        "C_('Power profile', 'Turbo')",
        "C_('Power profile', 'Normal')",
        "C_('Power profile', 'Whisper')",
        "C_('Power profile', 'Quiet')",
        "a14-power-profile-quiet-symbolic",
        "a14-power-profile-full-speed-symbolic",
        "this._proxy.ActiveProfile = profile",
    )
    missing = [token for token in required if token not in s]
    if missing:
        raise RuntimeError("GNOME Shell A14 semantic edit incomplete: " + ", ".join(missing))

    path.write_text(s, encoding="utf-8")
    print("gnome_shell_a14_five_mode_semantic=applied")


def patch_control_center_semantic(src: Path) -> None:
    h = src / "panels/power/cc-power-profile-row.h"
    c = src / "panels/power/cc-power-profile-row.c"

    hs = h.read_text(encoding="utf-8")
    cs = c.read_text(encoding="utf-8")

    hs = replace_once(
        hs,
        """typedef enum\n{\n  CC_POWER_PROFILE_PERFORMANCE,\n  CC_POWER_PROFILE_BALANCED,\n  CC_POWER_PROFILE_POWER_SAVER,\n  NUM_CC_POWER_PROFILES,\n""",
        """typedef enum\n{\n  CC_POWER_PROFILE_FULL_SPEED,\n  CC_POWER_PROFILE_PERFORMANCE,\n  CC_POWER_PROFILE_BALANCED,\n  CC_POWER_PROFILE_POWER_SAVER,\n  CC_POWER_PROFILE_QUIET,\n  NUM_CC_POWER_PROFILES,\n""",
        "control-center-five-profile-enum",
    )

    cs = replace_once(
        cs,
        """  CcPowerProfileRow *self;\n  const char *text, *subtext;\n\n  self = g_object_new (CC_TYPE_POWER_PROFILE_ROW, NULL);\n\n  self->power_profile = power_profile;\n  switch (self->power_profile)\n    {\n      case CC_POWER_PROFILE_PERFORMANCE:\n        text = C_(\"Power profile\", \"P_erformance\");\n        subtext = _(\"High performance and power usage\");\n        break;\n      case CC_POWER_PROFILE_BALANCED:\n        text = C_(\"Power profile\", \"Ba_lanced\");\n        subtext = _(\"Standard performance and power usage\");\n        break;\n      case CC_POWER_PROFILE_POWER_SAVER:\n        text = C_(\"Power profile\", \"P_ower Saver\");\n        subtext = _(\"Reduced performance and power usage\");\n        break;\n      default:\n        g_assert_not_reached ();\n    }\n\n  adw_preferences_row_set_title (ADW_PREFERENCES_ROW (self), text);\n""",
        """  CcPowerProfileRow *self;\n  const char *text, *subtext;\n\n  self = g_object_new (CC_TYPE_POWER_PROFILE_ROW, NULL);\n\n  self->power_profile = power_profile;\n  switch (self->power_profile)\n    {\n      case CC_POWER_PROFILE_FULL_SPEED:\n        text = C_(\"Power profile\", \"_Full Speed\");\n        subtext = _(\"ASUS Full Speed firmware mode\");\n        break;\n      case CC_POWER_PROFILE_PERFORMANCE:\n        text = C_(\"Power profile\", \"_Turbo\");\n        subtext = _(\"ASUS Turbo firmware mode\");\n        break;\n      case CC_POWER_PROFILE_BALANCED:\n        text = C_(\"Power profile\", \"_Normal\");\n        subtext = _(\"ASUS Normal firmware mode\");\n        break;\n      case CC_POWER_PROFILE_POWER_SAVER:\n        text = C_(\"Power profile\", \"_Whisper\");\n        subtext = _(\"Minimum disturbance; may throttle CPU and GPU\");\n        break;\n      case CC_POWER_PROFILE_QUIET:\n        text = C_(\"Power profile\", \"_Quiet\");\n        subtext = _(\"ASUS Quiet firmware mode\");\n        break;\n      default:\n        g_assert_not_reached ();\n    }\n\n  adw_preferences_row_set_title (ADW_PREFERENCES_ROW (self), text);\n""",
        "control-center-a14-five-mode-rows",
    )

    cs = replace_once(
        cs,
        """CcPowerProfile\ncc_power_profile_from_str (const char *profile)\n{\n  if (g_strcmp0 (profile, \"power-saver\") == 0)\n    return CC_POWER_PROFILE_POWER_SAVER;\n  if (g_strcmp0 (profile, \"balanced\") == 0)\n    return CC_POWER_PROFILE_BALANCED;\n  if (g_strcmp0 (profile, \"performance\") == 0)\n    return CC_POWER_PROFILE_PERFORMANCE;\n""",
        """CcPowerProfile\ncc_power_profile_from_str (const char *profile)\n{\n  if (g_strcmp0 (profile, \"full-speed\") == 0)\n    return CC_POWER_PROFILE_FULL_SPEED;\n  if (g_strcmp0 (profile, \"power-saver\") == 0)\n    return CC_POWER_PROFILE_POWER_SAVER;\n  if (g_strcmp0 (profile, \"balanced\") == 0)\n    return CC_POWER_PROFILE_BALANCED;\n  if (g_strcmp0 (profile, \"performance\") == 0)\n    return CC_POWER_PROFILE_PERFORMANCE;\n  if (g_strcmp0 (profile, \"quiet\") == 0)\n    return CC_POWER_PROFILE_QUIET;\n""",
        "control-center-profile-from-string",
    )
    cs = replace_once(
        cs,
        """const char *\ncc_power_profile_to_str (CcPowerProfile profile)\n{\n  switch (profile)\n  {\n  case CC_POWER_PROFILE_POWER_SAVER:\n    return \"power-saver\";\n  case CC_POWER_PROFILE_BALANCED:\n    return \"balanced\";\n  case CC_POWER_PROFILE_PERFORMANCE:\n    return \"performance\";\n""",
        """const char *\ncc_power_profile_to_str (CcPowerProfile profile)\n{\n  switch (profile)\n  {\n  case CC_POWER_PROFILE_FULL_SPEED:\n    return \"full-speed\";\n  case CC_POWER_PROFILE_POWER_SAVER:\n    return \"power-saver\";\n  case CC_POWER_PROFILE_BALANCED:\n    return \"balanced\";\n  case CC_POWER_PROFILE_PERFORMANCE:\n    return \"performance\";\n  case CC_POWER_PROFILE_QUIET:\n    return \"quiet\";\n""",
        "control-center-profile-to-string",
    )

    required_h = (
        "CC_POWER_PROFILE_FULL_SPEED", "CC_POWER_PROFILE_QUIET", "NUM_CC_POWER_PROFILES",
    )
    required_c = (
        'g_strcmp0 (profile, "quiet")', 'g_strcmp0 (profile, "full-speed")',
        'return "quiet";', 'return "full-speed";',
        'C_("Power profile", "_Whisper")', 'C_("Power profile", "_Quiet")',
        'C_("Power profile", "_Normal")', 'C_("Power profile", "_Turbo")',
        'C_("Power profile", "_Full Speed")',
    )
    forbidden_c = (
        "a14-power-profile-quiet-symbolic",
        "a14-power-profile-full-speed-symbolic",
        "gtk_image_set_from_icon_name",
    )
    if any(token not in hs for token in required_h):
        raise RuntimeError("GNOME Control Center A14 enum edit incomplete")
    if any(token not in cs for token in required_c):
        raise RuntimeError("GNOME Control Center A14 row edit incomplete")
    if any(token in cs for token in forbidden_c):
        raise RuntimeError("GNOME Settings profile rows unexpectedly gained profile icons")

    h.write_text(hs, encoding="utf-8")
    c.write_text(cs, encoding="utf-8")
    print("gnome_control_center_a14_five_mode_semantic=applied")
    print("gnome_settings_profile_icons=stock-none")


def localize_version(src: Path) -> None:
    version = output(["dpkg-parsechangelog", "-S", "Version"], cwd=src)
    if "+a14.2" in version:
        print(f"local_version=current:{version}")
        return
    # apt source normally yields an unmodified distro source. If a prior +a14
    # source tree is supplied, strip only the local suffix before adding ours.
    base_version = re.sub(r"\+a14(?:\.\d+)?$", "", version)
    distribution = output(["dpkg-parsechangelog", "-S", "Distribution"], cwd=src) or "UNRELEASED"
    new_version = base_version + "+a14.2"
    env = os.environ.copy()
    env.setdefault("DEBFULLNAME", "ASUS Zenbook A14 Linux support")
    env.setdefault("DEBEMAIL", "omerfaruknehir@gmail.com")
    print(f"+ dch --newversion {new_version} ...", flush=True)
    subprocess.run(
        ["dch", "--newversion", new_version, "--distribution", distribution,
         "ASUS Zenbook A14 Whisper/Quiet/Normal/Turbo/Full Speed Power Mode support."],
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
        if not icon.is_file():
            raise RuntimeError(f"missing symbolic icon: {icon}")
        run(["sudo", "install", "-m", "0644", str(icon), str(dest / icon.name)])
    if shutil.which("gtk-update-icon-cache"):
        run(["sudo", "gtk-update-icon-cache", "-f", "-t", "/usr/share/icons/hicolor"], check=False)


def install_native_marker() -> None:
    marker = WORK / "native-gnome-five-profile"
    marker.write_text(
        "ASUS Zenbook A14 native GNOME five-mode UI\n"
        "modes=whisper,quiet,normal,turbo,full-speed\n"
        "ppd=power-saver,quiet,balanced,performance,full-speed\n",
        encoding="utf-8",
    )
    run(["sudo", "install", "-D", "-m", "0644", str(marker), str(NATIVE_UI_MARKER)])


def enable_osd_extension() -> None:
    if shutil.which("gnome-extensions"):
        run(["gnome-extensions", "enable", EXTENSION_UUID], check=False)
    print("a14_extension_role=native-osd-only-after-shell-restart")


def main() -> int:
    for cmd in (
        "gnome-shell", "gnome-control-center", "apt-get", "dpkg-buildpackage",
        "dpkg-parsechangelog", "dpkg-deb", "dch", "sudo",
    ):
        require(cmd)

    shell_version = output(["gnome-shell", "--version"])
    cc_version = output(["gnome-control-center", "--version"])
    print(f"gnome_shell={shell_version}")
    print(f"gnome_control_center={cc_version}")

    if version_major(shell_version) != 50 or version_major(cc_version) != 50:
        raise RuntimeError("the current semantic edits are intentionally pinned to GNOME 50.x")

    if WORK.exists():
        shutil.rmtree(WORK)
    WORK.mkdir(parents=True, exist_ok=True)

    run(["sudo", "apt-get", "build-dep", "-y", "gnome-shell", "gnome-control-center"])
    run(["apt-get", "source", "gnome-shell", "gnome-control-center"], cwd=WORK)

    shell_src = find_source("gnome-shell")
    cc_src = find_source("gnome-control-center")
    print(f"gnome_shell_source={shell_src}")
    print(f"gnome_control_center_source={cc_src}")

    patch_shell_semantic(shell_src)
    patch_control_center_semantic(cc_src)
    localize_version(shell_src)
    localize_version(cc_src)

    run(["grep", "-n", "-E", "Whisper|Quiet|Normal|Turbo|Full Speed|full-speed",
         str(shell_src / "js/ui/status/powerProfiles.js")], check=True)
    run(["grep", "-n", "-E", "WHISPER|QUIET|NORMAL|TURBO|FULL_SPEED|Whisper|Quiet|Normal|Turbo|Full Speed",
         str(cc_src / "panels/power/cc-power-profile-row.c")], check=True)

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
    install_native_marker()
    enable_osd_extension()
    run(["sudo", "systemctl", "restart", "asus-zenbook-a14-ppd-bridge.service"], check=False)
    run(["sudo", "systemctl", "restart", "asus-zenbook-a14-profile.service"], check=False)

    print("A14_GNOME_NATIVE_FIVE_PROFILE_INSTALL=PASS")
    print("single_power_mode_control=true")
    print("gnome_quick_settings_modes=Whisper,Quiet,Normal,Turbo,Full Speed")
    print("gnome_settings_modes=Whisper,Quiet,Normal,Turbo,Full Speed")
    print("fn_f_osd_extension=enabled")
    print("logout_login_required=true")
    print("note=Wayland GNOME Shell must restart to load its rebuilt resource bundle and OSD-only extension role")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"A14_GNOME_NATIVE_FIVE_PROFILE_INSTALL=FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
