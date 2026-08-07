#!/usr/bin/env python3
"""Inject a staged A14 Windows-F0 CCI clock-rate probe into i2c-qcom-cci."""

from __future__ import annotations

import sys
from pathlib import Path
from typing import NoReturn

MARKER = "AON-F0-CCI-RATE-DIAG begin"


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
        fail("usage: a14-aos-f0-cci-rate-diag-inject.py /path/to/i2c-qcom-cci.c")

    path = Path(sys.argv[1])
    if not path.is_file():
        fail(f"CCI source was not found: {path}")

    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        print("f0_cci_rate_diagnostic_injection=already-present")
        return 0

    for retired in (
        "AON-DIAG stage=",
        "AON-POWER-DIAG begin",
        "AON-F0-RATE-DIAG begin",
        "ap-write-no-read",
        "aon-switch-restore-no-read",
    ):
        if retired in text:
            fail(f"refusing to modify source containing another diagnostic marker: {retired}")

    text = add_include(text, "linux/delay.h", "#include <linux/completion.h>\n")
    text = add_include(text, "linux/mutex.h", "#include <linux/module.h>\n")

    old_struct = """struct cci {
\tstruct device *dev;
\tvoid __iomem *base;
\tunsigned int irq;
\tconst struct cci_data *data;
\tstruct clk_bulk_data *clocks;
\tint nclocks;
\tstruct cci_master master[NUM_MASTERS];
};
"""
    new_struct = """struct cci {
\tstruct device *dev;
\tvoid __iomem *base;
\tunsigned int irq;
\tconst struct cci_data *data;
\tstruct clk_bulk_data *clocks;
\tint nclocks;
\tstruct cci_master master[NUM_MASTERS];

\t/* A14 diagnostic-only state; injected only into the isolated test module. */
\tstruct mutex a14_f0_rate_lock;
\tstruct clk *a14_f0_cci_clk;
\tint a14_f0_clock_status;
\tint a14_f0_round_status;
\tbool a14_f0_ready;
};
"""
    text = replace_once(text, old_struct, new_struct, "struct cci")

    implementation = r'''
#define A14_F0_CCI_TARGET_RATE 37500000UL

static int a14_f0_cci_rate_probe(struct device *dev)
{
	struct cci *cci = dev_get_drvdata(dev);
	unsigned long original_rate;
	unsigned long actual;
	bool pm_held = false;
	int restore_ret = 0;
	int ret = 0;

	if (!cci || !cci->a14_f0_ready)
		return -ENODEV;

	mutex_lock(&cci->a14_f0_rate_lock);

	if (cci->a14_f0_clock_status) {
		ret = cci->a14_f0_clock_status;
		dev_emerg(dev,
			  "AON-F0-CCI-RATE-DIAG unavailable reason=clock-lookup ret=%d\n",
			  ret);
		goto out_unlock;
	}
	if (cci->a14_f0_round_status) {
		ret = cci->a14_f0_round_status;
		dev_emerg(dev,
			  "AON-F0-CCI-RATE-DIAG unavailable reason=round-rate ret=%d\n",
			  ret);
		goto out_unlock;
	}
	if (!pm_runtime_suspended(dev)) {
		ret = -EBUSY;
		dev_emerg(dev,
			  "AON-F0-CCI-RATE-DIAG unavailable reason=runtime-not-suspended ret=%d\n",
			  ret);
		goto out_unlock;
	}

	original_rate = clk_get_rate(cci->a14_f0_cci_clk);
	dev_emerg(dev,
		  "AON-F0-CCI-RATE-DIAG begin device=%s target=%lu original=%lu direct-cpas-mmio=false ssc=false\n",
		  dev_name(dev), A14_F0_CCI_TARGET_RATE, original_rate);

	ret = pm_runtime_resume_and_get(dev);
	if (ret < 0) {
		dev_emerg(dev,
			  "AON-F0-CCI-RATE-DIAG runtime-pm failed device=%s ret=%d\n",
			  dev_name(dev), ret);
		goto out_unlock;
	}
	pm_held = true;
	dev_emerg(dev,
		  "AON-F0-CCI-RATE-DIAG runtime-pm ok device=%s normal-cci-init=true\n",
		  dev_name(dev));

	ret = clk_set_rate(cci->a14_f0_cci_clk, A14_F0_CCI_TARGET_RATE);
	actual = clk_get_rate(cci->a14_f0_cci_clk);
	dev_emerg(dev,
		  "AON-F0-CCI-RATE-DIAG set device=%s target=%lu actual=%lu ret=%d\n",
		  dev_name(dev), A14_F0_CCI_TARGET_RATE, actual, ret);
	if (ret)
		goto out_restore;
	if (actual != A14_F0_CCI_TARGET_RATE) {
		ret = -ERANGE;
		dev_emerg(dev,
			  "AON-F0-CCI-RATE-DIAG verify failed device=%s target=%lu actual=%lu ret=%d\n",
			  dev_name(dev), A14_F0_CCI_TARGET_RATE, actual, ret);
		goto out_restore;
	}

	dev_emerg(dev,
		  "AON-F0-CCI-RATE-DIAG target-ok device=%s hold-ms=250\n",
		  dev_name(dev));
	msleep(250);

out_restore:
	restore_ret = clk_set_rate(cci->a14_f0_cci_clk, original_rate);
	actual = clk_get_rate(cci->a14_f0_cci_clk);
	dev_emerg(dev,
		  "AON-F0-CCI-RATE-DIAG restore device=%s target=%lu actual=%lu ret=%d\n",
		  dev_name(dev), original_rate, actual, restore_ret);
	if (!restore_ret && actual != original_rate)
		restore_ret = -ERANGE;
	if (!ret && restore_ret)
		ret = restore_ret;

	if (pm_held) {
		pm_runtime_mark_last_busy(dev);
		pm_runtime_put_autosuspend(dev);
	}
	dev_emerg(dev,
		  "AON-F0-CCI-RATE-DIAG complete device=%s ret=%d restore-ret=%d direct-cpas-mmio=false ssc=false runtime-suspended=%u\n",
		  dev_name(dev), ret, restore_ret, pm_runtime_suspended(dev));

out_unlock:
	mutex_unlock(&cci->a14_f0_rate_lock);
	return ret;
}

static ssize_t a14_f0_cci_rate_status_show(struct device *dev,
					   struct device_attribute *attr,
					   char *buf)
{
	struct cci *cci = dev_get_drvdata(dev);
	unsigned long rate = 0;

	if (cci && cci->a14_f0_cci_clk)
		rate = clk_get_rate(cci->a14_f0_cci_clk);

	return sysfs_emit(buf,
			  "ready=%u clock_status=%d round_status=%d target=37500000 current_rate=%lu runtime_suspended=%u initialization=post-probe-success\n",
			  cci ? cci->a14_f0_ready : 0,
			  cci ? cci->a14_f0_clock_status : -ENODEV,
			  cci ? cci->a14_f0_round_status : -ENODEV,
			  rate, pm_runtime_suspended(dev));
}
static DEVICE_ATTR_RO(a14_f0_cci_rate_status);

static ssize_t a14_f0_cci_rate_probe_store(struct device *dev,
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

	ret = a14_f0_cci_rate_probe(dev);
	return ret ? ret : count;
}
static DEVICE_ATTR_WO(a14_f0_cci_rate_probe);

static struct attribute *a14_f0_cci_rate_attrs[] = {
	&dev_attr_a14_f0_cci_rate_status.attr,
	&dev_attr_a14_f0_cci_rate_probe.attr,
	NULL,
};

static const struct attribute_group a14_f0_cci_rate_group = {
	.name = "a14_f0_cci_rate_diag",
	.attrs = a14_f0_cci_rate_attrs,
};

static void a14_f0_cci_rate_diag_init(struct cci *cci)
{
	long rounded;
	int i;

	mutex_init(&cci->a14_f0_rate_lock);
	cci->a14_f0_ready = false;
	cci->a14_f0_clock_status = -ENOENT;
	cci->a14_f0_round_status = 0;
	cci->a14_f0_cci_clk = NULL;

	for (i = 0; i < cci->nclocks; i++) {
		if (!strcmp(cci->clocks[i].id, "cci")) {
			cci->a14_f0_cci_clk = cci->clocks[i].clk;
			cci->a14_f0_clock_status = 0;
			break;
		}
	}

	if (cci->a14_f0_clock_status) {
		dev_warn(cci->dev,
			 "A14 F0 CCI rate diagnostic unavailable reason=cci-clock-not-found\n");
		return;
	}

	rounded = clk_round_rate(cci->a14_f0_cci_clk,
				 A14_F0_CCI_TARGET_RATE);
	if (rounded < 0 || rounded != A14_F0_CCI_TARGET_RATE) {
		cci->a14_f0_round_status =
			rounded < 0 ? (int)rounded : -ERANGE;
		dev_warn(cci->dev,
			 "A14 F0 CCI rate diagnostic unavailable target=%lu rounded=%ld ret=%d\n",
			 A14_F0_CCI_TARGET_RATE, rounded,
			 cci->a14_f0_round_status);
		return;
	}

	cci->a14_f0_ready = true;
}

'''
    text = replace_once(
        text,
        "static int cci_probe(struct platform_device *pdev)\n",
        implementation + "static int cci_probe(struct platform_device *pdev)\n",
        "cci_probe",
    )

    old_return = """\tfor (i = 0; i < cci->data->num_masters; i++) {
\t\tif (!cci->master[i].cci)
\t\t\tcontinue;

\t\tret = i2c_add_adapter(&cci->master[i].adap);
\t\tif (ret < 0) {
\t\t\tof_node_put(cci->master[i].adap.dev.of_node);
\t\t\tgoto error_i2c;
\t\t}
\t}

\treturn 0;
"""
    new_return = """\tfor (i = 0; i < cci->data->num_masters; i++) {
\t\tif (!cci->master[i].cci)
\t\t\tcontinue;

\t\tret = i2c_add_adapter(&cci->master[i].adap);
\t\tif (ret < 0) {
\t\t\tof_node_put(cci->master[i].adap.dev.of_node);
\t\t\tgoto error_i2c;
\t\t}
\t}

\ta14_f0_cci_rate_diag_init(cci);
\tret = devm_device_add_group(dev, &a14_f0_cci_rate_group);
\tif (ret)
\t\tgoto error_i2c;

\tdev_warn(dev,
\t\t "A14 staged F0 CCI rate diagnostic available target=37500000 initialization=post-probe-success idle-guard=runtime-suspended\\n");

\treturn 0;
"""
    text = replace_once(text, old_return, new_return, "successful cci_probe completion")

    if MARKER not in text:
        fail("diagnostic marker is missing after transformation")

    path.write_text(text, encoding="utf-8")
    print("f0_cci_rate_diagnostic_injection=applied")
    print("target_rate=37500000")
    print("exact_round_rate_required=true")
    print("restore_original_rate=true")
    print("runtime_pm=existing-cci-driver")
    print("direct_cpas_mmio=false")
    print("ssc_contact=false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
