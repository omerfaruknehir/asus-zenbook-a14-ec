#!/usr/bin/env python3
"""Inject the staged A14 Windows-F0 clock-rate subset probe into stock CAMSS."""

from __future__ import annotations

import sys
from pathlib import Path
from typing import NoReturn

MARKER = "AON-F0-RATE-DIAG begin phase="


def fail(message: str) -> NoReturn:
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
        fail("usage: a14-aos-f0-rate-diag-inject.py /path/to/camss.c")

    path = Path(sys.argv[1])
    if not path.is_file():
        fail(f"CAMSS source was not found: {path}")

    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        print("f0_rate_diagnostic_injection=already-present")
        return 0

    for retired in (
        "aon_diag_stage",
        "AON-DIAG stage=",
        "ap-write-no-read",
        "aon-switch-restore-no-read",
        "AON-POWER-DIAG begin",
    ):
        if retired in text:
            fail(f"refusing to modify source containing another diagnostic marker: {retired}")

    text = add_include(text, "linux/delay.h", "#include <linux/clk.h>\n")
    text = add_include(text, "linux/err.h", "#include <linux/delay.h>\n")
    text = add_include(text, "linux/kstrtox.h", "#include <linux/interconnect.h>\n")
    text = add_include(text, "linux/mutex.h", "#include <linux/media.h>\n")
    text = add_include(text, "linux/pm_runtime.h", "#include <linux/mutex.h>\n")

    definitions = r'''
#define A14_F0_RATE_CLK_COUNT 7
#define A14_F0_RATE_TARGET_COUNT 5

static const char * const a14_f0_rate_clk_ids[A14_F0_RATE_CLK_COUNT] = {
	"camnoc_rt_axi",
	"camnoc_nrt_axi",
	"cpas_ahb",
	"core_ahb",
	"cpas_fast_ahb",
	"gcc_axi_hf",
	"gcc_axi_sf",
};

static const unsigned long a14_f0_rate_targets[A14_F0_RATE_TARGET_COUNT] = {
	300000000,
	300000000,
	80000000,
	80000000,
	100000000,
};

struct a14_f0_rate_diag {
	struct clk_bulk_data clks[A14_F0_RATE_CLK_COUNT];
	struct mutex lock;
	const char *failed_clock;
	int clock_get_status;
	int round_status;
	bool ready;
};

static struct a14_f0_rate_diag a14_f0_diag;

'''
    text = replace_once(
        text,
        "static const struct parent_dev_ops vfe_parent_dev_ops;\n",
        definitions + "static const struct parent_dev_ops vfe_parent_dev_ops;\n",
        "CAMSS definitions",
    )

    implementation = r'''
static bool a14_f0_rate_phase_uses_clock(unsigned int phase, unsigned int index)
{
	if (phase == 1)
		return index < 2;
	if (phase == 2)
		return index >= 2 && index < 5;
	if (phase == 3)
		return index < 5;
	return false;
}

static int a14_f0_rate_restore(struct device *dev,
			       struct a14_f0_rate_diag *diag,
			       const unsigned long *original_rates,
			       const bool *changed)
{
	int first_error = 0;
	int i;

	for (i = A14_F0_RATE_TARGET_COUNT - 1; i >= 0; i--) {
		unsigned long actual;
		int ret;

		if (!changed[i])
			continue;

		ret = clk_set_rate(diag->clks[i].clk, original_rates[i]);
		actual = clk_get_rate(diag->clks[i].clk);
		dev_emerg(dev,
			  "AON-F0-RATE-DIAG restore clock=%s target=%lu actual=%lu ret=%d\n",
			  diag->clks[i].id, original_rates[i], actual, ret);
		if (ret && !first_error)
			first_error = ret;
		else if (!ret && actual != original_rates[i] && !first_error)
			first_error = -ERANGE;
	}

	return first_error;
}

static int a14_camss_f0_rate_probe(struct device *dev, unsigned int phase)
{
	struct a14_f0_rate_diag *diag = &a14_f0_diag;
	struct camss *camss = dev_get_drvdata(dev);
	unsigned long original_rates[A14_F0_RATE_CLK_COUNT] = { 0 };
	bool changed[A14_F0_RATE_TARGET_COUNT] = { false };
	bool clocks_held = false;
	bool pm_held = false;
	int restore_ret = 0;
	unsigned int i;
	int ret = 0;

	if (!camss || !diag->ready)
		return -ENODEV;
	if (phase < 1 || phase > 3)
		return -EINVAL;

	mutex_lock(&diag->lock);
	if (diag->clock_get_status) {
		ret = diag->clock_get_status;
		dev_emerg(dev,
			  "AON-F0-RATE-DIAG unavailable reason=clock-lookup clock=%s ret=%d\n",
			  diag->failed_clock ?: "unknown", ret);
		goto out_unlock;
	}
	if (diag->round_status) {
		ret = diag->round_status;
		dev_emerg(dev,
			  "AON-F0-RATE-DIAG unavailable reason=round-rate clock=%s ret=%d\n",
			  diag->failed_clock ?: "unknown", ret);
		goto out_unlock;
	}
	if (!pm_runtime_suspended(dev)) {
		ret = -EBUSY;
		dev_emerg(dev,
			  "AON-F0-RATE-DIAG unavailable reason=runtime-not-suspended registered-video-refs=%d ret=%d\n",
			  atomic_read(&camss->ref_count), ret);
		goto out_unlock;
	}

	dev_emerg(dev,
		  "AON-F0-RATE-DIAG begin phase=%u direct-mmio=false ssc=false registered-video-refs=%d\n",
		  phase, atomic_read(&camss->ref_count));

	ret = pm_runtime_resume_and_get(dev);
	if (ret < 0) {
		dev_emerg(dev, "AON-F0-RATE-DIAG runtime-pm failed phase=%u ret=%d\n",
			  phase, ret);
		goto out_unlock;
	}
	pm_held = true;
	dev_emerg(dev,
		  "AON-F0-RATE-DIAG runtime-pm ok phase=%u top-gdsc=true icc-votes=true\n",
		  phase);

	ret = clk_bulk_prepare_enable(A14_F0_RATE_CLK_COUNT, diag->clks);
	if (ret) {
		dev_emerg(dev,
			  "AON-F0-RATE-DIAG platform-clocks failed phase=%u ret=%d\n",
			  phase, ret);
		goto out_release;
	}
	clocks_held = true;

	for (i = 0; i < A14_F0_RATE_CLK_COUNT; i++) {
		original_rates[i] = clk_get_rate(diag->clks[i].clk);
		dev_emerg(dev,
			  "AON-F0-RATE-DIAG original phase=%u clock=%s rate=%lu\n",
			  phase, diag->clks[i].id, original_rates[i]);
	}

	for (i = 0; i < A14_F0_RATE_TARGET_COUNT; i++) {
		unsigned long actual;

		if (!a14_f0_rate_phase_uses_clock(phase, i))
			continue;

		ret = clk_set_rate(diag->clks[i].clk, a14_f0_rate_targets[i]);
		actual = clk_get_rate(diag->clks[i].clk);
		dev_emerg(dev,
			  "AON-F0-RATE-DIAG set phase=%u clock=%s target=%lu actual=%lu ret=%d\n",
			  phase, diag->clks[i].id, a14_f0_rate_targets[i], actual, ret);
		if (ret)
			goto out_restore;
		changed[i] = true;
		if (actual != a14_f0_rate_targets[i]) {
			ret = -ERANGE;
			dev_emerg(dev,
				  "AON-F0-RATE-DIAG verify failed phase=%u clock=%s target=%lu actual=%lu ret=%d\n",
				  phase, diag->clks[i].id, a14_f0_rate_targets[i], actual, ret);
			goto out_restore;
		}
	}

	dev_emerg(dev,
		  "AON-F0-RATE-DIAG phase=%u targets-ok hold-ms=250\n", phase);
	msleep(250);

out_restore:
	restore_ret = a14_f0_rate_restore(dev, diag, original_rates, changed);
	if (!ret && restore_ret)
		ret = restore_ret;
out_release:
	if (clocks_held)
		clk_bulk_disable_unprepare(A14_F0_RATE_CLK_COUNT, diag->clks);
	if (pm_held)
		pm_runtime_put(dev);
	dev_emerg(dev,
		  "AON-F0-RATE-DIAG complete phase=%u ret=%d restore-ret=%d direct-mmio=false ssc=false runtime-suspended=%u\n",
		  phase, ret, restore_ret, pm_runtime_suspended(dev));
out_unlock:
	mutex_unlock(&diag->lock);
	return ret;
}

static ssize_t a14_f0_rate_status_show(struct device *dev,
				       struct device_attribute *attr,
				       char *buf)
{
	struct a14_f0_rate_diag *diag = &a14_f0_diag;
	struct camss *camss = dev_get_drvdata(dev);
	int registered_video_refs = camss ? atomic_read(&camss->ref_count) : -1;

	return sysfs_emit(buf,
			  "ready=%u clock_get_status=%d round_status=%d failed_clock=%s initialization=post-probe-success runtime_suspended=%u registered_video_refs=%d phases=1,2,3\n",
			  diag->ready, diag->clock_get_status, diag->round_status,
			  diag->failed_clock ?: "none", pm_runtime_suspended(dev),
			  registered_video_refs);
}
static DEVICE_ATTR_RO(a14_f0_rate_status);

static ssize_t a14_f0_rate_probe_store(struct device *dev,
				       struct device_attribute *attr,
				       const char *buf, size_t count)
{
	unsigned int phase;
	int ret;

	ret = kstrtouint(buf, 0, &phase);
	if (ret)
		return ret;
	if (phase < 1 || phase > 3)
		return -EINVAL;

	ret = a14_camss_f0_rate_probe(dev, phase);
	return ret ? ret : count;
}
static DEVICE_ATTR_WO(a14_f0_rate_probe);

static struct attribute *a14_f0_rate_diag_attrs[] = {
	&dev_attr_a14_f0_rate_status.attr,
	&dev_attr_a14_f0_rate_probe.attr,
	NULL,
};

static const struct attribute_group a14_f0_rate_diag_group = {
	.name = "a14_f0_rate_diag",
	.attrs = a14_f0_rate_diag_attrs,
};

'''
    text = replace_once(
        text,
        "static const struct camss_subdev_resources csiphy_res_8x16[] = {\n",
        implementation + "static const struct camss_subdev_resources csiphy_res_8x16[] = {\n",
        "CAMSS resource-table",
    )

    probe_block = r'''
	if (camss->res->version == CAMSS_X1E80100) {
		struct a14_f0_rate_diag *diag = &a14_f0_diag;
		unsigned int i;
		int diag_ret;

		mutex_init(&diag->lock);
		diag->ready = false;
		diag->clock_get_status = 0;
		diag->round_status = 0;
		diag->failed_clock = NULL;

		for (i = 0; i < A14_F0_RATE_CLK_COUNT; i++) {
			diag->clks[i].id = a14_f0_rate_clk_ids[i];
			diag->clks[i].clk = devm_clk_get(dev, diag->clks[i].id);
			if (IS_ERR(diag->clks[i].clk)) {
				diag_ret = PTR_ERR(diag->clks[i].clk);
				diag->clks[i].clk = NULL;
				if (!diag->clock_get_status) {
					diag->clock_get_status = diag_ret;
					diag->failed_clock = diag->clks[i].id;
				}
				dev_warn(dev,
					 "A14 F0 rate diagnostic clock lookup failed clock=%s ret=%d\n",
					 diag->clks[i].id, diag_ret);
			}
		}

		if (!diag->clock_get_status) {
			for (i = 0; i < A14_F0_RATE_TARGET_COUNT; i++) {
				long rounded = clk_round_rate(diag->clks[i].clk,
							   a14_f0_rate_targets[i]);

				if (rounded < 0 || rounded != a14_f0_rate_targets[i]) {
					diag->round_status = rounded < 0 ? (int)rounded : -ERANGE;
					diag->failed_clock = diag->clks[i].id;
					dev_warn(dev,
						 "A14 F0 rate diagnostic exact-rate check failed clock=%s target=%lu rounded=%ld ret=%d\n",
						 diag->clks[i].id, a14_f0_rate_targets[i], rounded,
						 diag->round_status);
					break;
				}
			}
		}

		diag->ready = true;
		diag_ret = devm_device_add_group(dev, &a14_f0_rate_diag_group);
		if (diag_ret) {
			diag->ready = false;
			dev_warn(dev,
				 "failed to add A14 F0 rate diagnostic: %d\n", diag_ret);
		} else if (diag->clock_get_status || diag->round_status) {
			dev_warn(dev,
				 "A14 F0 rate diagnostic unavailable clock=%s clock-ret=%d round-ret=%d initialization=post-probe-success\n",
				 diag->failed_clock ?: "unknown", diag->clock_get_status,
				 diag->round_status);
		} else {
			dev_warn(dev,
				 "A14 staged F0 rate diagnostic available clocks=7 targets=5 phases=3 initialization=post-probe-success idle-guard=runtime-suspended\n");
		}
	}
'''
    text = replace_once(
        text,
        "\treturn 0;\n\nerr_media_device_unregister:\n",
        probe_block + "\n\treturn 0;\n\nerr_media_device_unregister:\n",
        "successful camss_probe completion",
    )

    if MARKER not in text:
        fail("injection marker is missing after transformation")
    path.write_text(text, encoding="utf-8")
    print("f0_rate_diagnostic_injection=applied")
    print("diagnostic_initialization=post-probe-success")
    print("diagnostic_idle_guard=runtime-suspended")
    print("phase_1=camnoc-300mhz")
    print("phase_2=ahb-80-80-100mhz")
    print("phase_3=combined-five-targets")
    print("direct_cpas_mmio=false")
    print("ssc_contact=false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
