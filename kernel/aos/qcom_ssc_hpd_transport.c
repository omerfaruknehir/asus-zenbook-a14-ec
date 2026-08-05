// SPDX-License-Identifier: GPL-2.0-only
#include <linux/errno.h>
#include <linux/kernel.h>
#include <linux/slab.h>

#include "qcom_ssc_hpd_internal.h"

static const struct qmi_elem_info a14_ssc_control_req_ei[] = {
	{
		.data_type = QMI_UNSIGNED_1_BYTE,
		.elem_len = 1,
		.elem_size = sizeof(u8),
		.array_type = NO_ARRAY,
		.tlv_type = 0x10,
		.offset = offsetof(struct a14_ssc_control_req, report_type),
	},
	{
		.data_type = QMI_DATA_LEN,
		.elem_len = 1,
		.elem_size = sizeof(u32),
		.array_type = NO_ARRAY,
		.tlv_type = 0x01,
		.offset = offsetof(struct a14_ssc_control_req, data_len),
	},
	{
		.data_type = QMI_UNSIGNED_1_BYTE,
		.elem_len = A14_SSC_DATA_MAX,
		.elem_size = sizeof(u8),
		.array_type = VAR_LEN_ARRAY,
		.tlv_type = 0x01,
		.offset = offsetof(struct a14_ssc_control_req, data),
	},
	{}
};

static const struct qmi_elem_info a14_ssc_control_resp_ei[] = {
	{
		.data_type = QMI_STRUCT,
		.elem_len = 1,
		.elem_size = sizeof(struct qmi_response_type_v01),
		.array_type = NO_ARRAY,
		.tlv_type = 0x02,
		.offset = offsetof(struct a14_ssc_control_resp, resp),
		.ei_array = qmi_response_type_v01_ei,
	},
	{
		.data_type = QMI_UNSIGNED_8_BYTE,
		.elem_len = 1,
		.elem_size = sizeof(u64),
		.array_type = NO_ARRAY,
		.tlv_type = 0x10,
		.offset = offsetof(struct a14_ssc_control_resp, client_id),
	},
	{
		.data_type = QMI_UNSIGNED_4_BYTE,
		.elem_len = 1,
		.elem_size = sizeof(u32),
		.array_type = NO_ARRAY,
		.tlv_type = 0x11,
		.offset = offsetof(struct a14_ssc_control_resp, response),
	},
	{}
};

static const struct qmi_elem_info a14_ssc_report_ind_ei[] = {
	{
		.data_type = QMI_UNSIGNED_8_BYTE,
		.elem_len = 1,
		.elem_size = sizeof(u64),
		.array_type = NO_ARRAY,
		.tlv_type = 0x01,
		.offset = offsetof(struct a14_ssc_report_ind, client_id),
	},
	{
		.data_type = QMI_DATA_LEN,
		.elem_len = 1,
		.elem_size = sizeof(u32),
		.array_type = NO_ARRAY,
		.tlv_type = 0x02,
		.offset = offsetof(struct a14_ssc_report_ind, data_len),
	},
	{
		.data_type = QMI_UNSIGNED_1_BYTE,
		.elem_len = A14_SSC_DATA_MAX,
		.elem_size = sizeof(u8),
		.array_type = VAR_LEN_ARRAY,
		.tlv_type = 0x02,
		.offset = offsetof(struct a14_ssc_report_ind, data),
	},
	{}
};

static int send_control(struct a14_ssc_hpd *hpd, const u8 *data, size_t len)
{
	struct a14_ssc_control_resp resp = {};
	struct a14_ssc_control_req *req;
	struct qmi_txn txn;
	int ret;

	if (!hpd->connected || !len || len > A14_SSC_DATA_MAX)
		return -ENOTCONN;

	req = kzalloc(sizeof(*req), GFP_KERNEL);
	if (!req)
		return -ENOMEM;
	req->report_type = 1;
	req->data_len = len;
	memcpy(req->data, data, len);

	/* qmi_txn_init() returns a non-negative transaction ID on success. */
	ret = qmi_txn_init(&hpd->client, &txn, a14_ssc_control_resp_ei,
			   &resp);
	if (ret < 0)
		goto out;

	ret = qmi_send_request(&hpd->client, NULL, &txn,
			       A14_SSC_QMI_CONTROL,
			       A14_SSC_DATA_MAX + 32,
			       a14_ssc_control_req_ei, req);
	if (ret < 0) {
		qmi_txn_cancel(&txn);
		goto out;
	}

	/* qmi_txn_wait() returns a negative errno on failure. On successful
	 * decoded responses it may return the non-negative decoder result, which
	 * is not a protocol error. */
	ret = qmi_txn_wait(&txn, A14_SSC_TIMEOUT);
	if (ret < 0)
		goto out;
	if (resp.resp.result != QMI_RESULT_SUCCESS_V01) {
		dev_err(hpd->dev, "SSC control failed: result=%u error=%u\n",
			resp.resp.result, resp.resp.error);
		ret = -EREMOTEIO;
		goto out;
	}
	if (resp.response) {
		dev_err(hpd->dev, "SSC rejected request: response=%u\n",
			resp.response);
		ret = -EREMOTEIO;
		goto out;
	}

	ret = 0;
out:
	kfree(req);
	return ret;
}

static void report_cb(struct qmi_handle *qmi, struct sockaddr_qrtr *sq,
		      struct qmi_txn *txn, const void *decoded)
{
	struct a14_ssc_hpd *hpd = container_of(qmi, struct a14_ssc_hpd,
						client);
	const struct a14_ssc_report_ind *ind = decoded;

	if (ind->data_len > A14_SSC_DATA_MAX)
		return;
	a14_ssc_parse_report(hpd, ind->data, ind->data_len);
}

const struct qmi_msg_handler a14_ssc_handlers[] = {
	{
		.type = QMI_INDICATION,
		.msg_id = A14_SSC_QMI_REPORT_SMALL,
		.ei = a14_ssc_report_ind_ei,
		.decoded_size = sizeof(struct a14_ssc_report_ind),
		.fn = report_cb,
	},
	{
		.type = QMI_INDICATION,
		.msg_id = A14_SSC_QMI_REPORT_LARGE,
		.ei = a14_ssc_report_ind_ei,
		.decoded_size = sizeof(struct a14_ssc_report_ind),
		.fn = report_cb,
	},
	{}
};

int a14_ssc_discover_suid(struct a14_ssc_hpd *hpd, const char *datatype,
			 struct completion *done,
			 struct a14_ssc_suid *suid)
{
	u8 data[256];
	size_t len;
	int ret;

	reinit_completion(done);
	len = a14_ssc_build_suid_request(data, sizeof(data), datatype);
	if (!len)
		return -EINVAL;
	ret = send_control(hpd, data, len);
	if (ret)
		return ret;
	if (!wait_for_completion_timeout(done, A14_SSC_TIMEOUT))
		return -ETIMEDOUT;

	mutex_lock(&hpd->lock);
	ret = suid->valid ? 0 : -ENODEV;
	mutex_unlock(&hpd->lock);
	return ret;
}

int a14_ssc_enable_hpd(struct a14_ssc_hpd *hpd)
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

	len = a14_ssc_build_handshake_request(data, sizeof(data), &hpd->handshake_suid);
	if (!len) {
		ret = -EINVAL;
		goto out_unlock_op;
	}
	ret = send_control(hpd, data, len);
	if (ret)
		goto out_unlock_op;
	if (!wait_for_completion_timeout(&hpd->handshake_ack_done,
					 A14_SSC_TIMEOUT)) {
		dev_err(hpd->dev, "camera handshake ACK 832 timed out\n");
		ret = -ETIMEDOUT;
		goto out_unlock_op;
	}
	if (hpd->handshake_error) {
		ret = -EREMOTEIO;
		goto out_unlock_op;
	}

	len = a14_ssc_build_hpd_request(data, sizeof(data), &hpd->hpd_suid);
	if (!len) {
		ret = -EINVAL;
		goto out_unlock_op;
	}
	ret = send_control(hpd, data, len);
	if (ret)
		goto out_unlock_op;

	mutex_lock(&hpd->lock);
	hpd->event_enabled = true;
	mutex_unlock(&hpd->lock);
	ret = 0;
	goto out_unlock_op;

out_unlock_state:
	mutex_unlock(&hpd->lock);
out_unlock_op:
	mutex_unlock(&hpd->op_lock);
	return ret;
}
