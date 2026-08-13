#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    exec sudo --preserve-env=PATH bash "$0" "$@"
fi

case "${1:-install}" in
install)
    ;;
uninstall)
    rm -f \
      /etc/udev/rules.d/99-a14-camera-permissions.rules \
      /usr/lib/systemd/system-sleep/99-a14-resume-fix \
      /etc/systemd/system/a14-post-resume-fix.service \
      /usr/local/libexec/a14-resume-fix/a14-post-resume-fix
    rmdir /usr/local/libexec/a14-resume-fix 2>/dev/null || true
    systemctl daemon-reload
    udevadm control --reload-rules
    echo "Persistent A14 resume recovery removed."
    exit 0
    ;;
*)
    echo "Usage: $0 [install|uninstall]" >&2
    exit 2
    ;;
esac

install -d -m 0755 /usr/local/libexec/a14-resume-fix
install -d -m 0755 /run/a14-resume-fix

cat >/etc/udev/rules.d/99-a14-camera-permissions.rules <<'EOF'
# ASUS Zenbook A14: keep CAMSS V4L/media nodes usable after seat/suspend churn.
SUBSYSTEM=="video4linux", GROUP="video", MODE="0660", TAG+="uaccess"
SUBSYSTEM=="media", GROUP="video", MODE="0660", TAG+="uaccess"
EOF

cat >/usr/local/libexec/a14-resume-fix/a14-post-resume-fix <<'EOF'
#!/usr/bin/env bash
set -u

STATE=/run/a14-resume-fix
mkdir -p "$STATE"

log() {
    logger -t a14-resume-fix -- "$*" 2>/dev/null || true
    printf '[a14-resume-fix] %s\n' "$*"
}

restart_active_user_media() {
    local sid uid name
    loginctl list-sessions --no-legend 2>/dev/null | while read -r sid _; do
        [[ -n "$sid" ]] || continue
        [[ "$(loginctl show-session "$sid" -p Active --value 2>/dev/null)" == yes ]] || continue
        uid="$(loginctl show-session "$sid" -p User --value 2>/dev/null)"
        [[ "$uid" =~ ^[0-9]+$ && "$uid" -ge 1000 ]] || continue
        name="$(getent passwd "$uid" | cut -d: -f1)"
        [[ -n "$name" ]] || continue
        runuser -u "$name" -- env \
          XDG_RUNTIME_DIR="/run/user/$uid" \
          DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
          systemctl --user restart pipewire.service wireplumber.service >/dev/null 2>&1 || true
    done
}

repair_camera_permissions() {
    local bad=0 f mode
    local nodes=()
    shopt -s nullglob
    nodes+=(/dev/video* /dev/v4l-subdev* /dev/media*)
    shopt -u nullglob

    ((${#nodes[@]})) || return 0

    for f in "${nodes[@]}"; do
        mode="$(stat -Lc '%a' "$f" 2>/dev/null || echo missing)"
        if [[ "$mode" != 660 ]]; then
            bad=1
            break
        fi
    done

    ((bad)) || return 0

    log "repairing V4L/media node permissions"
    udevadm trigger --action=add --subsystem-match=video4linux 2>/dev/null || true
    udevadm trigger --action=add --subsystem-match=media 2>/dev/null || true
    udevadm settle --timeout=5 2>/dev/null || true

    shopt -s nullglob
    nodes=(/dev/video* /dev/v4l-subdev* /dev/media*)
    shopt -u nullglob
    for f in "${nodes[@]}"; do
        chown root:video "$f" 2>/dev/null || true
        chmod 0660 "$f" 2>/dev/null || true
    done

    restart_active_user_media
}

repair_keyboard_hid() {
    local drv=/sys/bus/hid/drivers/hid_asus_zenbook_a14_ec
    local led=/sys/class/leds/asus::kbd_backlight
    local saved='' dev id i
    local devs=()

    [[ -d "$drv" && -w "$drv/unbind" && -w "$drv/bind" ]] || return 0

    if [[ -r "$STATE/kbd-brightness" ]]; then
        read -r saved < "$STATE/kbd-brightness" || true
    elif [[ -r "$led/brightness" ]]; then
        read -r saved < "$led/brightness" || true
    fi
    [[ "$saved" =~ ^[0-3]$ ]] || saved=1

    shopt -s nullglob
    devs=("$drv"/0018:0B05:0220.*)
    shopt -u nullglob
    ((${#devs[@]})) || return 0

    log "re-probing Zenbook A14 EC HID driver after resume"
    for dev in "${devs[@]}"; do
        [[ -L "$dev" || -e "$dev" ]] || continue
        id="$(basename "$dev")"
        printf '%s\n' "$id" > "$drv/unbind" 2>/dev/null || continue
        sleep 0.20
        printf '%s\n' "$id" > "$drv/bind" 2>/dev/null || true
    done

    for i in {1..20}; do
        [[ -w "$led/brightness" ]] && break
        sleep 0.10
    done
    if [[ -w "$led/brightness" ]]; then
        printf '%s\n' "$saved" > "$led/brightness" 2>/dev/null || true
    fi
}

# Let the I2C-HID and camera stacks finish their normal resume first.
sleep 1
repair_camera_permissions
repair_keyboard_hid
rm -f "$STATE/kbd-brightness" 2>/dev/null || true
EOF
chmod 0755 /usr/local/libexec/a14-resume-fix/a14-post-resume-fix

cat >/etc/systemd/system/a14-post-resume-fix.service <<'EOF'
[Unit]
Description=ASUS Zenbook A14 post-resume camera/keyboard recovery
After=systemd-suspend.service

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/a14-resume-fix/a14-post-resume-fix
EOF

cat >/usr/lib/systemd/system-sleep/99-a14-resume-fix <<'EOF'
#!/bin/sh
STATE=/run/a14-resume-fix
LED=/sys/class/leds/asus::kbd_backlight/brightness

case "$1" in
pre)
    mkdir -p "$STATE" 2>/dev/null || true
    if [ -r "$LED" ]; then
        cat "$LED" > "$STATE/kbd-brightness" 2>/dev/null || true
    fi
    ;;
post)
    # Queue recovery, but order it after systemd-suspend.service has fully exited.
    systemctl --no-block restart a14-post-resume-fix.service >/dev/null 2>&1 || true
    ;;
esac
exit 0
EOF
chmod 0755 /usr/lib/systemd/system-sleep/99-a14-resume-fix

# Keep the older experimental hooks disabled. They mutate more hardware than
# required and were involved in the broken-resume state during diagnosis.
for h in \
  /usr/lib/systemd/system-sleep/85-a14-x1e-suspend-hardware \
  /usr/lib/systemd/system-sleep/a14-kbd-leds
 do
    [[ -e "$h" ]] && chmod a-x "$h" || true
 done
rm -f /run/a14-kbd-sleeping /run/a14-kbd-resume-quiet 2>/dev/null || true

systemctl daemon-reload
udevadm control --reload-rules

# Apply the camera rule to the currently existing media graph now.
udevadm trigger --action=add --subsystem-match=video4linux 2>/dev/null || true
udevadm trigger --action=add --subsystem-match=media 2>/dev/null || true
udevadm settle --timeout=5 2>/dev/null || true

shopt -s nullglob
for f in /dev/video* /dev/v4l-subdev* /dev/media*; do
    chown root:video "$f" 2>/dev/null || true
    chmod 0660 "$f" 2>/dev/null || true
done
shopt -u nullglob

# Exercise the same recovery path immediately so installation is self-checking.
systemctl start a14-post-resume-fix.service || true

echo
printf '%s\n' 'Installed persistent A14 resume recovery:' \
  '  - /etc/udev/rules.d/99-a14-camera-permissions.rules' \
  '  - /usr/lib/systemd/system-sleep/99-a14-resume-fix' \
  '  - /etc/systemd/system/a14-post-resume-fix.service' \
  '  - /usr/local/libexec/a14-resume-fix/a14-post-resume-fix'
echo
systemctl status a14-post-resume-fix.service --no-pager -l 2>/dev/null | tail -25 || true
