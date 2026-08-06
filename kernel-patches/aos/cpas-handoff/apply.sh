#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

usage() {
    echo "Usage: $0 /path/to/linux-source" >&2
}

[ "$#" -eq 1 ] || { usage; exit 2; }
src=$(CDPATH= cd -- "$1" 2>/dev/null && pwd) || {
    echo "Kernel source directory not found: $1" >&2
    exit 2
}
series=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

[ -f "$src/Makefile" ] || {
    echo "Kernel top-level Makefile is missing from $src" >&2
    exit 2
}
[ -f "$src/drivers/media/platform/qcom/camss/camss.c" ] || {
    echo "CAMSS source is missing from $src" >&2
    exit 2
}
[ -f "$src/arch/arm64/boot/dts/qcom/x1e80100-asus-zenbook-a14.dts" ] || {
    echo "The A14 DTS is missing from $src" >&2
    exit 2
}

if ! grep -Rqs 'camss:[[:space:]]*isp@acb7000' \
        "$src/arch/arm64/boot/dts/qcom"; then
    cat >&2 <<'EOF'
The source tree does not contain Ubuntu's camera-enabled X1E80100 CAMSS node.
Do not apply the A14 resource override to a tree without the existing camera
node and endpoints.
EOF
    exit 1
fi

patches="
$series/0001-dt-bindings-media-qcom-x1e80100-camss-add-cpas-top.patch
$series/0002-media-qcom-camss-add-aon-ownership-handoff.patch
$series/0003-arm64-dts-qcom-hamoa-add-cpas-top.patch
$series/0004-media-qcom-camss-treat-aon-mux-as-write-only.patch
$series/0005-media-qcom-camss-quarantine-direct-aon-mmio.patch
"

for patch in $patches; do
    [ -s "$patch" ] || { echo "Missing patch: $patch" >&2; exit 1; }
    if ! git -C "$src" apply --check "$patch"; then
        echo "Patch does not apply cleanly: $patch" >&2
        exit 1
    fi
done

for patch in $patches; do
    git -C "$src" apply "$patch"
done

cat <<EOF
Applied the A14 CAMSS AOS handoff series to:
  $src

The direct CPAS MMIO handoff is quarantined because both reads and writes reset
this platform. The provider currently returns -EOPNOTSUPP until the correct
firmware-mediated or platform-specific access mechanism is implemented.

Next required validations:
  make ARCH=arm64 dt_binding_check DT_SCHEMA_FILES=qcom,x1e80100-camss.yaml
  build the Ubuntu A14 DTB and qcom-camss module
  identify the Windows camera-platform access prerequisite or mediated path
  replace the quarantine only after a non-resetting hardware access is proven

No boot files or installed kernel packages were changed.
EOF
