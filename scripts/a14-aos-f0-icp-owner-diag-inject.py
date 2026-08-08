#!/usr/bin/env python3
"""Inject the isolated A14 full-F0/ICP owner diagnostic into patched CAMSS."""

from __future__ import annotations

import sys
from pathlib import Path
from typing import NoReturn

MARKER = "AON-F0-ICP-OWNER-DIAG begin"


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
        fail("usage: a14-aos-f0-icp-owner-diag-inject.py /path/to/camss.c")

    path = Path(sys.argv[1])
    if not path.is_file():
        fail(f"CAMSS source was not found: {path}")

    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        print("f0_icp_owner_diagnostic_injection=already-present")
        return 0

    required = (
        "aon_platform_clks[0].id = \"icp_ahb\"",
        "aon_platform_clks[1].id = \"icp\"",
        "AON handoff unavailable: direct CPAS MMIO resets this platform",
    )
    for marker in required:
        if marker not in text:
            fail(f"production ownership prerequisite is missing: {marker}")

    for retired in (
        "aon_diag_stage",
        "AON-DIAG stage=",
        "ap-write-no-read",
        "aon-switch-restore-no-read",
        "AON-POWER-DIAG begin",
        "AON-F0-RATE-DIAG begin",
    ):
        if retired in text:
            fail(f"refusing to combine with another diagnostic marker: {retired}")

    text = add_include(text, "linux/delay.h", "#include <linux/clk.h>\n")
    text = add_include(text, "linux/device/bus.h", "#include <linux/delay.h>\n")
    text = add_include(text, "linux/i2c-qcom-cci.h", "#include <linux/interconnect.h>\n")
    text = add_include(text, "linux/kstrtox.h", "#include <linux/i2c-qcom-cci.h>\n")
    text = add_include(text, "linux/pm_runtime.h", "#include <linux/mutex.h>\n")

    definitions = r'''
#define A14_F0_OWNER_CAMSS_CLK_COUNT 7
#define A14_F0_OWNER_CAMSS_TARGET_COUNT 5
#define A14_F0_OWNER_ICP_CLK_COUNT 2
#define A14_F0_OWNER_CCI_RATE 37500000UL

static const char * const a14_f0_owner_camss_clk_ids[A14_F0_OWNER_CAMSS_CLK_COUNT] = {
	"camnoc_rt_axi",
	"camnoc_nrt_axi",
	"cpas_ahb",
	"core_ahb",
	"cpas_fast_ahb",
	"gcc_axi_hf",
	"gcc_axi_sf",
};

static const unsigned long a14_f0_owner_camss_targets[A14_F0_OWNER_CAMSS_TARGET_COUNT] = {
	300000000,
	300000000,
	80000000,
	80000000,
	100000000,
};

static const unsigned long a14_f0_owner_icp_targets[A14_F0_OWNER_ICP_CLK_COUNT] = {
	80000000,
	400000000,
};

struct a14_f0_icp_owner_diag {
	struct clk_bulk_data camss_clks[A14_F0_OWNER_CAMSS_CLK_COUNT];
	struct mutex lock;
	const char *failed_clock;
	int clock_get_status;
	int round_status;
	bool ready;
};

static struct a14_f0_icp_owner_diag a14_f0_icp_owner_diag;

'''
    text = replace_once(
        text,
        "static const struct parent_dev_ops vfe_parent_dev_ops;\n",
        definitions + "static const struct parent_dev_ops vfe_parent_dev_ops;\n",
        "CAMSS definitions",
    )

    implementation = r'''
static int a14_f0_owner_restore_camss(struct device *dev,
				      struct a14_f0_icp_owner_diag *diag,
				      const unsigned long *original_rates,
				      const bool *changed,
				      bool *camnoc_limited)
{
	int first_error = 0;
	int i;

	for (i = A14_F0_OWNER_CAMSS_TARGET_COUNT - 1; i >= 0; i--) {
		unsigned long actual;
		int ret;

		if (!changed[i])
			continue;

		ret = clk_set_rate(diag->camss_clks[i].clk, original_rates[i]);
		actual = clk_get_rate(diag->camss_clks[i].clk);
		if (!ret && i < 2 && original_rates[i] == 19200000 &&
		    actual == 240000000) {
			*camnoc_limited = true;
			dev_emerg(dev,
				  "AON-F0-ICP-OWNER-DIAG camss-restore-known-limitation clock=%s target=%lu actual=%lu\n",
				  diag->camss_clks[i].id, original_rates[i], actual);
			continue;
		}

		dev_emerg(dev,
			  "AON-F0-ICP-OWNER-DIAG camss-restore clock=%s target=%lu actual=%lu ret=%d\n",
			  diag->camss_clks[i].id, original_rates[i], actual, ret);
		if (ret && !first_error)
			first_error = ret;
		else if (!ret && actual != original_rates[i] && !first_error)
			first_error = -ERANGE;
	}

	return first_error;
}

static int a14_f0_owner_restore_icp(struct device *dev, struct camss *camss,
				    const unsigned long *original_rates,
				    const bool *changed)
{
	int first_error = 0;
	int i;

	for (i = A14_F0_OWNER_ICP_CLK_COUNT - 1; i >= 0; i--) {
		unsigned long actual;
		int ret;

		if (!changed[i])
			continue;

		ret = clk_set_rate(camss->aon_platform_clks[i].clk, original_rates[i]);
		actual = clk_get_rate(camss->aon_platform_clks[i].clk);
		dev_emerg(dev,
			  "AON-F0-ICP-OWNER-DIAG icp-restore clock=%s target=%lu actual=%lu ret=%d\n",
			  camss->aon_platform_clks[i].id, original_rates[i], actual, ret);
		if (ret && !first_error)
			first_error = ret;
		else if (!ret && actual != original_rates[i] && !first_error)
			first_error = -ERANGE;
	}

	return first_error;
}

static int a14_camss_f0_icp_owner_probe(struct device *dev)
{
	struct a14_f0_icp_owner_diag *diag = &a14_f0_icp_owner_diag;
	struct camss *camss = dev_get_drvdata(dev);
	struct device *cci0 = NULL;
	struct device *cci1 = NULL;
	unsigned long camss_original[A14_F0_OWNER_CAMSS_CLK_COUNT] = { 0 };
	unsigned long icp_original[A14_F0_OWNER_ICP_CLK_COUNT] = { 0 };
	bool camss_changed[A14_F0_OWNER_CAMSS_TARGET_COUNT] = { false };
	bool icp_changed[A14_F0_OWNER_ICP_CLK_COUNT] = { false };
	bool camnoc_limited = false;
	bool cci0_held = false;
	bool cci1_held = false;
	bool camss_pm_held = false;
	bool camss_clks_held = false;
	bool icp_clks_held = false;
	int cleanup_ret;
	int ret = 0;
	unsigned int i;

	if (!camss || !diag->ready)
		return -ENODEV;

	mutex_lock(&diag->lock);
	if (diag->clock_get_status) {
		ret = diag->clock_get_status;
		goto out_unlock;
	}
	if (diag->round_status) {
		ret = diag->round_status;
		goto out_unlock;
	}
	if (camss->ap_streams || !pm_runtime_suspended(dev)) {
		ret = -EBUSY;
		dev_emerg(dev,
			  "AON-F0-ICP-OWNER-DIAG unavailable reason=camss-busy ap-streams=%u runtime-suspended=%u ret=%d\n",
			  camss->ap_streams, pm_runtime_suspended(dev), ret);
		goto out_unlock;
	}

	cci0 = bus_find_device_by_name(&platform_bus_type, NULL, "ac15000.cci");
	cci1 = bus_find_device_by_name(&platform_bus_type, NULL, "ac16000.cci");
	if (!cci0 || !cci1) {
		ret = -ENODEV;
		dev_emerg(dev,
			  "AON-F0-ICP-OWNER-DIAG unavailable reason=cci-device-lookup cci0=%u cci1=%u ret=%d\n",
			  !!cci0, !!cci1, ret);
		goto out_put_devices;
	}

	dev_emerg(dev,
		  "AON-F0-ICP-OWNER-DIAG begin direct-mmio=false ssc=false ap-streams=%u\n",
		  camss->ap_streams);

	ret = qcom_cci_platform_hold_get(cci0, A14_F0_OWNER_CCI_RATE);
	dev_emerg(dev, "AON-F0-ICP-OWNER-DIAG cci-get device=ac15000.cci target=%lu ret=%d\n",
		  A14_F0_OWNER_CCI_RATE, ret);
	if (ret)
		goto out_put_devices;
	cci0_held = true;

	ret = qcom_cci_platform_hold_get(cci1, A14_F0_OWNER_CCI_RATE);
	dev_emerg(dev, "AON-F0-ICP-OWNER-DIAG cci-get device=ac16000.cci target=%lu ret=%d\n",
		  A14_F0_OWNER_CCI_RATE, ret);
	if (ret)
		goto out_cleanup;
	cci1_held = true;

	ret = pm_runtime_resume_and_get(dev);
	if (ret < 0) {
		dev_emerg(dev, "AON-F0-ICP-OWNER-DIAG camss-runtime-pm ret=%d\n", ret);
		goto out_cleanup;
	}
	camss_pm_held = true;

	ret = clk_bulk_prepare_enable(A14_F0_OWNER_CAMSS_CLK_COUNT, diag->camss_clks);
	if (ret) {
		dev_emerg(dev, "AON-F0-ICP-OWNER-DIAG camss-clock-enable ret=%d\n", ret);
		goto out_cleanup;
	}
	camss_clks_held = true;

	for (i = 0; i < A14_F0_OWNER_CAMSS_CLK_COUNT; i++)
		camss_original[i] = clk_get_rate(diag->camss_clks[i].clk);

	for (i = 0; i < A14_F0_OWNER_CAMSS_TARGET_COUNT; i++) {
		unsigned long actual;

		ret = clk_set_rate(diag->camss_clks[i].clk,
				   a14_f0_owner_camss_targets[i]);
		actual = clk_get_rate(diag->camss_clks[i].clk);
		dev_emerg(dev,
			  "AON-F0-ICP-OWNER-DIAG camss-set clock=%s target=%lu actual=%lu ret=%d\n",
			  diag->camss_clks[i].id, a14_f0_owner_camss_targets[i],
			  actual, ret);
		if (ret)
			goto out_cleanup;
		camss_changed[i] = true;
		if (actual != a14_f0_owner_camss_targets[i]) {
			ret = -ERANGE;
			goto out_cleanup;
		}
	}

	for (i = 0; i < A14_F0_OWNER_ICP_CLK_COUNT; i++) {
		unsigned long actual;

		icp_original[i] = clk_get_rate(camss->aon_platform_clks[i].clk);
		if (!icp_original[i]) {
			ret = -ERANGE;
			dev_emerg(dev,
				  "AON-F0-ICP-OWNER-DIAG icp-original-invalid clock=%s rate=0 ret=%d\n",
				  camss->aon_platform_clks[i].id, ret);
			goto out_cleanup;
		}
		ret = clk_set_rate(camss->aon_platform_clks[i].clk,
				   a14_f0_owner_icp_targets[i]);
		actual = clk_get_rate(camss->aon_platform_clks[i].clk);
		dev_emerg(dev,
			  "AON-F0-ICP-OWNER-DIAG icp-set clock=%s original=%lu target=%lu actual=%lu ret=%d enabled=false\n",
			  camss->aon_platform_clks[i].id, icp_original[i],
			  a14_f0_owner_icp_targets[i], actual, ret);
		if (ret)
			goto out_cleanup;
		icp_changed[i] = true;
		if (actual != a14_f0_owner_icp_targets[i]) {
			ret = -ERANGE;
			goto out_cleanup;
		}
	}

	ret = clk_bulk_prepare_enable(A14_F0_OWNER_ICP_CLK_COUNT,
				      camss->aon_platform_clks);
	if (ret) {
		dev_emerg(dev, "AON-F0-ICP-OWNER-DIAG icp-clock-enable ret=%d\n", ret);
		goto out_cleanup;
	}
	icp_clks_held = true;

	dev_emerg(dev,
		  "AON-F0-ICP-OWNER-DIAG targets-ok hold-ms=250 cci0=37500000 cci1=37500000 icp_ahb=80000000 icp=400000000 direct-mmio=false ssc=false\n");
	msleep(250);

out_cleanup:
	if (icp_clks_held) {
		clk_bulk_disable_unprepare(A14_F0_OWNER_ICP_CLK_COUNT,
					   camss->aon_platform_clks);
		icp_clks_held = false;
	}

	cleanup_ret = a14_f0_owner_restore_icp(dev, camss, icp_original, icp_changed);
	if (!ret && cleanup_ret)
		ret = cleanup_ret;
	if (!cleanup_ret && (icp_changed[0] || icp_changed[1]))
		dev_emerg(dev, "AON-F0-ICP-OWNER-DIAG icp-restore-ok\n");

	cleanup_ret = a14_f0_owner_restore_camss(dev, diag, camss_original,
						 camss_changed, &camnoc_limited);
	if (!ret && cleanup_ret)
		ret = cleanup_ret;

	if (camss_clks_held)
		clk_bulk_disable_unprepare(A14_F0_OWNER_CAMSS_CLK_COUNT, diag->camss_clks);
	if (camss_pm_held)
		pm_runtime_put(dev);

	if (cci1_held) {
		cleanup_ret = qcom_cci_platform_hold_put(cci1);
		dev_emerg(dev, "AON-F0-ICP-OWNER-DIAG cci-put device=ac16000.cci ret=%d\n",
			  cleanup_ret);
		if (!ret && cleanup_ret)
			ret = cleanup_ret;
	}
	if (cci0_held) {
		cleanup_ret = qcom_cci_platform_hold_put(cci0);
		dev_emerg(dev, "AON-F0-ICP-OWNER-DIAG cci-put device=ac15000.cci ret=%d\n",
			  cleanup_ret);
		if (!ret && cleanup_ret)
			ret = cleanup_ret;
	}

	dev_emerg(dev,
		  "AON-F0-ICP-OWNER-DIAG complete ret=%d camnoc-limited=%u direct-mmio=false ssc=false runtime-suspended=%u\n",
		  ret, camnoc_limited, pm_runtime_suspended(dev));

out_put_devices:
	if (cci1)
		put_device(cci1);
	if (cci0)
		put_device(cci0);
out_unlock:
	mutex_unlock(&diag->lock);
	return ret;
}

static ssize_t a14_f0_icp_owner_status_show(struct device *dev,
					    struct device_attribute *attr,
					    char *buf)
{
	struct a14_f0_icp_owner_diag *diag = &a14_f0_icp_owner_diag;
	struct camss *camss = dev_get_drvdata(dev);
	bool icp0 = camss && camss->aon_platform_clks[0].clk;
	bool icp1 = camss && camss->aon_platform_clks[1].clk;

	return sysfs_emit(buf,
			  "ready=%u clock_get_status=%d round_status=%d failed_clock=%s icp_ahb_handle=%u icp_handle=%u runtime_suspended=%u ap_streams=%u direct_mmio=0 ssc=0\n",
			  diag->ready, diag->clock_get_status, diag->round_status,
			  diag->failed_clock ?: "none", icp0, icp1,
			  pm_runtime_suspended(dev), camss ? camss->ap_streams : ~0U);
}
static DEVICE_ATTR_RO(a14_f0_icp_owner_status);

static ssize_t a14_f0_icp_owner_probe_store(struct device *dev,
					    struct device_attribute *attr,
					    const char *buf, size_t count)
{
	unsigned int value;
	int ret;

	ret = kstrtouint(buf, 0, &value);
	if (ret)
		return ret;
	if (value != 1)
		return -EINVAL;

	ret = a14_camss_f0_icp_owner_probe(dev);
	return ret ? ret : count;
}
static DEVICE_ATTR_WO(a14_f0_icp_owner_probe);

static struct attribute *a14_f0_icp_owner_diag_attrs[] = {
	&dev_attr_a14_f0_icp_owner_status.attr,
	&dev_attr_a14_f0_icp_owner_probe.attr,
	NULL,
};

static const struct attribute_group a14_f0_icp_owner_diag_group = {
	.name = "a14_f0_icp_owner_diag",
	.attrs = a14_f0_icp_owner_diag_attrs,
};

'''
    text = replace_once(
        text,
        "static const struct camss_subdev_resources csiphy_res_8x16[] = {\n",
        implementation + "static const struct camss_subdev_resources csiphy_res_8x16[] = {\n",
        "CAMSS resource-table",
    )

    probe_block = r'''
	if (camss->res->version == CAMSS_X1E80100 && camss->cpas_top_base) {
		struct a14_f0_icp_owner_diag *diag = &a14_f0_icp_owner_diag;
		unsigned int i;
		int diag_ret;

		mutex_init(&diag->lock);
		diag->ready = false;
		diag->clock_get_status = 0;
		diag->round_status = 0;
		diag->failed_clock = NULL;

		for (i = 0; i < A14_F0_OWNER_CAMSS_CLK_COUNT; i++) {
			diag->camss_clks[i].id = a14_f0_owner_camss_clk_ids[i];
			diag->camss_clks[i].clk = devm_clk_get(dev, diag->camss_clks[i].id);
			if (IS_ERR(diag->camss_clks[i].clk)) {
				diag_ret = PTR_ERR(diag->camss_clks[i].clk);
				diag->camss_clks[i].clk = NULL;
				if (!diag->clock_get_status) {
					diag->clock_get_status = diag_ret;
					diag->failed_clock = diag->camss_clks[i].id;
				}
			}
		}

		for (i = 0; i < A14_F0_OWNER_ICP_CLK_COUNT; i++) {
			if (!camss->aon_platform_clks[i].clk && !diag->clock_get_status) {
				diag->clock_get_status = -ENOENT;
				diag->failed_clock = camss->aon_platform_clks[i].id;
			}
		}

		if (!diag->clock_get_status) {
			for (i = 0; i < A14_F0_OWNER_CAMSS_TARGET_COUNT; i++) {
				long rounded = clk_round_rate(diag->camss_clks[i].clk,
							   a14_f0_owner_camss_targets[i]);

				if (rounded < 0 || rounded != a14_f0_owner_camss_targets[i]) {
					diag->round_status = rounded < 0 ? (int)rounded : -ERANGE;
					diag->failed_clock = diag->camss_clks[i].id;
					break;
				}
			}
		}
		if (!diag->clock_get_status && !diag->round_status) {
			for (i = 0; i < A14_F0_OWNER_ICP_CLK_COUNT; i++) {
				long rounded = clk_round_rate(camss->aon_platform_clks[i].clk,
							   a14_f0_owner_icp_targets[i]);

				if (rounded < 0 || rounded != a14_f0_owner_icp_targets[i]) {
					diag->round_status = rounded < 0 ? (int)rounded : -ERANGE;
					diag->failed_clock = camss->aon_platform_clks[i].id;
					break;
				}
			}
		}

		diag->ready = true;
		diag_ret = devm_device_add_group(dev, &a14_f0_icp_owner_diag_group);
		if (diag_ret) {
			diag->ready = false;
			dev_warn(dev, "failed to add A14 F0 ICP owner diagnostic: %d\n",
				 diag_ret);
		} else {
			dev_warn(dev,
				 "A14 isolated F0 ICP owner diagnostic available clock-ret=%d round-ret=%d failed-clock=%s direct-mmio=false ssc=false\n",
				 diag->clock_get_status, diag->round_status,
				 diag->failed_clock ?: "none");
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
    print("f0_icp_owner_diagnostic_injection=applied")
    print("uses_production_icp_handles=true")
    print("uses_production_cci_hold_api=true")
    print("direct_cpas_mmio=false")
    print("ssc_contact=false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
