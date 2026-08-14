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
else
    say "ERROR: extension payload missing"
    ok=0
fi

if command -v gnome-extensions >/dev/null 2>&1; then
    if gnome-extensions list 2>/dev/null | grep -qx "$UUID"; then
        say "extension_discovered=true"
        gnome-extensions enable "$UUID" >/dev/null 2>&1 || true
        if gnome-extensions info "$UUID" 2>/dev/null | grep -q 'State: ENABLED'; then
            say "extension_enabled=true"
        else
            say "extension_enabled=false"
            say "extension_note=log_out_and_back_in_once_if_this_package_was_just_installed"
        fi
    else
        say "extension_discovered=false"
        say "extension_note=GNOME_Shell_must_start_a_new_session_once_to_scan_the_new_system_extension"
    fi
else
    say "gnome_extensions_cli=unavailable"
fi

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
