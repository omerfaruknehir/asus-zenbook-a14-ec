#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Read-only pre-arm verifier for the A14 factory-ACPI v2 safe boot.
set -euo pipefail

KREL="7.1.5-a14-acpi-full0"
SAFE_ENTRY="ASUS Zenbook A14 — ACPI v2 safe console ($KREL)"
KERNEL="/boot/vmlinuz-$KREL"
INITRD="/boot/initrd.img-$KREL"
SNIPPET="/etc/grub.d/41_a14_acpi_v2"
GRUB_CFG="/boot/grub/grub.cfg"
GRUB_ENV="/boot/grub/grubenv"
OWNER_HOME="$(if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then getent passwd "$SUDO_USER" | cut -d: -f6; else printf '%s' "$HOME"; fi)"
WORK="${A14_74C9_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
FINAL_STAMP="$WORK/74c9bd5-build.ready"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"; }

need_root
for c in awk grep sha256sum findmnt blkid uname; do need "$c"; done

[[ "$(uname -r)" != "$KREL" ]] || die "currently running the target ACPI kernel; verify from the normal DT/rescue kernel"
[[ -s "$KERNEL" ]] || die "target kernel missing: $KERNEL"
[[ -s "$INITRD" ]] || die "target initrd missing: $INITRD"
[[ -r "$FINAL_STAMP" ]] || die "final successful-build stamp missing: $FINAL_STAMP"
[[ -x "$SNIPPET" ]] || die "v2 GRUB snippet missing or non-executable: $SNIPPET"
[[ -r "$GRUB_CFG" ]] || die "generated grub.cfg missing: $GRUB_CFG"

expected_krel="$(awk -F= '$1 == "kernelrelease" {print $2}' "$FINAL_STAMP")"
expected_sha="$(awk -F= '$1 == "image_sha256" {print $2}' "$FINAL_STAMP")"
[[ "$expected_krel" == "$KREL" ]] || die "stamp kernelrelease mismatch: ${expected_krel:-missing}"
[[ -n "$expected_sha" ]] || die "stamp image SHA is missing"
installed_sha="$(sha256sum "$KERNEL" | awk '{print $1}')"
[[ "$installed_sha" == "$expected_sha" ]] || die "installed kernel SHA mismatch: got $installed_sha expected $expected_sha"

menu_count="$(grep -c "^menuentry 'ASUS Zenbook A14 — ACPI v2 .* console ($KREL)'" "$SNIPPET" || true)"
[[ "$menu_count" -eq 2 ]] || die "expected exactly 2 ACPI v2 menuentries in snippet, found $menu_count"
! grep -Eq '^[[:space:]]*devicetree([[:space:]]|$)' "$SNIPPET" || die "snippet contains an active devicetree command"

safe_stanza="$(awk -v title="$SAFE_ENTRY" '
    $0 == "menuentry \047" title "\047 --class ubuntu --class gnu-linux --class gnu --class os {" {in_safe=1}
    in_safe {print}
    in_safe && $0 == "}" {exit}
' "$SNIPPET")"
[[ -n "$safe_stanza" ]] || die "could not extract safe ACPI v2 stanza"

safe_linux="$(awk '/^[[:space:]]*linux[[:space:]]/{print; exit}' <<<"$safe_stanza")"
safe_initrd="$(awk '/^[[:space:]]*initrd[[:space:]]/{print; exit}' <<<"$safe_stanza")"
[[ -n "$safe_linux" ]] || die "safe stanza has no linux line"
[[ "$safe_initrd" == *"/boot/initrd.img-$KREL"* ]] || die "safe stanza points to wrong initrd"
[[ "$safe_linux" == *"/boot/vmlinuz-$KREL"* ]] || die "safe stanza points to wrong kernel"

for required in \
    ' acpi=force' \
    ' earlycon=efifb,ram' \
    ' console=tty0' \
    ' loglevel=8' \
    ' ignore_loglevel' \
    ' printk.time=1' \
    ' systemd.unit=multi-user.target' \
    ' clk_ignore_unused' \
    ' pd_ignore_unused' \
    ' cma=128M' \
    ' efi=noruntime'; do
    grep -Fq "$required" <<<"$safe_linux" || die "safe linux line lacks:$required"
done

for forbidden in \
    'devicetree' \
    'a14_acpi_halt=' \
    'a14_acpi_reboot_delay_ms=' \
    'a14_acpi_trace_delay_ms=' \
    'a14_device_halt_after=' \
    'initcall_blacklist=' \
    'reserve_mem=' \
    'ramoops.' \
    'splash'; do
    ! grep -Fq "$forbidden" <<<"$safe_stanza" || die "safe stanza contains forbidden token: $forbidden"
done

root_uuid="$(findmnt -n -o UUID / 2>/dev/null || true)"
if [[ -z "$root_uuid" || "$root_uuid" == "-" ]]; then
    root_src="$(findmnt -n -o SOURCE /)"
    root_uuid="$(blkid -s UUID -o value "$root_src" 2>/dev/null || true)"
fi
[[ -n "$root_uuid" ]] || die "cannot determine current root filesystem UUID"
grep -Fq "root=UUID=$root_uuid" <<<"$safe_linux" || die "safe entry root UUID does not match the mounted root filesystem"
grep -Fq "search --no-floppy --fs-uuid --set=root $root_uuid" <<<"$safe_stanza" || die "safe entry GRUB search UUID does not match mounted root"

cfg_count="$(grep -Fxc "menuentry '$SAFE_ENTRY' --class ubuntu --class gnu-linux --class gnu --class os {" "$GRUB_CFG" || true)"
[[ "$cfg_count" -eq 1 ]] || die "generated grub.cfg does not contain exactly one safe ACPI v2 entry (found $cfg_count)"

if command -v grub-script-check >/dev/null 2>&1; then
    grub-script-check "$GRUB_CFG" >/dev/null || die "grub-script-check rejected $GRUB_CFG"
    say "grub_script_check=PASS"
else
    say "grub_script_check=unavailable"
fi

next_entry=""
if command -v grub-editenv >/dev/null 2>&1 && [[ -f "$GRUB_ENV" ]]; then
    next_entry="$(grub-editenv "$GRUB_ENV" list 2>/dev/null | sed -n 's/^next_entry=//p' | head -n1 || true)"
fi
[[ -z "$next_entry" ]] || die "a GRUB one-shot next_entry is already armed: $next_entry"

say "A14_ACPI_V2_PRE_ARM_VERIFY=PASS"
say "running_kernel=$(uname -r)"
say "target_kernel=$KERNEL"
say "installed_sha256=$installed_sha"
say "target_initrd=$INITRD"
say "root_uuid=$root_uuid"
say "safe_entry=$SAFE_ENTRY"
say "active_devicetree_command=false"
say "safe_target=multi-user.target"
say "safe_hold_open_clocks=true"
say "safe_hold_open_power_domains=true"
say "stale_next_entry=false"
say "ready_to_arm=true"
