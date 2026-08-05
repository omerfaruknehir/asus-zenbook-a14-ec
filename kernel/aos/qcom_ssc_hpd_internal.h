// SPDX-License-Identifier: GPL-2.0-only
#ifndef _QCOM_SSC_HPD_INTERNAL_H
#define _QCOM_SSC_HPD_INTERNAL_H

#include <linux/completion.h>
#include <linux/iio/iio.h>
#include <linux/mutex.h>
#include <linux/net.h>
#include <linux/soc/qcom/qmi.h>
#include <linux/workqueue.h>

#define A14_SSC_QMI_SERVICE             400
#define A14_SSC_QMI_VERSION             1
#define A14_SSC_QMI_INSTANCE            0

#define A14_SSC_QMI_CONTROL             0x20
#define A14_SSC_QMI_REPORT_SMALL        0x21
#define A14_SSC_QMI_REPORT_LARGE        0x22

#define A14_SSC_MSG_SUID_REQ            512
#define A14_SSC_MSG_SUID_EVENT          768
#define A14_SSC_MSG_ERROR_EVENT         130
#define A14_SSC_MSG_HANDSHAKE_INIT      576
#define A14_SSC_MSG_HANDSHAKE_ACK       832
#define A14_SSC_MSG_HANDSHAKE_RELEASE   577
#define A14_SSC_MSG_HANDSHAKE_RELEASE_ACK 833
#define A14_SSC_MSG_HANDSHAKE_REVOKE    579
#define A14_SSC_MSG_HANDSHAKE_REVOKE_ACK 835
#define A14_SSC_MSG_HPD_CONFIG          512
#define A14_SSC_MSG_PRESENCE_EVENT      928

#define A14_SSC_DATA_MAX                1024
#define A14_SSC_TIMEOUT                 (3 * HZ)

struct a14_ssc_suid {
	u64 field1;
	u64 field2;
	bool valid;
};

struct a14_ssc_control_req {
	u8 report_type;
	u32 data_len;
	u8 data[A14_SSC_DATA_MAX];
};

struct a14_ssc_control_resp {
	struct qmi_response_type_v01 resp;
	u64 client_id;
	u32 response;
};

struct a14_ssc_report_ind {
	u64 client_id;
	u32 data_len;
	u8 data[A14_SSC_DATA_MAX];
};

struct a14_ssc_hpd {
	struct device *dev;
	struct iio_dev *indio_dev;

	struct qmi_handle lookup;
	struct qmi_handle client;
	bool client_initialized;
	bool connected;
	bool service_present;
	bool suspended;
	bool shutting_down;
	struct sockaddr_qrtr service_addr;

	struct mutex lock;
	struct mutex op_lock;
	struct workqueue_struct *wq;
	struct work_struct connect_work;
	struct work_struct disconnect_work;

	struct completion handshake_suid_done;
	struct completion hpd_suid_done;
	struct completion face_suid_done;
	struct completion handshake_ack_done;

	struct a14_ssc_suid handshake_suid;
	struct a14_ssc_suid hpd_suid;
	struct a14_ssc_suid face_suid;

	int handshake_error;
	int presence;
	bool presence_valid;
	bool event_enabled;
};

size_t a14_ssc_build_suid_request(u8 *dst, size_t cap, const char *datatype);
size_t a14_ssc_build_handshake_request(u8 *dst, size_t cap,
				       const struct a14_ssc_suid *suid);
size_t a14_ssc_build_hpd_request(u8 *dst, size_t cap,
				 const struct a14_ssc_suid *suid);
void a14_ssc_parse_report(struct a14_ssc_hpd *hpd, const u8 *buf, size_t len);

extern const struct qmi_msg_handler a14_ssc_handlers[];
int a14_ssc_discover_suid(struct a14_ssc_hpd *hpd, const char *datatype,
			  struct completion *done, struct a14_ssc_suid *suid);
int a14_ssc_enable_hpd(struct a14_ssc_hpd *hpd);

#endif
