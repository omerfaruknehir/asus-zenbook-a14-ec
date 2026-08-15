#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Build the A14 external modules while working around Ubuntu mainline header
# packages that contain a gendwarfksyms host executable for the wrong CPU.
set -eu

kernel=${1:-$(uname -r)}
kdir=${KDIR:-/lib/modules/$kernel/build}
module_dir=${A14_MODULE_DIR:-$(pwd)}
target=${A14_KBUILD_TARGET:-modules}

if [ ! -e "$kdir/Makefile" ]; then
    echo "Missing kernel build tree: $kdir" >&2
    exit 1
fi

native_machine()
{
    file=$1
    [ -f "$file" ] || return 1
    command -v readelf >/dev/null 2>&1 || return 1
    machine=$(LC_ALL=C readelf -h "$file" 2>/dev/null | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p' | head -n1)
    case "$(uname -m):$machine" in
        aarch64:AArch64|arm64:AArch64) return 0 ;;
        x86_64:*X86-64*) return 0 ;;
        riscv64:RISC-V) return 0 ;;
        ppc64le:*PowerPC64*) return 0 ;;
    esac
    return 1
}

same_gendwarf_sources()
{
    left=$1
    right=$2
    for f in gendwarfksyms.c gendwarfksyms.h cache.c die.c dwarf.c kabi.c symbols.c types.c; do
        [ -f "$left/$f" ] || return 1
        [ -f "$right/$f" ] || return 1
        cmp -s "$left/$f" "$right/$f" || return 1
    done
    return 0
}

broken="$kdir/scripts/gendwarfksyms/gendwarfksyms"
helper=

# CONFIG_GENDWARFKSYMS kernels execute this host-side program while compiling
# every module object. If the packaged helper is already native, leave Kbuild
# completely untouched.
if [ -x "$broken" ] && ! native_machine "$broken"; then
    broken_dir=$(dirname "$broken")
    broken_real=$(readlink -f "$broken" 2>/dev/null || printf '%s\n' "$broken")

    # Prefer another installed header tree whose native helper was built from
    # byte-identical sources. Linux v7.0 and v7.1 upstream gendwarfksyms sources
    # are identical, which makes the distro 7.0 ARM64 headers a valid donor for
    # a 7.1.x mainline header package when their checked-in sources also match.
    for candidate in /usr/src/linux-headers-*/scripts/gendwarfksyms/gendwarfksyms; do
        [ -x "$candidate" ] || continue
        candidate_real=$(readlink -f "$candidate" 2>/dev/null || printf '%s\n' "$candidate")
        [ "$candidate_real" = "$broken_real" ] && continue
        native_machine "$candidate" || continue
        same_gendwarf_sources "$broken_dir" "$(dirname "$candidate")" || continue
        helper=$candidate
        break
    done

    if [ -z "$helper" ]; then
        echo "Kernel headers contain a foreign-architecture gendwarfksyms:" >&2
        LC_ALL=C readelf -h "$broken" 2>/dev/null | grep -E 'Class:|Machine:' >&2 || true
        echo "No installed native helper with byte-identical sources was found." >&2
        echo "Install/retain an Ubuntu ARM64 7.0/7.1 header package or rebuild gendwarfksyms natively." >&2
        exit 126
    fi

    echo "A14 kbuild compatibility: packaged gendwarfksyms is not executable on $(uname -m)." >&2
    echo "A14 kbuild compatibility: using exact-source native helper: $helper" >&2
fi

if [ -n "$helper" ]; then
    # scripts/Makefile.build defines this as a recursively expanded make
    # variable. Preserve its dynamic symtypes/stable switches verbatim and only
    # replace the executable path.
    gd_override="$helper \$(if \$(KBUILD_SYMTYPES), --symtypes \$(@:.o=.symtypes)) \$(if \$(KBUILD_GENDWARFKSYMS_STABLE), --stable)"
    exec make -C "$kdir" M="$module_dir" "gendwarfksyms=$gd_override" "$target"
fi

exec make -C "$kdir" M="$module_dir" "$target"
