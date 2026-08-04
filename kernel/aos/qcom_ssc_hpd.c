// SPDX-License-Identifier: GPL-2.0-only
/*
 * Qualcomm SSC camera human-presence development driver
 *
 * Upstream-oriented hardware validation for ASUS Zenbook A14 UX3407RA.
 * Uses the in-kernel QRTR/QMI framework and exposes presence through IIO.
 * This is not part of the EC DKMS package and is never loaded automatically.
 */

#include <linux/iio/events.h>
#include <linux/iio/iio.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/workqueue.h>

#include "qcom_ssc_hpd_internal.h"

static void disconnect_client(struct a14_ssc_hpd *hpd);

static int hpd_read_raw(struct iio_dev *indio_dev,
			const struct iio_chan_spec *chan,
			int *val, int *val2, long mask)
{
	struct a14_ssc_hpd *hpd = iio_priv(indio_dev);

	if (mask != IIO_CHAN_INFO_RAW)
		return -EINVAL;

	mutex_lock(&hpd->lock);
	if (!hpd->presence_valid) {
		mutex_unlock(&hpd->lock);
		return -ENODATA;
	}
	*val = hpd->presence;
	mutex_unlock(&hpd->lock);
	return IIO_VAL_INT;
}

static int hpd_read_event_config(struct iio_dev *indio_dev,
				 const struct iio_chan_spec *chan,
				 enum iio_event_type type,
				 enum iio_event_direction dir)
{
	struct a14_ssc_hpd *hpd = iio_priv(indio_dev);
	int enabled;

	mutex_lock(&hpd->lock);
	enabled = hpd->event_enabled;
	mutex_unlock(&hpd->lock);
	return enabled;
}

static int hpd_write_event_config(struct iio_dev *indio_dev,
				  const struct iio_chan_spec *chan,
				  enum iio_event_type type,
				  enum iio_event_direction dir,
				  int state)
{
	struct a14_ssc_hpd *hpd = iio_priv(indio_dev);
	bool reconnect;

	if (state)
		return a14_ssc_enable_hpd(hpd);

	/* QMI-client teardown removes every SSC request owned by this client.
	 * Reconnect afterwards for a clean, idle service-discovery state. */
	disconnect_client(hpd);
	mutex_lock(&hpd->lock);
	reconnect = hpd->service_present;
	mutex_unlock(&hpd->lock);
	if (reconnect)
		queue_work(hpd->wq, &hpd->connect_work);

	return 0;
}

static const struct iio_info hpd_iio_info = {
	.read_raw = hpd_read_raw,
	.read_event_config = hpd_read_event_config,
	.write_event_config = hpd_write_event_config,
};

static const struct iio_event_spec hpd_event_spec[] = {
	{
		.type = IIO_EV_TYPE_CHANGE,
		.dir = IIO_EV_DIR_EITHER,
		.mask_separate = BIT(IIO_EV_INFO_ENABLE),
	},
};

static const struct iio_chan_spec hpd_channels[] = {
	{
		.type = IIO_PROXIMITY,
		.info_mask_separate = BIT(IIO_CHAN_INFO_RAW),
		.event_spec = hpd_event_spec,
		.num_event_specs = ARRAY_SIZE(hpd_event_spec),
	},
};

static void disconnect_client(struct a14_ssc_hpd *hpd)
{
	mutex_lock(&hpd->op_lock);
	mutex_lock(&hpd->lock);
	if (!hpd->client_initialized) {
		hpd->connected = false;
		mutex_unlock(&hpd->lock);
		mutex_unlock(&hpd->op_lock);
		return;
	}
	hpd->connected = false;
	hpd->event_enabled = false;
	hpd->presence_valid = false;
	hpd->client_initialized = false;
	mutex_unlock(&hpd->lock);
	qmi_handle_release(&hpd->client);
	mutex_unlock(&hpd->op_lock);
}

static void disconnect_work_fn(struct work_struct *work)
{
	struct a14_ssc_hpd *hpd = container_of(work, struct a14_ssc_hpd,
						disconnect_work);

	disconnect_client(hpd);
	dev_warn(hpd->dev, "SSC service disappeared; state released\n");
}

static void connect_work_fn(struct work_struct *work)
{
	struct a14_ssc_hpd *hpd = container_of(work, struct a14_ssc_hpd,
						connect_work);
	struct sockaddr_qrtr sq;
	int ret;

	mutex_lock(&hpd->op_lock);
	mutex_lock(&hpd->lock);
	if (!hpd->service_present || hpd->client_initialized) {
		mutex_unlock(&hpd->lock);
		mutex_unlock(&hpd->op_lock);
		return;
	}
	sq = hpd->service_addr;
	mutex_unlock(&hpd->lock);

	ret = qmi_handle_init(&hpd->client, A14_SSC_DATA_MAX + 64, NULL,
			      a14_ssc_handlers);
	if (ret)
		goto err;

	mutex_lock(&hpd->lock);
	hpd->client_initialized = true;
	mutex_unlock(&hpd->lock);

	ret = kernel_connect(hpd->client.sock, (void *)&sq, sizeof(sq), 0);
	if (ret)
		goto err_release;

	mutex_lock(&hpd->lock);
	hpd->connected = true;
	mutex_unlock(&hpd->lock);
	dev_info(hpd->dev, "connected to SSC QMI service at %u:%u\n",
		 sq.sq_node, sq.sq_port);

	ret = a14_ssc_discover_suid(hpd, "camera_handshake",
			    &hpd->handshake_suid_done, &hpd->handshake_suid);
	if (ret)
		dev_err(hpd->dev, "camera_handshake discovery failed: %d\n", ret);
	ret = a14_ssc_discover_suid(hpd, "human_presence_detect",
			    &hpd->hpd_suid_done, &hpd->hpd_suid);
	if (ret)
		dev_err(hpd->dev, "human_presence_detect discovery failed: %d\n", ret);
	ret = a14_ssc_discover_suid(hpd, "camera_face_detect",
			    &hpd->face_suid_done, &hpd->face_suid);
	if (ret)
		dev_warn(hpd->dev, "camera_face_detect discovery failed: %d\n", ret);
	mutex_unlock(&hpd->op_lock);
	return;

err_release:
	mutex_lock(&hpd->lock);
	hpd->connected = false;
	hpd->client_initialized = false;
	mutex_unlock(&hpd->lock);
	qmi_handle_release(&hpd->client);
err:
	mutex_unlock(&hpd->op_lock);
	dev_err(hpd->dev, "failed to connect SSC service: %d\n", ret);
}

static int new_server(struct qmi_handle *qmi, struct qmi_service *service)
{
	struct a14_ssc_hpd *hpd = container_of(qmi, struct a14_ssc_hpd,
						lookup);

	mutex_lock(&hpd->lock);
	hpd->service_addr.sq_family = AF_QIPCRTR;
	hpd->service_addr.sq_node = service->node;
	hpd->service_addr.sq_port = service->port;
	hpd->service_present = true;
	mutex_unlock(&hpd->lock);
	service->priv = hpd;
	queue_work(hpd->wq, &hpd->connect_work);
	return 0;
}

static void del_server(struct qmi_handle *qmi, struct qmi_service *service)
{
	struct a14_ssc_hpd *hpd = service->priv;

	if (!hpd)
		return;
	mutex_lock(&hpd->lock);
	hpd->service_present = false;
	mutex_unlock(&hpd->lock);
	queue_work(hpd->wq, &hpd->disconnect_work);
}

static const struct qmi_ops lookup_ops = {
	.new_server = new_server,
	.del_server = del_server,
};

static int a14_ssc_hpd_probe(struct platform_device *pdev)
{
	struct iio_dev *indio_dev;
	struct a14_ssc_hpd *hpd;
	int ret;

	if (!of_machine_is_compatible("asus,zenbook-a14-ux3407ra"))
		return -ENODEV;

	indio_dev = devm_iio_device_alloc(&pdev->dev, sizeof(*hpd));
	if (!indio_dev)
		return -ENOMEM;
	hpd = iio_priv(indio_dev);
	hpd->dev = &pdev->dev;
	hpd->indio_dev = indio_dev;
	mutex_init(&hpd->lock);
	mutex_init(&hpd->op_lock);
	hpd->wq = alloc_ordered_workqueue("a14-ssc-hpd", WQ_MEM_RECLAIM);
	if (!hpd->wq)
		return -ENOMEM;
	INIT_WORK(&hpd->connect_work, connect_work_fn);
	INIT_WORK(&hpd->disconnect_work, disconnect_work_fn);
	init_completion(&hpd->handshake_suid_done);
	init_completion(&hpd->hpd_suid_done);
	init_completion(&hpd->face_suid_done);
	init_completion(&hpd->handshake_ack_done);

	indio_dev->name = "qcom-ssc-human-presence";
	indio_dev->info = &hpd_iio_info;
	indio_dev->modes = INDIO_DIRECT_MODE;
	indio_dev->channels = hpd_channels;
	indio_dev->num_channels = ARRAY_SIZE(hpd_channels);

	ret = devm_iio_device_register(&pdev->dev, indio_dev);
	if (ret)
		goto err_destroy_wq;
	platform_set_drvdata(pdev, hpd);

	ret = qmi_handle_init(&hpd->lookup, 0, &lookup_ops, NULL);
	if (ret)
		goto err_destroy_wq;
	ret = qmi_add_lookup(&hpd->lookup, A14_SSC_QMI_SERVICE,
			     A14_SSC_QMI_VERSION, A14_SSC_QMI_INSTANCE);
	if (ret) {
		qmi_handle_release(&hpd->lookup);
		goto err_destroy_wq;
	}

	dev_info(&pdev->dev,
		 "waiting for SSC QMI service 400; IIO activation is manual\n");
	return 0;

err_destroy_wq:
	destroy_workqueue(hpd->wq);
	return ret;
}

static void a14_ssc_hpd_remove(struct platform_device *pdev)
{
	struct a14_ssc_hpd *hpd = platform_get_drvdata(pdev);

	qmi_handle_release(&hpd->lookup);
	flush_workqueue(hpd->wq);
	disconnect_client(hpd);
	destroy_workqueue(hpd->wq);
}

static struct platform_driver a14_ssc_hpd_driver = {
	.probe = a14_ssc_hpd_probe,
	.remove = a14_ssc_hpd_remove,
	.driver = {
		.name = "qcom-ssc-hpd-a14",
	},
};

static struct platform_device *a14_ssc_hpd_pdev;

static int __init a14_ssc_hpd_init(void)
{
	int ret;

	ret = platform_driver_register(&a14_ssc_hpd_driver);
	if (ret)
		return ret;
	a14_ssc_hpd_pdev = platform_device_register_simple("qcom-ssc-hpd-a14",
							     PLATFORM_DEVID_NONE,
							     NULL, 0);
	if (IS_ERR(a14_ssc_hpd_pdev)) {
		ret = PTR_ERR(a14_ssc_hpd_pdev);
		platform_driver_unregister(&a14_ssc_hpd_driver);
		return ret;
	}
	return 0;
}

static void __exit a14_ssc_hpd_exit(void)
{
	platform_device_unregister(a14_ssc_hpd_pdev);
	platform_driver_unregister(&a14_ssc_hpd_driver);
}

module_init(a14_ssc_hpd_init);
module_exit(a14_ssc_hpd_exit);

MODULE_DESCRIPTION("ASUS Zenbook A14 Qualcomm SSC human-presence development driver");
MODULE_AUTHOR("Ömer Faruk Nehir");
MODULE_LICENSE("GPL");
