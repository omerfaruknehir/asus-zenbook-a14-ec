#!/usr/bin/env python3
"""Inject the A14 non-MMIO platform-power probe into a temporary CAMSS copy."""

from __future__ import annotations

import sys
from pathlib import Path

MARKER = "AON-POWER-DIAG begin direct-mmio=false ssc=false"


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"ERROR: {message}")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        fail(f"expected one {label} anchor, found {count}")
    return text.replace(old, new, 1)


def add_include(text: str, include: str, anchor: str) -> str:
    line = f"#include <{include}>\n"
    if line in text:
        return text
    return replace_once(text, anchor, anchor + line, f"include insertion for {include}")


def main() -> int:
    if len(sys.argv) != 2:
        fail("usage: a14-aos-power-diag-inject.py /path/to/camss.c")

    path = Path(sys.argv[1])
    if not path.is_file():
        fail(f"CAMSS source was not found: {path}")

    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        print("power_diagnostic_injection=already-present")
        return 0

    for retired in (
        "aon_diag_stage",
        "AON-DIAG stage=",
        "ap-write-no-read",
        "aon-switch-restore-no-read",
    ):
        if retired in text:
            fail(f"refusing to modify source containing retired diagnostic marker: {retired}")

    text = add_include(text, "linux/delay.h", "#include <linux/clk.h>\n")
    text = add_include(text, "linux/err.h", "#include <linux/delay.h>\n")
    text = add_include(text, "linux/kstrtox.h", "#include <linux/interconnect.h>\n")
    text = add_include(text, "linux/mutex.h", "#include <linux/media.h>\n")

    definitions = r"""
#define A14_AON_POWER_CLK_COUNT 7

static const char * const a14_aon_power_clk_ids[A14_AON_POWER_CLK_COUNT] = {
	"camnoc_rt_axi",
	"camnoc_nrt_axi",
	"cpas_ahb",
	"core_ahb",
	"cpas_fast_ahb",
	"gcc_axi_hf",
	"gcc_axi_sf",
};

struct a14_aon_power_diag {
	struct clk_bulk_data clks[A14_AON_POWER_CLK_COUNT];
	struct mutex lock;
	const char *failed_clock;
	int clock_get_status;
	bool ready;
};

static struct a14_aon_power_diag a14_power_diag;

"""
    text = replace_once(
        text,
        "static const struct parent_dev_ops vfe_parent_dev_ops;\n",
        definitions + "static const struct parent_dev_ops vfe_parent_dev_ops;\n",
        "CAMSS definitions",
    )

    implementation = r"""
static int a14_camss_aon_power_probe(struct device *dev)
{
	struct a14_aon_power_diag *diag = &a14_power_diag;
	struct camss *camss = dev_get_drvdata(dev);
	bool clocks_held = false;
	bool pm_held = false;
	unsigned int i;
	int ret = 0;

	if (!camss || !diag->ready)
		return -ENODEV;

	mutex_lock(&diag->lock);
	if (atomic_read(&camss->ref_count) != 0) {
		ret = -EBUSY;
		dev_emerg(dev,
			  "AON-POWER-DIAG unavailable reason=camss-busy ret=%d\n",
			  ret);
		goto out_unlock;
	}
	if (diag->clock_get_status) {
		ret = diag->clock_get_status;
		dev_emerg(dev,
			  "AON-POWER-DIAG unavailable reason=clock-lookup clock=%s ret=%d\n",
			  diag->failed_clock ?: "unknown", ret);
		goto out_unlock;
	}

	dev_emerg(dev,
		  "AON-POWER-DIAG begin direct-mmio=false ssc=false\n");

	ret = pm_runtime_resume_and_get(dev);
	if (ret < 0) {
		dev_emerg(dev,
			  "AON-POWER-DIAG runtime-pm failed ret=%d\n", ret);
		goto out_unlock;
	}
	pm_held = true;
	dev_emerg(dev,
		  "AON-POWER-DIAG runtime-pm ok top-gdsc=true icc-votes=true\n");

	ret = clk_bulk_prepare_enable(A14_AON_POWER_CLK_COUNT, diag->clks);
	if (ret) {
		dev_emerg(dev,
			  "AON-POWER-DIAG platform-clocks failed ret=%d\n",
			  ret);
		goto out_release;
	}
	clocks_held = true;

	for (i = 0; i < A14_AON_POWER_CLK_COUNT; i++)
		dev_emerg(dev,
			  "AON-POWER-DIAG clock=%s rate=%lu\n",
			  diag->clks[i].id,
			  clk_get_rate(diag->clks[i].clk));

	dev_emerg(dev,
		  "AON-POWER-DIAG platform-clocks ok hold-ms=250\n");
	msleep(250);

out_release:
	if (clocks_held)
		clk_bulk_disable_unprepare(A14_AON_POWER_CLK_COUNT, diag->clks);
	if (pm_held)
		pm_runtime_put(dev);
	dev_emerg(dev,
		  "AON-POWER-DIAG complete ret=%d direct-mmio=false ssc=false\n",
		  ret);
out_unlock:
	mutex_unlock(&diag->lock);
	return ret;
}

static ssize_t a14_aon_power_status_show(struct device *dev,
					 struct device_attribute *attr,
					 char *buf)
{
	struct a14_aon_power_diag *diag = &a14_power_diag;

	return sysfs_emit(buf,
			  "ready=%u clock_get_status=%d failed_clock=%s initialization=post-probe-success\n",
			  diag->ready, diag->clock_get_status,
			  diag->failed_clock ?: "none");
}
static DEVICE_ATTR_RO(a14_aon_power_status);

static ssize_t a14_aon_power_probe_store(struct device *dev,
					 struct device_attribute *attr,
					 const char *buf, size_t count)
{
	unsigned int trigger;
	int ret;

	ret = kstrtouint(buf, 0, &trigger);
	if (ret)
		return ret;
	if (trigger != 1)
		return -EINVAL;

	ret = a14_camss_aon_power_probe(dev);
	return ret ? ret : count;
}
static DEVICE_ATTR_WO(a14_aon_power_probe);

static struct attribute *a14_aon_power_diag_attrs[] = {
	&dev_attr_a14_aon_power_status.attr,
	&dev_attr_a14_aon_power_probe.attr,
	NULL,
};

static const struct attribute_group a14_aon_power_diag_group = {
	.name = "a14_aon_power_diag",
	.attrs = a14_aon_power_diag_attrs,
};

"""
    text = replace_once(
        text,
        "static const struct camss_subdev_resources csiphy_res_8x16[] = {\n",
        implementation + "static const struct camss_subdev_resources csiphy_res_8x16[] = {\n",
        "CAMSS resource-table",
    )

    probe_block = r"""
	if (camss->res->version == CAMSS_X1E80100) {
		struct a14_aon_power_diag *diag = &a14_power_diag;
		unsigned int i;
		int diag_ret;

		mutex_init(&diag->lock);
		diag->ready = false;
		diag->clock_get_status = 0;
		diag->failed_clock = NULL;

		for (i = 0; i < A14_AON_POWER_CLK_COUNT; i++) {
			diag->clks[i].id = a14_aon_power_clk_ids[i];
			diag->clks[i].clk = devm_clk_get(dev, diag->clks[i].id);
			if (IS_ERR(diag->clks[i].clk)) {
				diag_ret = PTR_ERR(diag->clks[i].clk);
				diag->clks[i].clk = NULL;
				if (!diag->clock_get_status) {
					diag->clock_get_status = diag_ret;
					diag->failed_clock = diag->clks[i].id;
				}
				dev_warn(dev,
					 "A14 power diagnostic clock lookup failed clock=%s ret=%d\n",
					 diag->clks[i].id, diag_ret);
			}
		}

		diag->ready = true;
		diag_ret = devm_device_add_group(dev, &a14_aon_power_diag_group);
		if (diag_ret) {
			diag->ready = false;
			dev_warn(dev,
				 "failed to add A14 power diagnostic: %d\n",
				 diag_ret);
		} else if (diag->clock_get_status) {
			dev_warn(dev,
				 "A14 non-MMIO platform-power diagnostic available clock=%s ret=%d initialization=post-probe-success\n",
				 diag->failed_clock, diag->clock_get_status);
		} else {
			dev_warn(dev,
				 "A14 non-MMIO platform-power diagnostic available clocks=7 initialization=post-probe-success\n");
		}
	}
"""
    text = replace_once(
        text,
        "\treturn 0;\n\nerr_media_device_unregister:\n",
        probe_block + "\n\treturn 0;\n\nerr_media_device_unregister:\n",
        "successful camss_probe completion",
    )

    if MARKER not in text:
        fail("injection marker is missing after transformation")
    path.write_text(text, encoding="utf-8")
    print("power_diagnostic_injection=applied")
    print("diagnostic_initialization=post-probe-success")
    print("direct_cpas_mmio=false")
    print("ssc_contact=false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
