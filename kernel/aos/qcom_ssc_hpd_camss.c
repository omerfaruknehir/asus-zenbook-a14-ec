// SPDX-License-Identifier: GPL-2.0-only
#include <linux/device.h>
#include <linux/errno.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/platform_device.h>

#include "qcom_ssc_hpd_internal.h"

#ifdef A14_SSC_CAMSS_HANDOFF
#include <media/qcom_camss.h>

int a14_ssc_camss_init(struct a14_ssc_hpd *hpd)
{
	struct platform_device *camss_pdev;
	struct device_node *np;

	np = of_find_compatible_node(NULL, NULL, "qcom,x1e80100-camss");
	if (!np)
		return -EPROBE_DEFER;

	camss_pdev = of_find_device_by_node(np);
	of_node_put(np);
	if (!camss_pdev)
		return -EPROBE_DEFER;

	hpd->camss_dev = &camss_pdev->dev;
	hpd->camss_link = device_link_add(hpd->dev, hpd->camss_dev,
					 DL_FLAG_STATELESS | DL_FLAG_PM_RUNTIME);
	if (!hpd->camss_link) {
		put_device(hpd->camss_dev);
		hpd->camss_dev = NULL;
		return -EINVAL;
	}

	dev_info(hpd->dev, "CAMSS AON ownership handoff enabled\n");
	return 0;
}

void a14_ssc_camss_cleanup(struct a14_ssc_hpd *hpd)
{
	a14_ssc_camss_release(hpd);

	if (hpd->camss_link) {
		device_link_del(hpd->camss_link);
		hpd->camss_link = NULL;
	}
	if (hpd->camss_dev) {
		put_device(hpd->camss_dev);
		hpd->camss_dev = NULL;
	}
}

int a14_ssc_camss_acquire(struct a14_ssc_hpd *hpd)
{
	int ret;

	mutex_lock(&hpd->lock);
	if (hpd->camss_aon_owned) {
		mutex_unlock(&hpd->lock);
		return 0;
	}
	mutex_unlock(&hpd->lock);

	if (!hpd->camss_dev)
		return -ENODEV;

	ret = qcom_camss_aon_acquire(hpd->camss_dev);
	if (ret)
		return ret;

	mutex_lock(&hpd->lock);
	hpd->camss_aon_owned = true;
	mutex_unlock(&hpd->lock);
	dev_info(hpd->dev, "CAMSS camera path handed to AON\n");
	return 0;
}

void a14_ssc_camss_release(struct a14_ssc_hpd *hpd)
{
	bool release;

	mutex_lock(&hpd->lock);
	release = hpd->camss_aon_owned;
	hpd->camss_aon_owned = false;
	mutex_unlock(&hpd->lock);

	if (!release || !hpd->camss_dev)
		return;

	qcom_camss_aon_release(hpd->camss_dev);
	dev_info(hpd->dev, "CAMSS camera path restored to AP\n");
}
#else
int a14_ssc_camss_init(struct a14_ssc_hpd *hpd)
{
	(void)hpd;
	return 0;
}

void a14_ssc_camss_cleanup(struct a14_ssc_hpd *hpd)
{
	(void)hpd;
}

int a14_ssc_camss_acquire(struct a14_ssc_hpd *hpd)
{
	(void)hpd;
	return -EOPNOTSUPP;
}

void a14_ssc_camss_release(struct a14_ssc_hpd *hpd)
{
	(void)hpd;
}
#endif
