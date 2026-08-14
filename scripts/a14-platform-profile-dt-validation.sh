#!/bin/sh

# Build and validate the Linux platform_profile class on the DT-booted A14.
# The upstream 7.1.5 module exports the class API but refuses module init when
# acpi_disabled is true. The repository transform keeps the class API usable
# while leaving ACPI-only legacy aggregate sysfs disabled on a DT boot.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd)
USER_HOME=$HOME
if [ -n "${SUDO_USER:-}" ] && command -v getent >/dev/null 2>&1; then
    resolved_home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
    if [ -n "$resolved_home" ]; then
        USER_HOME=$resolved_home
    fi
fi
KERNEL_SRC=${A14_KERNEL_SRC:-$USER_HOME/Downloads/linux-7.1.5-a14-mainline}
KBUILD=/lib/modules/$(uname -r)/build
BUILD_DIR=$ROOT/.platform-profile-dt-build
PP_SRC=$KERNEL_SRC/drivers/acpi/platform_profile.c
PP_KO=$BUILD_DIR/platform_profile.ko
EC_KO=$ROOT/asus_zenbook_a14_ec.ko
ok=1
loaded_pp=0
loaded_ec=0
PP_NODE=""

say()
{
    printf '%s\n' "$*"
}

find_pp_node()
{
    PP_NODE=""
    for d in /sys/class/platform-profile/platform-profile-*; do
        if [ -r "$d/name" ] && [ "$(cat "$d/name" 2>/dev/null)" = asus-zenbook-a14-ec ]; then
            PP_NODE=$d
            break
        fi
    done
}

count_profile_handlers()
{
    count=0
    for d in /sys/class/platform-profile/platform-profile-*; do
        if [ -d "$d" ]; then
            count=$((count + 1))
        fi
    done
    printf '%s' "$count"
}

restore_balanced()
{
    if [ -n "$PP_NODE" ] && [ -w "$PP_NODE/profile" ]; then
        printf '%s\n' balanced > "$PP_NODE/profile" 2>/dev/null || true
    elif [ -w /sys/devices/platform/asus_zenbook_a14_ec/profile ]; then
        printf '%s\n' balanced > /sys/devices/platform/asus_zenbook_a14_ec/profile 2>/dev/null || true
    fi
}

if [ "$(id -u)" -ne 0 ]; then
    say "ERROR: run with sudo: sudo sh ./scripts/a14-platform-profile-dt-validation.sh"
    ok=0
fi

if [ "$ok" -eq 1 ]; then
    say "===== INPUT ====="
    say "kernel=$(uname -r)"
    say "user_home=$USER_HOME"
    say "kernel_source=$KERNEL_SRC"
    say "kernel_build=$KBUILD"

    if [ ! -r "$PP_SRC" ]; then
        say "ERROR: missing $PP_SRC"
        ok=0
    fi
    if [ ! -d "$KBUILD" ]; then
        say "ERROR: missing running-kernel build directory $KBUILD"
        ok=0
    fi
    if [ ! -r "$EC_KO" ]; then
        say "ERROR: missing $EC_KO; build the EC modules first"
        ok=0
    fi
fi

if [ "$ok" -eq 1 ]; then
    say ""
    say "===== RUNNING KERNEL CONFIG ====="
    cfg=""
    if [ -r "/boot/config-$(uname -r)" ]; then
        cfg=/boot/config-$(uname -r)
    elif [ -r /proc/config.gz ]; then
        cfg=/proc/config.gz
    fi

    if [ -n "$cfg" ]; then
        if [ "$cfg" = /proc/config.gz ]; then
            zcat "$cfg" 2>/dev/null | grep '^CONFIG_ACPI_PLATFORM_PROFILE=' || true
        else
            grep '^CONFIG_ACPI_PLATFORM_PROFILE=' "$cfg" || true
        fi
    else
        say "kernel_config=unavailable"
    fi

    modinfo platform_profile 2>/dev/null | grep -E '^(filename|vermagic):' || true
fi

if [ "$ok" -eq 1 ]; then
    handlers=$(count_profile_handlers)
    say "existing_platform_profile_handlers=$handlers"
    if [ "$handlers" -ne 0 ]; then
        say "ERROR: a platform-profile handler is already active; refusing to replace the framework underneath it."
        find_pp_node
        say "existing_a14_platform_profile=${PP_NODE:-none}"
        ok=0
    fi
fi

if [ "$ok" -eq 1 ]; then
    say ""
    say "===== APPLY DT CLASS FIX ====="
    python3 "$ROOT/scripts/apply-mainline-platform-profile-dt.py" "$KERNEL_SRC"
    rc=$?
    say "transform_rc=$rc"
    if [ "$rc" -ne 0 ]; then
        ok=0
    fi
fi

if [ "$ok" -eq 1 ]; then
    git -C "$KERNEL_SRC" diff --check -- drivers/acpi/platform_profile.c
    rc=$?
    say "diff_check_rc=$rc"
    if [ "$rc" -ne 0 ]; then
        ok=0
    fi
fi

if [ "$ok" -eq 1 ]; then
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    cp "$PP_SRC" "$BUILD_DIR/platform_profile.c"
    cat > "$BUILD_DIR/Makefile" <<'EOF'
obj-m += platform_profile.o
EOF

    say ""
    say "===== BUILD PATCHED PLATFORM_PROFILE ====="
    make -C "$KBUILD" M="$BUILD_DIR" modules
    rc=$?
    say "platform_profile_build_rc=$rc"
    if [ "$rc" -ne 0 ] || [ ! -r "$PP_KO" ]; then
        ok=0
    fi
fi

if [ "$ok" -eq 1 ]; then
    if grep -q '^asus_zenbook_a14_ec ' /proc/modules 2>/dev/null; then
        say "unloading_ec=true"
        sh "$ROOT/scripts/asus-zenbook-a14-ec-unload"
    fi
    if grep -q '^asus_zenbook_a14_ec ' /proc/modules 2>/dev/null; then
        say "ERROR: EC module remained loaded"
        ok=0
    fi
fi

if [ "$ok" -eq 1 ]; then
    if grep -q '^platform_profile ' /proc/modules 2>/dev/null; then
        say "existing_platform_profile_module=true"
        modprobe -r platform_profile 2>/dev/null
        rc=$?
        say "platform_profile_unload_rc=$rc"
        if [ "$rc" -ne 0 ]; then
            ok=0
        fi
    fi
fi

if [ "$ok" -eq 1 ]; then
    say "loading_patched_platform_profile=$PP_KO"
    insmod "$PP_KO"
    rc=$?
    say "platform_profile_insmod_rc=$rc"
    if [ "$rc" -ne 0 ]; then
        ok=0
    else
        loaded_pp=1
    fi
fi

if [ "$ok" -eq 1 ]; then
    say "loading_local_ec=$EC_KO"
    insmod "$EC_KO" performance_pwm=160
    rc=$?
    say "ec_insmod_rc=$rc"
    if [ "$rc" -ne 0 ]; then
        ok=0
    else
        loaded_ec=1
        sleep 2
    fi
fi

if [ "$ok" -eq 1 ]; then
    find_pp_node
    say "a14_platform_profile_node=${PP_NODE:-missing}"
    if [ -z "$PP_NODE" ]; then
        ok=0
    fi
fi

if [ "$ok" -eq 1 ]; then
    say ""
    say "===== STANDARD CLASS API ====="
    say "name=$(cat "$PP_NODE/name" 2>/dev/null)"
    say "choices=$(cat "$PP_NODE/choices" 2>/dev/null)"
    say "profile=$(cat "$PP_NODE/profile" 2>/dev/null)"
    say "legacy_acpi_platform_profile_present=$(test -e /sys/firmware/acpi/platform_profile && echo yes || echo no)"

    private=/sys/devices/platform/asus_zenbook_a14_ec/profile
    for standard in balanced quiet performance max-power balanced; do
        say ""
        say "----- standard profile: $standard -----"
        printf '%s\n' "$standard" > "$PP_NODE/profile" 2>/dev/null
        rc=$?
        sleep 1
        class_value=$(cat "$PP_NODE/profile" 2>/dev/null)
        private_value=$(cat "$private" 2>/dev/null)
        say "write_rc=$rc class=$class_value private=$private_value"
        if [ "$rc" -ne 0 ]; then
            ok=0
            break
        fi
        if [ "$standard" = max-power ]; then
            expected=full-speed
        else
            expected=$standard
        fi
        if [ "$class_value" != "$standard" ] || [ "$private_value" != "$expected" ]; then
            say "ERROR: standard/private profile mapping mismatch expected_private=$expected"
            ok=0
            break
        fi
    done
fi

restore_balanced

say ""
say "===== KERNEL LOG ====="
journalctl -k --since '-2 minutes' --no-pager 2>/dev/null | \
    grep -Ei 'platform.profile|platform_profile|asus_zenbook_a14_ec' | tail -n 120 || true

say ""
if [ "$ok" -eq 1 ]; then
    say "A14_PLATFORM_PROFILE_DT_VALIDATION=PASS"
else
    say "A14_PLATFORM_PROFILE_DT_VALIDATION=FAIL"
fi
say "patched_platform_profile_left_loaded=$loaded_pp"
say "local_ec_left_loaded=$loaded_ec"
say "final_profile=balanced_requested"

true
