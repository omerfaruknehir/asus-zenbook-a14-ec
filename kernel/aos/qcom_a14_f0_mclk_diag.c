// SPDX-License-Identifier: GPL-2.0-only
/*
 * ASUS Zenbook A14 X1E80100 CAMP F0 MCLK pinctrl discriminator.
 *
 * Diagnostic only.  The driver never changes pinctrl state at probe time.
 * Userspace must explicitly select the active state through the root-only
 * sysfs attribute.  The idle state is restored before removal if necessary.
 *
 * No GPIO MMIO, CPAS MMIO, SSC traffic, clock control or camera ownership is
 * performed here; all pin changes go through the Linux pinctrl framework.
 */

#include <linux/device.h>
#include <linux/errno.h>
#include <linux/kstrtox.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/pinctrl/consumer.h>
#include <linux/platform_device.h>
#include <linux/slab.h>

struct a14_f0_mclk_diag {
	struct pinctrl *pinctrl;
	struct pinctrl_state *active_state;
	struct pinctrl_state *idle_state;
	struct mutex lock;
	bool active;
};

static ssize_t a14_f0_mclk_active_show(struct device *dev,
					struct device_attribute *attr, char *buf)
{
	struct a14_f0_mclk_diag *diag = dev_get_drvdata(dev);
	bool active;

	mutex_lock(&diag->lock);
	active = diag->active;
	mutex_unlock(&diag->lock);

	return sysfs_emit(buf, "%u\n", active);
}

static ssize_t a14_f0_mclk_active_store(struct device *dev,
					 struct device_attribute *attr,
					 const char *buf, size_t count)
{
	struct a14_f0_mclk_diag *diag = dev_get_drvdata(dev);
	struct pinctrl_state *state;
	bool requested;
	int ret;

	ret = kstrtobool(buf, &requested);
	if (ret)
		return ret;

	mutex_lock(&diag->lock);
	if (requested == diag->active) {
		mutex_unlock(&diag->lock);
		return count;
	}

	state = requested ? diag->active_state : diag->idle_state;
	ret = pinctrl_select_state(diag->pinctrl, state);
	if (!ret)
		diag->active = requested;
	mutex_unlock(&diag->lock);

	if (ret)
		return ret;

	dev_warn(dev,
		 "A14-F0-MCLK-DIAG state=%s gpios=97,98 direct-mmio=false cpas=false ssc=false\n",
		 requested ? "active-cam_mclk-no-pull-6mA" :
			     "idle-gpio-pulldown-2mA");
	return count;
}
static DEVICE_ATTR_RW(a14_f0_mclk_active);

static struct attribute *a14_f0_mclk_attrs[] = {
	&dev_attr_a14_f0_mclk_active.attr,
	NULL,
};

static const struct attribute_group a14_f0_mclk_group = {
	.attrs = a14_f0_mclk_attrs,
};

static int a14_f0_mclk_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct a14_f0_mclk_diag *diag;
	int ret;

	diag = devm_kzalloc(dev, sizeof(*diag), GFP_KERNEL);
	if (!diag)
		return -ENOMEM;

	mutex_init(&diag->lock);

	diag->pinctrl = devm_pinctrl_get(dev);
	if (IS_ERR(diag->pinctrl))
		return dev_err_probe(dev, PTR_ERR(diag->pinctrl),
				     "failed to obtain diagnostic pinctrl\n");

	diag->active_state = pinctrl_lookup_state(diag->pinctrl,
						 "aos-f0-mclk-active");
	if (IS_ERR(diag->active_state))
		return dev_err_probe(dev, PTR_ERR(diag->active_state),
				     "missing active diagnostic pinctrl state\n");

	diag->idle_state = pinctrl_lookup_state(diag->pinctrl,
					       "aos-f0-mclk-idle");
	if (IS_ERR(diag->idle_state))
		return dev_err_probe(dev, PTR_ERR(diag->idle_state),
				     "missing idle diagnostic pinctrl state\n");

	/* Intentionally do not select either state here.  Probe must be inert. */
	diag->active = false;
	platform_set_drvdata(pdev, diag);

	ret = devm_device_add_group(dev, &a14_f0_mclk_group);
	if (ret)
		return ret;

	dev_info(dev,
		 "A14 F0 MCLK diagnostic ready; manual activation only, direct-mmio=false cpas=false ssc=false\n");
	return 0;
}

static void a14_f0_mclk_remove(struct platform_device *pdev)
{
	struct a14_f0_mclk_diag *diag = platform_get_drvdata(pdev);
	int ret;

	if (!diag)
		return;

	mutex_lock(&diag->lock);
	if (diag->active) {
		ret = pinctrl_select_state(diag->pinctrl, diag->idle_state);
		if (ret)
			dev_err(&pdev->dev,
				"failed to restore idle MCLK pinctrl state during remove: %d\n",
				ret);
		else
			diag->active = false;
	}
	mutex_unlock(&diag->lock);
}

static const struct of_device_id a14_f0_mclk_of_match[] = {
	{ .compatible = "asus,a14-aos-f0-mclk-diag" },
	{ }
};
MODULE_DEVICE_TABLE(of, a14_f0_mclk_of_match);

static struct platform_driver a14_f0_mclk_driver = {
	.probe = a14_f0_mclk_probe,
	.remove = a14_f0_mclk_remove,
	.driver = {
		.name = "qcom-a14-f0-mclk-diag",
		.of_match_table = a14_f0_mclk_of_match,
	},
};
module_platform_driver(a14_f0_mclk_driver);

MODULE_DESCRIPTION("ASUS Zenbook A14 CAMP F0 MCLK pinctrl diagnostic");
MODULE_LICENSE("GPL");
