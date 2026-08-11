#!/usr/bin/env python3
"""Extend the isolated Stage-C CAMSS diagnostic with a bounded hold duration.

This transforms only the generated diagnostic CAMSS source. Production CAMSS
remains unchanged. No CPAS access or SSC code is added here.
"""

from __future__ import annotations

import sys
from pathlib import Path

MARKER = "A14-F0-SSC-HANDSHAKE-DIAG extension"


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        fail(f"expected one {label} anchor, found {count}")
    return text.replace(old, new, 1)


def main() -> int:
    if len(sys.argv) != 2:
        fail("usage: a14-aos-f0-ssc-handshake-extend.py /path/to/generated/camss.c")

    path = Path(sys.argv[1])
    if not path.is_file():
        fail(f"CAMSS source was not found: {path}")

    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        print("f0_ssc_handshake_extension=already-present")
        return 0

    for required in (
        "AON-F0-ICP-OWNER-DIAG begin",
        "static struct a14_f0_icp_owner_diag a14_f0_icp_owner_diag;",
        "static DEVICE_ATTR_WO(a14_f0_icp_owner_probe);",
        "msleep(250);",
    ):
        if required not in text:
            fail(f"Stage-C diagnostic prerequisite is missing: {required}")

    # Keep the normal Stage-C default exactly 250 ms. The dedicated handshake
    # runner may raise it, but only up to five seconds and only before a run.
    text = replace_once(
        text,
        "\tint round_status;\n\tbool ready;\n",
        "\tint round_status;\n\tunsigned int hold_ms;\n\tbool ready;\n",
        "diagnostic state",
    )

    text = replace_once(
        text,
        "\tdev_emerg(dev,\n"
        "\t\t  \"AON-F0-ICP-OWNER-DIAG targets-ok hold-ms=250 cci0=37500000 cci1=37500000 icp_ahb=80000000 icp=400000000 direct-mmio=false ssc=false\\n\");\n"
        "\tmsleep(250);\n",
        "\tdev_emerg(dev,\n"
        "\t\t  \"AON-F0-ICP-OWNER-DIAG targets-ok hold-ms=%u cci0=37500000 cci1=37500000 icp_ahb=80000000 icp=400000000 direct-mmio=false ssc-external-only=true\\n\",\n"
        "\t\t  diag->hold_ms);\n"
        "\tmsleep(diag->hold_ms);\n",
        "target hold",
    )

    hold_attr = r'''
/* A14-F0-SSC-HANDSHAKE-DIAG extension
 * The default remains the already-tested 250 ms Stage-C hold. Only the
 * isolated SSC handshake runner raises this temporarily. The upper bound is
 * deliberately small so a failed userspace coordinator cannot leave the
 * diagnostic resource state held indefinitely.
 */
static ssize_t a14_f0_icp_owner_hold_ms_show(struct device *dev,
					     struct device_attribute *attr,
					     char *buf)
{
	struct a14_f0_icp_owner_diag *diag = &a14_f0_icp_owner_diag;
	unsigned int value;

	mutex_lock(&diag->lock);
	value = diag->hold_ms;
	mutex_unlock(&diag->lock);
	return sysfs_emit(buf, "%u\n", value);
}

static ssize_t a14_f0_icp_owner_hold_ms_store(struct device *dev,
					      struct device_attribute *attr,
					      const char *buf, size_t count)
{
	struct a14_f0_icp_owner_diag *diag = &a14_f0_icp_owner_diag;
	unsigned int value;
	int ret;

	ret = kstrtouint(buf, 0, &value);
	if (ret)
		return ret;
	if (value < 250 || value > 5000)
		return -ERANGE;

	mutex_lock(&diag->lock);
	diag->hold_ms = value;
	mutex_unlock(&diag->lock);
	return count;
}
static DEVICE_ATTR_RW(a14_f0_icp_owner_hold_ms);

'''
    text = replace_once(
        text,
        "static DEVICE_ATTR_WO(a14_f0_icp_owner_probe);\n\nstatic struct attribute *a14_f0_icp_owner_diag_attrs[] = {\n",
        "static DEVICE_ATTR_WO(a14_f0_icp_owner_probe);\n\n"
        + hold_attr
        + "static struct attribute *a14_f0_icp_owner_diag_attrs[] = {\n",
        "hold attribute insertion",
    )

    text = replace_once(
        text,
        "\t&dev_attr_a14_f0_icp_owner_status.attr,\n\t&dev_attr_a14_f0_icp_owner_probe.attr,\n",
        "\t&dev_attr_a14_f0_icp_owner_status.attr,\n"
        "\t&dev_attr_a14_f0_icp_owner_hold_ms.attr,\n"
        "\t&dev_attr_a14_f0_icp_owner_probe.attr,\n",
        "diagnostic attribute table",
    )

    text = replace_once(
        text,
        "\t\tdiag->round_status = 0;\n\t\tdiag->failed_clock = NULL;\n",
        "\t\tdiag->round_status = 0;\n\t\tdiag->hold_ms = 250;\n\t\tdiag->failed_clock = NULL;\n",
        "diagnostic initialization",
    )

    if MARKER not in text:
        fail("extension marker is missing after transformation")
    if "msleep(250);" in text:
        fail("hard-coded Stage-C hold remains after transformation")

    path.write_text(text, encoding="utf-8")
    print("f0_ssc_handshake_extension=applied")
    print("default_hold_ms=250")
    print("maximum_hold_ms=5000")
    print("direct_cpas_mmio_added=false")
    print("ssc_code_added_to_camss=false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
