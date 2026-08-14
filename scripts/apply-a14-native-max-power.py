#!/usr/bin/env python3
from pathlib import Path

p = Path('asus_zenbook_a14_ec.c')
s = p.read_text()


def once(old: str, new: str, label: str) -> None:
    global s
    if new in s:
        return
    count = s.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected one source anchor, found {count}')
    s = s.replace(old, new, 1)


# PLATFORM_PROFILE_MAX_POWER was merged for Linux 6.19.  The A14's local
# full-speed profile remains available on every supported kernel; older kernels
# project it as PERFORMANCE only because their standard ABI has no fourth
# high-power state.
once(
'''\tset_bit(PLATFORM_PROFILE_QUIET, choices);\n\tset_bit(PLATFORM_PROFILE_BALANCED, choices);\n\tset_bit(PLATFORM_PROFILE_PERFORMANCE, choices);\n''',
'''\tset_bit(PLATFORM_PROFILE_QUIET, choices);\n\tset_bit(PLATFORM_PROFILE_BALANCED, choices);\n\tset_bit(PLATFORM_PROFILE_PERFORMANCE, choices);\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 19, 0)\n\tset_bit(PLATFORM_PROFILE_MAX_POWER, choices);\n#endif\n''',
    'max-power platform choice',
)

once(
'''\tcase ASUS_EC_PROFILE_PERFORMANCE:\n\tcase ASUS_EC_PROFILE_FULL_SPEED:\n\t\t*profile = PLATFORM_PROFILE_PERFORMANCE;\n\t\tbreak;\n''',
'''\tcase ASUS_EC_PROFILE_PERFORMANCE:\n\t\t*profile = PLATFORM_PROFILE_PERFORMANCE;\n\t\tbreak;\n\tcase ASUS_EC_PROFILE_FULL_SPEED:\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 19, 0)\n\t\t*profile = PLATFORM_PROFILE_MAX_POWER;\n#else\n\t\t*profile = PLATFORM_PROFILE_PERFORMANCE;\n#endif\n\t\tbreak;\n''',
    'full-speed platform projection',
)

once(
'''\tcase PLATFORM_PROFILE_PERFORMANCE:\n\t\tmapped = ASUS_EC_PROFILE_PERFORMANCE;\n\t\tbreak;\n\tdefault:\n''',
'''\tcase PLATFORM_PROFILE_PERFORMANCE:\n\t\tmapped = ASUS_EC_PROFILE_PERFORMANCE;\n\t\tbreak;\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 19, 0)\n\tcase PLATFORM_PROFILE_MAX_POWER:\n\t\tmapped = ASUS_EC_PROFILE_FULL_SPEED;\n\t\tbreak;\n#endif\n\tdefault:\n''',
    'max-power platform setter',
)

p.write_text(s)
print('a14_native_max_power=applied')
