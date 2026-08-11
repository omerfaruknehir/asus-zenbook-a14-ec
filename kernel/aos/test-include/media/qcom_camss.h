/* SPDX-License-Identifier: GPL-2.0 */
#ifndef __MEDIA_QCOM_CAMSS_H__
#define __MEDIA_QCOM_CAMSS_H__

struct device;

int qcom_camss_aon_acquire(struct device *camss_dev);
void qcom_camss_aon_release(struct device *camss_dev);

#endif
