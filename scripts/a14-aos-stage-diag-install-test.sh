#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Retired after direct reads and writes of the A14 AON mux reset the platform.
set -Eeuo pipefail

cat >&2 <<'EOF'
ERROR: installation of the write-capable A14 AON diagnostic is blocked.

Do not install or boot an artifact whose BUILD-INFO lists either:
  3:ap-write-no-read
  4:aon-switch-restore-no-read

Stage 3 reset the platform before the sysfs write returned. Stage 4 was not run
and must remain disabled. Use the complete production CPAS patch series, whose
final quarantine patch returns -EOPNOTSUPP before direct MMIO.
EOF

exit 1
