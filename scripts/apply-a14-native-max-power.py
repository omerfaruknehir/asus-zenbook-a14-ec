#!/usr/bin/env python3
from pathlib import Path

p = Path('asus_zenbook_a14_ec.c')
s = p.read_text()


def replace_required(old: str, new: str, label: str) -> None:
    global s
    count = s.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected one source anchor, found {count}')
    s = s.replace(old, new, 1)


# This transform is deliberately semantic rather than whole-block idempotent.
# A developer tree may already contain an older composed MAX_POWER projection
# while missing later policy-v2 transforms.  Treat each of the three MAX_POWER
# pieces independently so an upgrade can continue instead of failing because a
# previous generated block has slightly different surrounding context.

# 1. Advertise MAX_POWER where the kernel ABI supports it.
if 'set_bit(PLATFORM_PROFILE_MAX_POWER, choices);' not in s:
    replace_required(
        '''\tset_bit(PLATFORM_PROFILE_QUIET, choices);\n\tset_bit(PLATFORM_PROFILE_BALANCED, choices);\n\tset_bit(PLATFORM_PROFILE_PERFORMANCE, choices);\n''',
        '''\tset_bit(PLATFORM_PROFILE_QUIET, choices);\n\tset_bit(PLATFORM_PROFILE_BALANCED, choices);\n\tset_bit(PLATFORM_PROFILE_PERFORMANCE, choices);\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 19, 0)\n\tset_bit(PLATFORM_PROFILE_MAX_POWER, choices);\n#endif\n''',
        'max-power platform choice',
    )

# 2. Project the private full-speed state to MAX_POWER on modern kernels.
getter_current = (
    'case ASUS_EC_PROFILE_FULL_SPEED:' in s and
    '*profile = PLATFORM_PROFILE_MAX_POWER;' in s
)
if not getter_current:
    replace_required(
        '''\tcase ASUS_EC_PROFILE_PERFORMANCE:\n\tcase ASUS_EC_PROFILE_FULL_SPEED:\n\t\t*profile = PLATFORM_PROFILE_PERFORMANCE;\n\t\tbreak;\n''',
        '''\tcase ASUS_EC_PROFILE_PERFORMANCE:\n\t\t*profile = PLATFORM_PROFILE_PERFORMANCE;\n\t\tbreak;\n\tcase ASUS_EC_PROFILE_FULL_SPEED:\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 19, 0)\n\t\t*profile = PLATFORM_PROFILE_MAX_POWER;\n#else\n\t\t*profile = PLATFORM_PROFILE_PERFORMANCE;\n#endif\n\t\tbreak;\n''',
        'full-speed platform projection',
    )

# 3. Accept MAX_POWER writes and map them back to the A14 full-speed policy.
setter_current = (
    'case PLATFORM_PROFILE_MAX_POWER:' in s and
    'mapped = ASUS_EC_PROFILE_FULL_SPEED;' in s
)
if not setter_current:
    replace_required(
        '''\tcase PLATFORM_PROFILE_PERFORMANCE:\n\t\tmapped = ASUS_EC_PROFILE_PERFORMANCE;\n\t\tbreak;\n\tdefault:\n''',
        '''\tcase PLATFORM_PROFILE_PERFORMANCE:\n\t\tmapped = ASUS_EC_PROFILE_PERFORMANCE;\n\t\tbreak;\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 19, 0)\n\tcase PLATFORM_PROFILE_MAX_POWER:\n\t\tmapped = ASUS_EC_PROFILE_FULL_SPEED;\n\t\tbreak;\n#endif\n\tdefault:\n''',
        'max-power platform setter',
    )

required = (
    'set_bit(PLATFORM_PROFILE_MAX_POWER, choices);',
    '*profile = PLATFORM_PROFILE_MAX_POWER;',
    'case PLATFORM_PROFILE_MAX_POWER:',
    'mapped = ASUS_EC_PROFILE_FULL_SPEED;',
)
missing = [token for token in required if token not in s]
if missing:
    raise SystemExit('max-power transform incomplete: ' + ', '.join(missing))

p.write_text(s)
print('a14_native_max_power=current' if getter_current and setter_current else 'a14_native_max_power=applied')
