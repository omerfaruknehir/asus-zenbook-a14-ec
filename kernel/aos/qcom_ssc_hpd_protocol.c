// SPDX-License-Identifier: GPL-2.0-only
#include <linux/errno.h>
#include <linux/iio/events.h>
#include <linux/kernel.h>
#include <linux/string.h>

#include "qcom_ssc_hpd_internal.h"

static void put_le32(u8 *p, u32 v)
{
	p[0] = v;
	p[1] = v >> 8;
	p[2] = v >> 16;
	p[3] = v >> 24;
}

static void put_le64(u8 *p, u64 v)
{
	int i;

	for (i = 0; i < 8; i++)
		p[i] = v >> (i * 8);
}

static u32 get_le32(const u8 *p)
{
	return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) |
	       ((u32)p[3] << 24);
}

static u64 get_le64(const u8 *p)
{
	u64 v = 0;
	int i;

	for (i = 7; i >= 0; i--)
		v = (v << 8) | p[i];
	return v;
}

static size_t put_varint(u8 *dst, size_t cap, u64 value)
{
	size_t n = 0;

	do {
		u8 b = value & 0x7f;

		value >>= 7;
		if (value)
			b |= 0x80;
		if (n >= cap)
			return 0;
		dst[n++] = b;
	} while (value);

	return n;
}

static size_t varint_size(u64 value)
{
	size_t n = 1;

	while (value >= 0x80) {
		value >>= 7;
		n++;
	}
	return n;
}

static int get_varint(const u8 *buf, size_t len, size_t *pos, u64 *value)
{
	u64 out = 0;
	unsigned int shift = 0;

	while (*pos < len && shift <= 63) {
		u8 b = buf[(*pos)++];

		out |= (u64)(b & 0x7f) << shift;
		if (!(b & 0x80)) {
			*value = out;
			return 0;
		}
		shift += 7;
	}

	return -EBADMSG;
}

struct pb_field {
	u32 number;
	u8 wire;
	const u8 *data;
	size_t len;
	u64 value;
};

static int pb_next(const u8 *buf, size_t len, size_t *pos,
		   struct pb_field *field)
{
	u64 tag, n;
	int ret;

	if (*pos >= len)
		return 0;

	ret = get_varint(buf, len, pos, &tag);
	if (ret)
		return ret;
	field->number = tag >> 3;
	field->wire = tag & 7;
	field->data = NULL;
	field->len = 0;
	field->value = 0;
	if (!field->number)
		return -EBADMSG;

	switch (field->wire) {
	case 0:
		return get_varint(buf, len, pos, &field->value) ?: 1;
	case 1:
		if (len - *pos < 8)
			return -EBADMSG;
		field->data = buf + *pos;
		field->len = 8;
		*pos += 8;
		return 1;
	case 2:
		ret = get_varint(buf, len, pos, &n);
		if (ret || n > len - *pos)
			return -EBADMSG;
		field->data = buf + *pos;
		field->len = n;
		*pos += n;
		return 1;
	case 5:
		if (len - *pos < 4)
			return -EBADMSG;
		field->data = buf + *pos;
		field->len = 4;
		*pos += 4;
		return 1;
	default:
		return -EBADMSG;
	}
}

/* sns_client_request_msg.request is an sns_std_request, not an opaque byte
 * string. Every sensor-specific protobuf therefore has to be nested in
 * sns_std_request.payload (field 2).  The QMI layer adds its own variable-array
 * length around this completed protobuf; no private SSC length prefix belongs
 * here. */
static size_t build_client_request(u8 *dst, size_t cap,
				   const struct a14_ssc_suid *suid,
				   u32 msg_id, const u8 *payload,
				   size_t payload_len)
{
	size_t p = 0, n, std_req_len;

	if (!suid->valid || cap < 40 || payload_len > 900)
		return 0;

	std_req_len = 1 + varint_size(payload_len) + payload_len;

	/* field 1: required sns_std_suid */
	dst[p++] = 0x0a;
	dst[p++] = 0x12;
	dst[p++] = 0x09;
	put_le64(dst + p, suid->field1);
	p += 8;
	dst[p++] = 0x11;
	put_le64(dst + p, suid->field2);
	p += 8;

	/* field 2: required fixed32 msg_id */
	dst[p++] = 0x15;
	put_le32(dst + p, msg_id);
	p += 4;

	/* field 3: APSS + WAKEUP suspend configuration */
	dst[p++] = 0x1a;
	dst[p++] = 0x04;
	dst[p++] = 0x08;
	dst[p++] = 0x01;
	dst[p++] = 0x10;
	dst[p++] = 0x00;

	/* field 4: sns_std_request { payload = sensor protobuf } */
	if (p >= cap)
		return 0;
	dst[p++] = 0x22;
	n = put_varint(dst + p, cap - p, std_req_len);
	if (!n || p + n + std_req_len > cap)
		return 0;
	p += n;
	dst[p++] = 0x12;
	n = put_varint(dst + p, cap - p, payload_len);
	if (!n || p + n + payload_len > cap)
		return 0;
	p += n;
	memcpy(dst + p, payload, payload_len);
	p += payload_len;

	return p;
}

size_t a14_ssc_build_suid_request(u8 *dst, size_t cap, const char *datatype)
{
	static const struct a14_ssc_suid suid_service = {
		.field1 = 0xababababababababULL,
		.field2 = 0xababababababababULL,
		.valid = true,
	};
	u8 payload[160];
	size_t name_len = strlen(datatype);
	size_t p = 0, n;

	if (!name_len || name_len > 120)
		return 0;

	/* Raw sns_suid_req. The generic builder adds sns_std_request. */
	payload[p++] = 0x0a;
	n = put_varint(payload + p, sizeof(payload) - p, name_len);
	if (!n)
		return 0;
	p += n;
	memcpy(payload + p, datatype, name_len);
	p += name_len;
	payload[p++] = 0x10;
	payload[p++] = 0x00;
	payload[p++] = 0x18;
	payload[p++] = 0x01;

	return build_client_request(dst, cap, &suid_service,
				    A14_SSC_MSG_SUID_REQ, payload, p);
}

size_t a14_ssc_build_handshake_request(u8 *dst, size_t cap,
				      const struct a14_ssc_suid *suid)
{
	static const char name[] = "ov02c10";
	u8 payload[32];
	size_t p = 0;

	/* qsh_camera_handshake_init: sensor_name, restart_count, camera_id. */
	payload[p++] = 0x0a;
	payload[p++] = sizeof(name) - 1;
	memcpy(payload + p, name, sizeof(name) - 1);
	p += sizeof(name) - 1;
	payload[p++] = 0x10;
	payload[p++] = 0x00;
	payload[p++] = 0x18;
	payload[p++] = 0x02;

	return build_client_request(dst, cap, suid,
				    A14_SSC_MSG_HANDSHAKE_INIT, payload, p);
}

size_t a14_ssc_build_hpd_request(u8 *dst, size_t cap,
				const struct a14_ssc_suid *suid)
{
	/* Policy value for the development driver. Windows stores this setting in
	 * millimetres and converts to metres for this protobuf. Make it an IIO
	 * threshold attribute later instead of baking it into the transport. */
	const float threshold_m = 1.5f;
	u32 bits;
	u8 payload[5];

	memcpy(&bits, &threshold_m, sizeof(bits));
	payload[0] = 0x0d;
	put_le32(payload + 1, bits);

	return build_client_request(dst, cap, suid,
				    A14_SSC_MSG_HPD_CONFIG, payload,
				    sizeof(payload));
}

static int parse_suid_payload(struct a14_ssc_hpd *hpd,
			      const u8 *buf, size_t len)
{
	struct a14_ssc_suid suid = {};
	char datatype[64] = {};
	size_t pos = 0;
	struct pb_field f;
	int ret;

	while ((ret = pb_next(buf, len, &pos, &f)) > 0) {
		if (f.number == 1 && f.wire == 2) {
			size_t copy = min_t(size_t, f.len, sizeof(datatype) - 1);

			memcpy(datatype, f.data, copy);
		} else if (f.number == 2 && f.wire == 2) {
			size_t sp = 0;
			struct pb_field sf;

			while (pb_next(f.data, f.len, &sp, &sf) > 0) {
				if (sf.number == 1 && sf.wire == 1)
					suid.field1 = get_le64(sf.data);
				else if (sf.number == 2 && sf.wire == 1)
					suid.field2 = get_le64(sf.data);
			}
			suid.valid = suid.field1 || suid.field2;
		}
	}
	if (ret < 0 || !datatype[0] || !suid.valid)
		return -EBADMSG;

	mutex_lock(&hpd->lock);
	if (!strcmp(datatype, "camera_handshake")) {
		hpd->handshake_suid = suid;
		complete_all(&hpd->handshake_suid_done);
	} else if (!strcmp(datatype, "human_presence_detect")) {
		hpd->hpd_suid = suid;
		complete_all(&hpd->hpd_suid_done);
	} else if (!strcmp(datatype, "camera_face_detect")) {
		hpd->face_suid = suid;
		complete_all(&hpd->face_suid_done);
	}
	mutex_unlock(&hpd->lock);

	dev_info(hpd->dev, "SSC datatype %s SUID fields %016llx:%016llx\n",
		 datatype, suid.field1, suid.field2);
	return 0;
}

static void parse_event(struct a14_ssc_hpd *hpd, u32 msg_id,
			const u8 *payload, size_t payload_len)
{
	size_t pos = 0;
	struct pb_field f;
	int ret;

	switch (msg_id) {
	case A14_SSC_MSG_SUID_EVENT:
		parse_suid_payload(hpd, payload, payload_len);
		break;
	case A14_SSC_MSG_HANDSHAKE_ACK:
		hpd->handshake_error = -EBADMSG;
		while ((ret = pb_next(payload, payload_len, &pos, &f)) > 0) {
			if (f.number == 1 && f.wire == 0) {
				hpd->handshake_error = f.value;
				break;
			}
		}
		complete_all(&hpd->handshake_ack_done);
		dev_info(hpd->dev, "camera handshake ACK error_state=%d\n",
			 hpd->handshake_error);
		break;
	case A14_SSC_MSG_PRESENCE_EVENT:
		while ((ret = pb_next(payload, payload_len, &pos, &f)) > 0) {
			if (f.number == 1 && f.wire == 0) {
				int new_presence;

				if (f.value == 1)
					new_presence = 1;
				else if (f.value == 2)
					new_presence = 0;
				else
					break;

				mutex_lock(&hpd->lock);
				hpd->presence = new_presence;
				hpd->presence_valid = true;
				mutex_unlock(&hpd->lock);
				iio_push_event(hpd->indio_dev,
					IIO_UNMOD_EVENT_CODE(IIO_PROXIMITY, 0,
						IIO_EV_TYPE_CHANGE,
						IIO_EV_DIR_EITHER),
					iio_get_time_ns(hpd->indio_dev));
				break;
			}
		}
		break;
	case A14_SSC_MSG_ERROR_EVENT:
		while ((ret = pb_next(payload, payload_len, &pos, &f)) > 0) {
			if (f.number == 1 && f.wire == 0) {
				dev_err(hpd->dev, "SSC sensor error event=%llu\n",
					f.value);
				break;
			}
		}
		break;
	default:
		dev_dbg(hpd->dev, "SSC event message=%u payload=%zu\n",
			msg_id, payload_len);
		break;
	}
}

void a14_ssc_parse_report(struct a14_ssc_hpd *hpd, const u8 *buf, size_t len)
{
	size_t pos = 0;
	struct pb_field f;
	int ret;

	/* QMI_DATA_LEN has already consumed the QMI array-length field. */
	while ((ret = pb_next(buf, len, &pos, &f)) > 0) {
		if (f.number == 2 && f.wire == 2) {
			size_t ep = 0;
			struct pb_field ef;
			u32 msg_id = 0;
			const u8 *payload = NULL;
			size_t payload_len = 0;

			while (pb_next(f.data, f.len, &ep, &ef) > 0) {
				if (ef.number == 1 && ef.wire == 5)
					msg_id = get_le32(ef.data);
				else if (ef.number == 3 && ef.wire == 2) {
					payload = ef.data;
					payload_len = ef.len;
				}
			}
			if (msg_id && payload)
				parse_event(hpd, msg_id, payload, payload_len);
		}
	}
}
