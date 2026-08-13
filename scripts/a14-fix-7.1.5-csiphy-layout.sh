#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Update the A14 AOS diagnostic/build stack for the 7.1.5 live CAMSS layout,
# where CSIPHY0/1/2 expose 0x2000-byte resource windows.
set -Eeuo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo"

python3 - <<'PY'
from pathlib import Path

files = [
    Path('scripts/a14-aos-stage-build.sh'),
    Path('kernel-patches/aos/cpas-handoff/0003-arm64-dts-qcom-hamoa-add-cpas-top.patch'),
    Path('scripts/a14-aos-f0-icp-owner-diag-build.sh'),
]

repls = [
    ('0x0ace4000,0x1000', '0x0ace4000,0x2000'),
    ('0x0ace6000,0x1000', '0x0ace6000,0x2000'),
    ('0x0ace8000,0x1000', '0x0ace8000,0x2000'),
    ('0x0ace4000 0 0x1000', '0x0ace4000 0 0x2000'),
    ('0x0ace6000 0 0x1000', '0x0ace6000 0 0x2000'),
    ('0x0ace8000 0 0x1000', '0x0ace8000 0 0x2000'),
]

changed = []
for p in files:
    s = p.read_text()
    before = s
    hits = 0
    for old, new in repls:
        c = s.count(old)
        if c:
            s = s.replace(old, new)
            hits += c
    if s != before:
        p.write_text(s)
        changed.append((str(p), hits))

expected = {
    'scripts/a14-aos-stage-build.sh',
    'kernel-patches/aos/cpas-handoff/0003-arm64-dts-qcom-hamoa-add-cpas-top.patch',
    'scripts/a14-aos-f0-icp-owner-diag-build.sh',
}
actual = {p for p, _ in changed}
missing = expected - actual
if missing:
    raise SystemExit(f'expected stale CSIPHY layout not found in: {sorted(missing)}')

for p, hits in changed:
    print(f'updated={p} replacements={hits}')
PY

# Fail if the old 0x1000 windows remain in the three runtime sources.
if grep -nE '0x0ace(4000|6000|8000)(,0x1000| 0 0x1000)' \
    scripts/a14-aos-stage-build.sh \
    kernel-patches/aos/cpas-handoff/0003-arm64-dts-qcom-hamoa-add-cpas-top.patch \
    scripts/a14-aos-f0-icp-owner-diag-build.sh; then
    echo 'ERROR: stale CSIPHY 0x1000 window remains' >&2
    exit 1
fi

# Require the new layout in every runtime copy.
for f in \
    scripts/a14-aos-stage-build.sh \
    kernel-patches/aos/cpas-handoff/0003-arm64-dts-qcom-hamoa-add-cpas-top.patch \
    scripts/a14-aos-f0-icp-owner-diag-build.sh; do
    grep -q '0x0ace4000.*0x2000' "$f"
    grep -q '0x0ace6000.*0x2000' "$f"
    grep -q '0x0ace8000.*0x2000' "$f"
done

git add \
    scripts/a14-aos-stage-build.sh \
    kernel-patches/aos/cpas-handoff/0003-arm64-dts-qcom-hamoa-add-cpas-top.patch \
    scripts/a14-aos-f0-icp-owner-diag-build.sh

git diff --cached --check

echo 'csiphy_layout_7_1_5=ready'
git status --short
