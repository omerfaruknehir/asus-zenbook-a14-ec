#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Retired after direct reads and writes of the A14 AON mux reset the platform.
set -Eeuo pipefail

cat >&2 <<'EOF'
ERROR: the write-capable A14 AON diagnostic module has been retired.

Hardware validation established that both a read and an isolated write of the
AON mux can abruptly reset the ASUS Zenbook A14. Building another module that
exposes those sysfs stages would preserve a known platform-reset path.

The production CAMSS provider is quarantined and returns -EOPNOTSUPP before
MMIO. Continue by investigating the Windows camera-platform prerequisite or
firmware-mediated access path; do not recreate Stage 3 or run Stage 4.
EOF

exit 1
