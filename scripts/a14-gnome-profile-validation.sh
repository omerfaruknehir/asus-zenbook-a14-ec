#!/bin/sh

BUS=io.github.omerfaruknehir.AsusA14
OBJ=/io/github/omerfaruknehir/AsusA14
IFACE=io.github.omerfaruknehir.AsusA14.Profile1
PROFILE=/sys/devices/platform/asus_zenbook_a14_ec/profile
UUID=asus-a14-modes@omerfaruknehir
ok=1
original=""

say()
{
    printf '%s\n' "$*"
}

restore()
{
    if [ -n "$original" ] && command -v busctl >/dev/null 2>&1; then
        busctl --system call "$BUS" "$OBJ" "$IFACE" SetProfile s "$original" >/dev/null 2>&1 || \
            busctl --system call "$BUS" "$OBJ" "$IFACE" SetProfile s balanced >/dev/null 2>&1 || true
    fi
}

trap restore INT TERM HUP

say "===== GNOME / SERVICE ====="
if command -v gnome-shell >/dev/null 2>&1; then
    gnome-shell --version 2>/dev/null || true
else
    say "gnome_shell=not-installed"
fi
say "xdg_current_desktop=${XDG_CURRENT_DESKTOP:-unset}"
say "xdg_session_type=${XDG_SESSION_TYPE:-unset}"

if ! command -v busctl >/dev/null 2>&1; then
    say "ERROR: busctl is required"
    ok=0
fi

if [ "$ok" -eq 1 ]; then
    systemctl is-active asus-zenbook-a14-profile.service 2>/dev/null
    service_rc=$?
    say "profile_service_active_rc=$service_rc"
    if [ "$service_rc" -ne 0 ]; then
        ok=0
    fi
fi

if [ "$ok" -eq 1 ]; then
    reply=$(busctl --system call "$BUS" "$OBJ" "$IFACE" GetProfiles 2>&1)
    rc=$?
    say "GetProfiles_rc=$rc"
    say "GetProfiles=$reply"
    if [ "$rc" -ne 0 ]; then
        ok=0
    else
        for required in quiet power-saver balanced performance full-speed; do
            case "$reply" in
                *"\"$required\""*) ;;
                *) say "ERROR: D-Bus profile missing: $required"; ok=0 ;;
            esac
        done
    fi
fi

if [ "$ok" -eq 1 ]; then
    original=$(cat "$PROFILE" 2>/dev/null)
    case "$original" in quiet|power-saver|balanced|performance|full-speed) ;; *) original=balanced ;; esac
    say "original_profile=$original"

    for requested in quiet power-saver balanced performance full-speed; do
        say "----- D-Bus SetProfile $requested -----"
        busctl --system call "$BUS" "$OBJ" "$IFACE" SetProfile s "$requested" >/dev/null 2>&1
        rc=$?
        sleep 1
        actual=$(cat "$PROFILE" 2>/dev/null)
        say "set_rc=$rc driver_profile=$actual"
        if [ "$rc" -ne 0 ] || [ "$actual" != "$requested" ]; then
            say "ERROR: D-Bus profile mismatch requested=$requested actual=$actual"
            ok=0
            break
        fi
    done
fi

restore
sleep 1

say ""
say "===== STOCK GNOME POWER MODE ====="
if command -v powerprofilesctl >/dev/null 2>&1; then
    for ppd in power-saver balanced performance; do
        powerprofilesctl set "$ppd" >/dev/null 2>&1
        rc=$?
        sleep 1
        actual=$(cat "$PROFILE" 2>/dev/null)
        say "gnome_standard=$ppd set_rc=$rc driver_profile=$actual"
        if [ "$rc" -ne 0 ] || [ "$actual" != "$ppd" ]; then
            say "ERROR: standard GNOME mapping failed for $ppd"
            ok=0
            break
        fi
    done
    powerprofilesctl set balanced >/dev/null 2>&1 || true
else
    say "powerprofilesctl=unavailable"
    ok=0
fi

say ""
say "===== A14 QUICK SETTINGS EXTENSION ====="
extdir=/usr/share/gnome-shell/extensions/$UUID
if [ -r "$extdir/metadata.json" ] && [ -r "$extdir/extension.js" ]; then
    say "extension_payload=installed"
    say "extension_dir=$extdir"
    ls -ld "$extdir" 2>/dev/null || true
    ls -l "$extdir/metadata.json" "$extdir/extension.js" 2>/dev/null || true
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$extdir/metadata.json" <<'PY' 2>&1 || true
import json, sys
p = sys.argv[1]
try:
    m = json.load(open(p, encoding='utf-8'))
    print('extension_metadata_uuid=' + str(m.get('uuid')))
    print('extension_metadata_shell_versions=' + ','.join(map(str, m.get('shell-version', []))))
except Exception as e:
    print('extension_metadata_error=' + repr(e))
PY
    fi
else
    say "ERROR: extension payload missing"
    ok=0
fi

if command -v gsettings >/dev/null 2>&1; then
    say "disable_user_extensions=$(gsettings get org.gnome.shell disable-user-extensions 2>/dev/null || echo unavailable)"
    say "enabled_extensions=$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || echo unavailable)"
fi

if command -v gnome-extensions >/dev/null 2>&1; then
    discovered=0
    if gnome-extensions list 2>/dev/null | grep -qx "$UUID"; then
        discovered=1
        say "extension_discovered=true"
    else
        say "extension_discovered=false"
    fi

    say "----- gnome-extensions info BEFORE enable -----"
    info_before=$(gnome-extensions info "$UUID" 2>&1)
    info_before_rc=$?
    say "info_before_rc=$info_before_rc"
    printf '%s\n' "$info_before"

    if [ "$discovered" -eq 1 ]; then
        gnome-extensions enable "$UUID" >/tmp/a14-gnome-enable.$$ 2>&1
        enable_rc=$?
        say "extension_enable_rc=$enable_rc"
        if [ -s /tmp/a14-gnome-enable.$$ ]; then
            sed 's/^/extension_enable_output=/' /tmp/a14-gnome-enable.$$
        fi
        rm -f /tmp/a14-gnome-enable.$$
        sleep 1

        say "----- gnome-extensions info AFTER enable -----"
        info_after=$(gnome-extensions info "$UUID" 2>&1)
        info_after_rc=$?
        say "info_after_rc=$info_after_rc"
        printf '%s\n' "$info_after"

        if [ "$enable_rc" -eq 0 ] && printf '%s\n' "$info_after" | grep -Eq 'State:[[:space:]]+ENABLED'; then
            say "extension_enabled=true"
        else
            say "ERROR: extension is discovered but not enabled"
            ok=0
        fi
    else
        say "ERROR: GNOME Shell did not discover the installed system extension after login/reboot"
        ok=0
    fi
else
    say "ERROR: gnome_extensions_cli=unavailable"
    ok=0
fi

say ""
say "===== GNOME SHELL EXTENSION LOG ====="
journalctl --user -b --no-pager -o cat 2>/dev/null | \
    grep -Ei 'asus-a14-modes|AsusA14|A14 Mode|extension.*error|JS ERROR|Gjs-CRITICAL' | tail -n 100 || true
journalctl -b --no-pager -o cat /usr/bin/gnome-shell 2>/dev/null | \
    grep -Ei 'asus-a14-modes|AsusA14|A14 Mode|extension.*error|JS ERROR|Gjs-CRITICAL' | tail -n 100 || true

say ""
say "===== EMERGENCY STATE ====="
busctl --system call "$BUS" "$OBJ" "$IFACE" GetQuietEmergency 2>/dev/null || true
[ -r /sys/devices/platform/asus_zenbook_a14_ec/quiet_emergency ] && \
    say "driver_quiet_emergency=$(cat /sys/devices/platform/asus_zenbook_a14_ec/quiet_emergency 2>/dev/null)"

say ""
if [ "$ok" -eq 1 ]; then
    say "A14_GNOME_PROFILE_VALIDATION=PASS"
else
    say "A14_GNOME_PROFILE_VALIDATION=FAIL"
fi
say "final_profile=$(cat "$PROFILE" 2>/dev/null)"

trap - INT TERM HUP
true
