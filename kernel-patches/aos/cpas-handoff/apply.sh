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
binding='Documentation/devicetree/bindings/media/qcom,x1e80100-camss.yaml'

[ -f "$src/Makefile" ] || {
    echo "Kernel top-level Makefile is missing from $src" >&2
    exit 2
}
[ -f "$src/drivers/media/platform/qcom/camss/camss.c" ] || {
    echo "CAMSS source is missing from $src" >&2
    exit 2
}
[ -f "$src/drivers/i2c/busses/i2c-qcom-cci.c" ] || {
    echo "Qualcomm CCI source is missing from $src" >&2
    exit 2
}
[ -f "$src/arch/arm64/boot/dts/qcom/x1e80100-asus-zenbook-a14.dts" ] || {
    echo "The A14 DTS is missing from $src" >&2
    exit 2
}

if ! grep -Rqs 'camss:[[:space:]]*isp@acb7000' \
        "$src/arch/arm64/boot/dts/qcom"; then
    cat >&2 <<'MSG'
The source tree does not contain Ubuntu's camera-enabled X1E80100 CAMSS node.
Do not apply the A14 resource override to a tree without the existing camera
node and endpoints.
MSG
    exit 1
fi

patches="
$series/0001-dt-bindings-media-qcom-x1e80100-camss-add-cpas-top.patch
$series/0002-media-qcom-camss-add-aon-ownership-handoff.patch
$series/0003-arm64-dts-qcom-hamoa-add-cpas-top.patch
$series/0004-media-qcom-camss-treat-aon-mux-as-write-only.patch
$series/0005-media-qcom-camss-quarantine-direct-aon-mmio.patch
$series/0006-media-qcom-camss-own-aos-icp-platform-clocks.patch
$series/0007-i2c-qcom-cci-add-platform-clock-hold-api.patch
$series/0008-i2c-qcom-cci-fail-closed-on-hold-restore-error.patch
"

rollback() {
    for entry in $applied; do
        mode=${entry%%|*}
        applied_patch=${entry#*|}
        case "$mode" in
            full)
                git -C "$src" apply -R "$applied_patch" || true
                ;;
            no-binding)
                git -C "$src" apply -R --exclude="$binding" "$applied_patch" || true
                ;;
        esac
    done
}

# The production patch files remain complete and are validated against upstream
# Linux in CI. Ubuntu's qcom-x1e source can carry downstream schema changes that
# make only the DT-binding hunks context-incompatible. Those schema hunks are
# not part of the runtime module/DTB result, so if and only if a full application
# fails for patch 0001 or 0006, retry without the binding file. Code and DTS
# hunks still must apply exactly, and runtime postconditions are checked below.
applied=""
schema_patch_state=full
for patch in $patches; do
    [ -s "$patch" ] || { echo "Missing patch: $patch" >&2; rollback; exit 1; }
    base=$(basename "$patch")
    mode=full

    if git -C "$src" apply --check "$patch"; then
        :
    else
        case "$base" in
            0001-dt-bindings-media-qcom-x1e80100-camss-add-cpas-top.patch)
                printf '%s\n' 'Binding patch does not match this downstream kernel; runtime build does not require schema modification.'
                printf '%s\n' 'schema_patch_0001=skipped-runtime-only'
                schema_patch_state=runtime-skipped
                continue
                ;;
            0006-media-qcom-camss-own-aos-icp-platform-clocks.patch)
                if git -C "$src" apply --check --exclude="$binding" "$patch"; then
                    mode=no-binding
                    schema_patch_state=runtime-skipped
                    printf '%s\n' 'schema_patch_0006=skipped-runtime-only'
                else
                    echo "Patch does not apply cleanly even with only the schema hunk excluded: $patch" >&2
                    rollback
                    exit 1
                fi
                ;;
            *)
                echo "Patch does not apply cleanly: $patch" >&2
                rollback
                exit 1
                ;;
        esac
    fi

    case "$mode" in
        full)
            git -C "$src" apply "$patch" || {
                echo "Failed to apply patch: $patch" >&2
                rollback
                exit 1
            }
            ;;
        no-binding)
            git -C "$src" apply --exclude="$binding" "$patch" || {
                echo "Failed to apply runtime portions of patch: $patch" >&2
                rollback
                exit 1
            }
            ;;
    esac

    applied="$mode|$patch
$applied"
done

camss="$src/drivers/media/platform/qcom/camss/camss.c"
camss_h="$src/drivers/media/platform/qcom/camss/camss.h"
cci="$src/drivers/i2c/busses/i2c-qcom-cci.c"
aos_dtsi="$src/arch/arm64/boot/dts/qcom/x1e80100-asus-zenbook-a14-aos.dtsi"

for required in "$camss" "$camss_h" "$cci" "$aos_dtsi"; do
    [ -s "$required" ] || {
        echo "Runtime ownership postcondition file is missing: $required" >&2
        rollback
        exit 1
    }
done

grep -q 'cpas-top' "$aos_dtsi" || { echo 'Runtime DTS lacks cpas-top' >&2; rollback; exit 1; }
grep -q 'CAM_CC_ICP_AHB_CLK' "$aos_dtsi" || { echo 'Runtime DTS lacks ICP AHB clock' >&2; rollback; exit 1; }
grep -q 'CAM_CC_ICP_CLK' "$aos_dtsi" || { echo 'Runtime DTS lacks ICP clock' >&2; rollback; exit 1; }
grep -q 'aon_platform_clks\[0\].id = "icp_ahb"' "$camss" || { echo 'CAMSS lacks ICP AHB ownership handle' >&2; rollback; exit 1; }
grep -q 'aon_platform_clks\[1\].id = "icp"' "$camss" || { echo 'CAMSS lacks ICP ownership handle' >&2; rollback; exit 1; }
grep -q 'return -EOPNOTSUPP' "$camss" || { echo 'CAMSS AON provider is not fail-closed' >&2; rollback; exit 1; }
grep -q 'qcom_cci_platform_hold_get' "$cci" || { echo 'CCI owner API is missing' >&2; rollback; exit 1; }
grep -q 'platform_hold_faulted' "$cci" || { echo 'CCI fail-closed restore state is missing' >&2; rollback; exit 1; }

printf 'schema_patch_state=%s\n' "$schema_patch_state"
printf '%s\n' 'runtime_ownership_postconditions=validated'

cat <<MSG
Applied the A14 CAMSS AOS handoff series to:
  $src

The direct CPAS MMIO handoff is quarantined because both reads and writes reset
this platform. The provider returns -EOPNOTSUPP before direct MMIO until the
correct firmware-mediated or platform-specific access mechanism is implemented.

Stage A represents the Windows F0 ICP pair as optional CAMSS-owned clock handles
(icp_ahb / icp). Those clocks are not prepared, enabled or rate-changed by the
production path.

Stage B adds a CCI-owned, reference-counted platform clock-hold API with exact
rate/restore validation and transfer exclusion. Restore failures latch the CCI
owner fail-closed so normal I2C cannot resume with uncertain timing. No CAMSS or
AOS caller is wired to that API yet, so applying this series does not create a
platform hold.

Next required validations:
  make ARCH=arm64 dt_binding_check DT_SCHEMA_FILES=qcom,x1e80100-camss.yaml
  build the Ubuntu A14 DTB, qcom-camss and i2c-qcom-cci
  confirm the Stage A/B ownership plumbing compiles cleanly
  use the isolated no-MMIO/no-SSC Stage C diagnostic before any ICP activation

No boot files or installed kernel packages were changed.
MSG
