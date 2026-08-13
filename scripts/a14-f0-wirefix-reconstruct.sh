#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Reconstruct the 7.1.5 full-F0 + corrected SSC wire-format retest tree.
set -Eeuo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo"

git fetch origin agent/aos-f0-ssc-handshake-probe agent/windows-re-hpd-protocol-fix

base=$(git merge-base \
    origin/agent/aos-f0-ssc-handshake-probe \
    origin/agent/windows-re-hpd-protocol-fix)

patch=$(mktemp)
trap 'rm -f "$patch"' EXIT

git diff "$base"..origin/agent/windows-re-hpd-protocol-fix -- \
    kernel/aos/qcom_ssc_hpd_internal.h \
    kernel/aos/qcom_ssc_hpd_protocol.c \
    kernel/aos/qcom_ssc_hpd_transport.c > "$patch"

# internal.h and protocol.c apply cleanly. transport.c intentionally conflicts
# because the F0 diagnostic branch owns the CAMSS acquire/release wrapper.
git apply --3way "$patch" || true

# Resolve transport deterministically: take the recovered Windows QMI transport
# and reinsert only the full-F0/CAMSS activation wrapper.
git show \
    origin/agent/windows-re-hpd-protocol-fix:kernel/aos/qcom_ssc_hpd_transport.c \
    > kernel/aos/qcom_ssc_hpd_transport.c

python3 - <<'PY'
from pathlib import Path
p = Path('kernel/aos/qcom_ssc_hpd_transport.c')
s = p.read_text()
marker = 'int a14_ssc_enable_hpd(struct a14_ssc_hpd *hpd)\n'
assert marker in s
prefix = s[:s.index(marker)]
func = r'''int a14_ssc_enable_hpd(struct a14_ssc_hpd *hpd)
{
	u8 data[256];
	size_t len;
	int ret;

	mutex_lock(&hpd->op_lock);
	mutex_lock(&hpd->lock);
	if (hpd->event_enabled) {
		ret = 0;
		goto out_unlock_state;
	}
	if (!hpd->connected || !hpd->handshake_suid.valid ||
	    !hpd->hpd_suid.valid) {
		ret = -EAGAIN;
		goto out_unlock_state;
	}
	reinit_completion(&hpd->handshake_ack_done);
	hpd->handshake_error = -EINPROGRESS;
	mutex_unlock(&hpd->lock);

	ret = a14_ssc_camss_acquire(hpd);
	if (ret) {
		dev_err(hpd->dev, "failed to hand camera path to AON: %d\n", ret);
		goto out_unlock_op;
	}

	len = a14_ssc_build_handshake_request(data, sizeof(data),
					     &hpd->handshake_suid);
	if (!len) {
		ret = -EINVAL;
		goto out_release_camss;
	}
	ret = send_control(hpd, data, len);
	if (ret)
		goto out_release_camss;
	if (!wait_for_completion_timeout(&hpd->handshake_ack_done,
					 A14_SSC_TIMEOUT)) {
		dev_err(hpd->dev, "camera handshake ACK 832 timed out\n");
		ret = -ETIMEDOUT;
		goto out_release_camss;
	}
	if (hpd->handshake_error) {
		ret = -EREMOTEIO;
		goto out_release_camss;
	}

	len = a14_ssc_build_hpd_request(data, sizeof(data), &hpd->hpd_suid);
	if (!len) {
		ret = -EINVAL;
		goto out_release_camss;
	}
	ret = send_control(hpd, data, len);
	if (ret)
		goto out_release_camss;

	mutex_lock(&hpd->lock);
	hpd->event_enabled = true;
	mutex_unlock(&hpd->lock);
	ret = 0;
	goto out_unlock_op;

out_unlock_state:
	mutex_unlock(&hpd->lock);
	goto out_unlock_op;
out_release_camss:
	a14_ssc_camss_release(hpd);
out_unlock_op:
	mutex_unlock(&hpd->op_lock);
	return ret;
}
'''
p.write_text(prefix + func)
PY

python3 - <<'PY'
from pathlib import Path
p = Path('kernel/aos/qcom_ssc_hpd_protocol.c')
s = p.read_text()
old = '\tpayload[p++] = 0x10;\n\tpayload[p++] = 0x00;\n\tpayload[p++] = 0x18;\n\tpayload[p++] = 0x02;\n'
new = '\tpayload[p++] = 0x10;\n\tpayload[p++] = 0x05;\n\tpayload[p++] = 0x18;\n\tpayload[p++] = 0x02;\n'
assert s.count(old) == 1
p.write_text(s.replace(old, new, 1))
PY

python3 - <<'PY'
from pathlib import Path
p = Path('scripts/a14-aos-stage-build.sh')
s = p.read_text()
s = s.replace("grep -qx 'CONFIG_QCOM_QMI_HELPERS=y' \"$config\" || fail \"QCOM QMI helpers are unavailable\"",
              "grep -Eq '^CONFIG_QCOM_QMI_HELPERS=[ym]$' \"$config\" || fail \"QCOM QMI helpers are unavailable\"")
s = s.replace("grep -qx 'CONFIG_IIO=m' \"$config\" || fail \"IIO is not modular as expected\"",
              "grep -Eq '^CONFIG_IIO=[ym]$' \"$config\" || fail \"IIO is unavailable\"")
old = '''source_pkg=$(dpkg-query -W -f='${source:Package}' "linux-image-$release" 2>/dev/null || true)
source_version=$(dpkg-query -W -f='${source:Version}' "linux-image-$release" 2>/dev/null || true)
[ -n "$source_pkg" ] || fail "could not resolve the source package for linux-image-$release"
[ -n "$source_version" ] || fail "could not resolve the source version for linux-image-$release"
'''
new = '''image_pkg=
for candidate in "linux-image-unsigned-$release" "linux-image-$release"; do
    status=$(dpkg-query -W -f='${db:Status-Abbrev}' "$candidate" 2>/dev/null || true)
    if [ "$status" = "ii " ]; then
        image_pkg=$candidate
        break
    fi
done
[ -n "$image_pkg" ] || fail "could not find an installed image package for $release"
source_pkg=$(dpkg-query -W -f='${source:Package}' "$image_pkg" 2>/dev/null || true)
source_version=$(dpkg-query -W -f='${source:Version}' "$image_pkg" 2>/dev/null || true)
if [ -z "$source_version" ]; then
    source_version=$(dpkg-query -W -f='${Version}' "$image_pkg" 2>/dev/null || true)
fi
[ -n "$source_pkg" ] || source_pkg=$image_pkg
[ -n "$source_version" ] || fail "could not resolve package version for $image_pkg"
printf 'image_package=%s\\n' "$image_pkg"
'''
assert old in s
p.write_text(s.replace(old, new, 1))
PY

python3 - <<'PY'
from pathlib import Path
p = Path('scripts/a14-aos-f0-ssc-handshake-run.sh')
s = p.read_text()
s = s.replace('for tool in awk cam cat date find fuser grep insmod journalctl lsmod mktemp rmmod \\\n            readlink rm seq sleep sort sudo sync systemctl tee timeout uname; do',
              'for tool in awk cam cat date find fuser grep insmod journalctl lsmod mktemp modprobe rmmod \\\n            readlink rm seq sleep sort sudo sync systemctl tee timeout uname; do')
old = "printf '\\n%s\\n' '===== LOAD MANUALLY-GATED HPD MODULE ====='\nsudo insmod \"$stage/qcom_ssc_hpd.ko\" allow_unrouted_handshake_probe=1\n"
new = "printf '\\n%s\\n' '===== LOAD SSC/IIO CORE DEPENDENCIES ====='\nsudo modprobe qmi_helpers\nsudo modprobe industrialio\nprintf '%s\\n' 'ssc_iio_dependencies=ready'\n\nprintf '\\n%s\\n' '===== LOAD MANUALLY-GATED HPD MODULE ====='\nsudo insmod \"$stage/qcom_ssc_hpd.ko\" allow_unrouted_handshake_probe=1\n"
assert old in s
p.write_text(s.replace(old, new, 1))
PY

git add \
    kernel/aos/qcom_ssc_hpd_internal.h \
    kernel/aos/qcom_ssc_hpd_protocol.c \
    kernel/aos/qcom_ssc_hpd_transport.c \
    scripts/a14-aos-stage-build.sh \
    scripts/a14-aos-f0-ssc-handshake-run.sh

git diff --cached --check

echo 'f0_wirefix_reconstruction=ready'
git status --short
