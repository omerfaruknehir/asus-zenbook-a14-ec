#!/bin/sh

BUS=org.freedesktop.UPower.PowerProfiles
OBJ=/org/freedesktop/UPower/PowerProfiles
IFACE=org.freedesktop.UPower.PowerProfiles
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
        busctl --system set-property "$BUS" "$OBJ" "$IFACE" ActiveProfile s "$original" >/dev/null 2>&1 || \
            busctl --system set-property "$BUS" "$OBJ" "$IFACE" ActiveProfile s balanced >/dev/null 2>&1 || true
    fi
}

trap restore INT TERM HUP

say "===== GNOME / BACKEND ====="
gnome-shell --version 2>/dev/null || true
gnome-control-center --version 2>/dev/null || true
say "xdg_current_desktop=${XDG_CURRENT_DESKTOP:-unset}"
say "xdg_session_type=${XDG_SESSION_TYPE:-unset}"

if ! command -v busctl >/dev/null 2>&1; then
    say "ERROR: busctl is required"
    ok=0
fi

if [ "$ok" -eq 1 ]; then
    systemctl is-active asus-zenbook-a14-ppd-bridge.service 2>/dev/null
    bridge_rc=$?
    say "ppd_bridge_active_rc=$bridge_rc"
    if [ "$bridge_rc" -ne 0 ]; then
        say "ERROR: A14 PPD-compatible backend is not active"
        ok=0
    fi
fi

say ""
say "===== ADVERTISED PROFILES ====="
if [ "$ok" -eq 1 ]; then
    profiles=$(busctl --system get-property "$BUS" "$OBJ" "$IFACE" Profiles 2>&1)
    rc=$?
    say "Profiles_rc=$rc"
    say "Profiles=$profiles"
    if [ "$rc" -ne 0 ]; then
        ok=0
    else
        for required in quiet power-saver balanced performance full-speed; do
            case "$profiles" in
                *"\"$required\""*) say "profile_advertised=$required" ;;
                *) say "ERROR: backend profile missing: $required"; ok=0 ;;
            esac
        done
    fi
fi

say ""
say "===== FIVE-MODE D-BUS ROUND TRIP ====="
if [ "$ok" -eq 1 ]; then
    original=$(cat "$PROFILE" 2>/dev/null)
    case "$original" in quiet|power-saver|balanced|performance|full-speed) ;; *) original=balanced ;; esac
    say "original_profile=$original"

    for requested in quiet power-saver balanced performance full-speed; do
        say "----- ActiveProfile $requested -----"
        result=$(busctl --system set-property "$BUS" "$OBJ" "$IFACE" ActiveProfile s "$requested" 2>&1)
        rc=$?
        sleep 1
        actual=$(cat "$PROFILE" 2>/dev/null)
        active=$(busctl --system get-property "$BUS" "$OBJ" "$IFACE" ActiveProfile 2>/dev/null || true)
        say "set_rc=$rc driver_profile=$actual dbus_active=$active"
        if [ -n "$result" ]; then
            say "set_output=$result"
        fi
        if [ "$rc" -ne 0 ] || [ "$actual" != "$requested" ]; then
            say "ERROR: profile mismatch requested=$requested actual=$actual"
            ok=0
            break
        fi
    done
fi

restore
sleep 1

say ""
say "===== PATCHED STOCK GNOME ====="
shell_pkg=$(dpkg-query -W -f='${Version}' gnome-shell 2>/dev/null || true)
cc_pkg=$(dpkg-query -W -f='${Version}' gnome-control-center 2>/dev/null || true)
say "gnome_shell_package=$shell_pkg"
say "gnome_control_center_package=$cc_pkg"
case "$shell_pkg" in *+a14*) say "gnome_shell_a14_patch=present" ;; *) say "ERROR: patched gnome-shell package not installed"; ok=0 ;; esac
case "$cc_pkg" in *+a14*) say "gnome_control_center_a14_patch=present" ;; *) say "ERROR: patched gnome-control-center package not installed"; ok=0 ;; esac

for icon in \
    /usr/share/icons/hicolor/scalable/status/a14-power-profile-quiet-symbolic.svg \
    /usr/share/icons/hicolor/scalable/status/a14-power-profile-full-speed-symbolic.svg
do
    if [ -r "$icon" ]; then
        say "icon_present=$icon"
    else
        say "ERROR: icon missing: $icon"
        ok=0
    fi
done

say ""
say "===== OBSOLETE DUPLICATE EXTENSION ====="
if command -v gnome-extensions >/dev/null 2>&1 && gnome-extensions list 2>/dev/null | grep -qx "$UUID"; then
    info=$(gnome-extensions info "$UUID" 2>&1)
    printf '%s\n' "$info"
    if printf '%s\n' "$info" | grep -Eq 'Enabled:[[:space:]]+Yes|State:[[:space:]]+(ACTIVE|ENABLED)'; then
        say "ERROR: obsolete A14 duplicate Quick Settings extension is still active"
        ok=0
    else
        say "obsolete_extension_active=false"
    fi
else
    say "obsolete_extension_present=false"
fi

say ""
say "===== RESULT ====="
if [ "$ok" -eq 1 ]; then
    say "A14_GNOME_NATIVE_FIVE_PROFILE_VALIDATION=PASS"
else
    say "A14_GNOME_NATIVE_FIVE_PROFILE_VALIDATION=FAIL"
fi
say "final_profile=$(cat "$PROFILE" 2>/dev/null)"

trap - INT TERM HUP
true
