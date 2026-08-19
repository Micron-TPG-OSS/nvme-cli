// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Copyright (c) 2026 Micron Technology, Inc.
 *
 * Authors: Broc Going <bgoing@micron.com>
 *
 * SPDM (DMTF DSP0274) requester for retrieving and classifying a device
 * certificate chain, carried over the NVMe Security Send/Receive transport
 * defined by the SPDM-over-Storage binding (DMTF DSP0286).
 *
 * Only the five messages needed to read a certificate chain are implemented:
 * GET_VERSION, GET_CAPABILITIES, NEGOTIATE_ALGORITHMS, GET_DIGESTS and
 * GET_CERTIFICATE. There is no session establishment, no CHALLENGE and no
 * signature verification, so no SPDM library is needed -- the messages have
 * fixed layouts and are built and parsed byte by byte below.
 */

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <libnvme.h>

#include <ccan/endian/endian.h>
#include <shared/crypto-util.h>
#include <shared/fs-util.h>
#include <shared/io-util.h>
#include <shared/x509-util.h>

#include "global-ctx.h"
#include "micron-spdm.h"
#include "nvme-print.h"
#include "plugin.h"
#include "src/cleanup.h"

/*
 * DSP0286 SPDM-over-Storage transport binding.
 *
 * The security protocol and the SPSP0 operation codes below are the values
 * DSP0286 assigns; a device whose firmware predates the published binding may
 * use different ones, so --secp and --conn-id let an operator override them
 * without a rebuild. Keep every binding-specific constant in this block so a
 * spec correction stays a one-place change.
 */
#define MICRON_SPDM_SECP		0xe8	/* SECP: DMTF SPDM */
#define MICRON_SPDM_NSSF		0x00	/* reserved by DSP0286 */

#define SPDM_STORAGE_OP_DISCOVERY	0x01
#define SPDM_STORAGE_OP_PENDING_INFO	0x02
#define SPDM_STORAGE_OP_MESSAGE		0x05
#define SPDM_STORAGE_OP_SECURED_MESSAGE	0x06

/*
 * Every storage message is prefixed with its own total length as a 32-bit
 * little-endian count, so the responder can return a short message into a
 * fixed-size Security Receive allocation.
 */
#define SPDM_STORAGE_HDR_SIZE		4

/* SPDM message header: version, request/response code, Param1, Param2. */
#define SPDM_HDR_SIZE			4

#define SPDM_VERSION_1_0		0x10
#define SPDM_VERSION_1_1		0x11
#define SPDM_VERSION_1_2		0x12
#define SPDM_VERSION_1_3		0x13

/* Request codes. */
#define SPDM_GET_DIGESTS		0x81
#define SPDM_GET_CERTIFICATE		0x82
#define SPDM_GET_VERSION		0x84
#define SPDM_GET_CAPABILITIES		0xe1
#define SPDM_NEGOTIATE_ALGORITHMS	0xe3
#define SPDM_RESPOND_IF_READY		0xff

/* Response codes. */
#define SPDM_DIGESTS			0x01
#define SPDM_CERTIFICATE		0x02
#define SPDM_VERSION			0x04
#define SPDM_CAPABILITIES		0x61
#define SPDM_ALGORITHMS			0x63
#define SPDM_ERROR			0x7f

/* Error codes carried in an ERROR response Param1. */
#define SPDM_ERR_INVALID_REQUEST	0x01
#define SPDM_ERR_BUSY			0x03
#define SPDM_ERR_UNEXPECTED_REQUEST	0x04
#define SPDM_ERR_UNSPECIFIED		0x05
#define SPDM_ERR_UNSUPPORTED_REQUEST	0x07
#define SPDM_ERR_VERSION_MISMATCH	0x41
#define SPDM_ERR_RESPONSE_NOT_READY	0x42
#define SPDM_ERR_REQUEST_RESYNCH	0x43
#define SPDM_ERR_OPERATION_FAILED	0x44

/* Measurement specification and algorithm selection bits. */
#define SPDM_MEAS_SPEC_DMTF		0x01

#define SPDM_BASE_HASH_SHA_256		0x00000001
#define SPDM_BASE_HASH_SHA_384		0x00000002
#define SPDM_BASE_HASH_SHA_512		0x00000004

#define SPDM_BASE_ASYM_RSASSA_2048	0x00000001
#define SPDM_BASE_ASYM_RSASSA_3072	0x00000004
#define SPDM_BASE_ASYM_ECDSA_P256	0x00000010
#define SPDM_BASE_ASYM_RSASSA_4096	0x00000020
#define SPDM_BASE_ASYM_ECDSA_P384	0x00000080
#define SPDM_BASE_ASYM_ECDSA_P521	0x00000100

/*
 * The hash algorithms we advertise, i.e. those shr_sha*() can reproduce for the
 * GET_DIGESTS comparison. Offering an algorithm we cannot compute would leave
 * the digest check permanently unavailable.
 */
#define SPDM_HASH_ALGOS_SUPPORTED					\
	(SPDM_BASE_HASH_SHA_256 | SPDM_BASE_HASH_SHA_384 |		\
	 SPDM_BASE_HASH_SHA_512)

/*
 * Signature algorithms are advertised only because NEGOTIATE_ALGORITHMS
 * requires a non-zero selection; no signature is ever verified here.
 */
#define SPDM_ASYM_ALGOS_SUPPORTED					\
	(SPDM_BASE_ASYM_RSASSA_2048 | SPDM_BASE_ASYM_RSASSA_3072 |	\
	 SPDM_BASE_ASYM_RSASSA_4096 | SPDM_BASE_ASYM_ECDSA_P256 |	\
	 SPDM_BASE_ASYM_ECDSA_P384 | SPDM_BASE_ASYM_ECDSA_P521)

/* Fixed message sizes, per DSP0274. */
#define SPDM_VERSION_RSP_MIN		6
#define SPDM_GET_CAPS_1_1_SIZE		12
#define SPDM_GET_CAPS_1_2_SIZE		20
#define SPDM_CAPS_RSP_MIN		12
#define SPDM_NEG_ALGS_SIZE		32
#define SPDM_ALGS_RSP_MIN		36
#define SPDM_GET_CERT_SIZE		8
#define SPDM_CERT_RSP_HDR_SIZE		8

/* Certificate chain header: Length, Reserved, RootHash[H]. */
#define SPDM_CERT_CHAIN_HDR_SIZE	4

#define SPDM_MAX_SLOT			7

/*
 * A chain of four ~1 KiB certificates is the expected case; 64 KiB is both a
 * generous ceiling and the largest chain the 16-bit GET_CERTIFICATE offset can
 * address.
 */
#define SPDM_MAX_CHAIN_SIZE		65536

/*
 * @SPDM_MAX_MSG_SIZE bounds an SPDM message; the Security Send/Receive buffer
 * is that plus the storage length prefix, so the two limits are defined
 * together to keep every buffer here consistently sized.
 */
#define SPDM_MAX_MSG_SIZE		4092
#define SPDM_MAX_XFER_SIZE		(SPDM_MAX_MSG_SIZE + \
					 SPDM_STORAGE_HDR_SIZE)
#define SPDM_DEFAULT_XFER_SIZE		1024

/* Bound the ResponseNotReady retry loop so a stuck device cannot hang us. */
#define SPDM_MAX_NOT_READY_RETRY	8

/*
 * A responder timing exponent is a power-of-two microsecond count. Cap it so a
 * bogus value cannot turn into a multi-hour sleep.
 */
#define SPDM_MAX_WAIT_US		2000000

struct spdm_ctx {
	struct libnvme_transport_handle	*hdl;
	uint8_t		secp;		/* NVMe security protocol */
	uint8_t		conn_id;	/* DSP0286 connection ID */
	uint8_t		version;	/* negotiated, 0x12 for 1.2 */
	uint8_t		ct_exponent;	/* responder CT = 2^n us */
	uint32_t	base_hash_algo;	/* selected SPDM_BASE_HASH_* */
	size_t		hash_size;	/* digest size of the above */
	uint32_t	xfer_size;	/* per-message payload limit */
};

/* One certificate of the retrieved chain, plus how we label it in output. */
struct spdm_cert {
	struct shr_x509_info	info;
	const char		*role;	/* root/intermediate/leaf */
};

enum spdm_chain_class {
	SPDM_CHAIN_SELF_SIGNED,
	SPDM_CHAIN_COMPLETE,
	SPDM_CHAIN_INCOMPLETE,
};

struct spdm_chain {
	unsigned char		*raw;		/* with chain header */
	size_t			raw_len;
	const unsigned char	*root_hash;	/* into @raw */
	const unsigned char	*certs;		/* into @raw */
	size_t			certs_len;
	struct spdm_cert	*cert;
	unsigned int		count;
	enum spdm_chain_class	klass;
};

static uint16_t get_le16(const unsigned char *p)
{
	return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t get_le32(const unsigned char *p)
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
	       ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void put_le16(unsigned char *p, uint16_t v)
{
	p[0] = v & 0xff;
	p[1] = (v >> 8) & 0xff;
}

static void put_le32(unsigned char *p, uint32_t v)
{
	p[0] = v & 0xff;
	p[1] = (v >> 8) & 0xff;
	p[2] = (v >> 16) & 0xff;
	p[3] = (v >> 24) & 0xff;
}

static const char *hash_algo_name(uint32_t algo)
{
	switch (algo) {
	case SPDM_BASE_HASH_SHA_256:
		return "SHA-256";
	case SPDM_BASE_HASH_SHA_384:
		return "SHA-384";
	case SPDM_BASE_HASH_SHA_512:
		return "SHA-512";
	default:
		return "unknown";
	}
}

static size_t hash_algo_size(uint32_t algo)
{
	switch (algo) {
	case SPDM_BASE_HASH_SHA_256:
		return SHR_SHA256_SIZE;
	case SPDM_BASE_HASH_SHA_384:
		return SHR_SHA384_SIZE;
	case SPDM_BASE_HASH_SHA_512:
		return SHR_SHA512_SIZE;
	default:
		return 0;
	}
}

static unsigned char *spdm_hash(const struct spdm_ctx *ctx,
			        const unsigned char *data, size_t len)
{
	switch (ctx->base_hash_algo) {
	case SPDM_BASE_HASH_SHA_256:
		return shr_sha256(data, len);
	case SPDM_BASE_HASH_SHA_384:
		return shr_sha384(data, len);
	case SPDM_BASE_HASH_SHA_512:
		return shr_sha512(data, len);
	default:
		return NULL;
	}
}

static const char *spdm_error_str(uint8_t code)
{
	switch (code) {
	case SPDM_ERR_INVALID_REQUEST:
		return "InvalidRequest";
	case SPDM_ERR_BUSY:
		return "Busy";
	case SPDM_ERR_UNEXPECTED_REQUEST:
		return "UnexpectedRequest";
	case SPDM_ERR_UNSPECIFIED:
		return "Unspecified";
	case SPDM_ERR_UNSUPPORTED_REQUEST:
		return "UnsupportedRequest";
	case SPDM_ERR_VERSION_MISMATCH:
		return "VersionMismatch";
	case SPDM_ERR_RESPONSE_NOT_READY:
		return "ResponseNotReady";
	case SPDM_ERR_REQUEST_RESYNCH:
		return "RequestResynch";
	case SPDM_ERR_OPERATION_FAILED:
		return "OperationFailed";
	default:
		return "unrecognized";
	}
}

/* Sleep 2^@exponent microseconds, clamped. */
static void spdm_wait(uint8_t exponent)
{
	unsigned long us;

	if (exponent >= 21)
		us = SPDM_MAX_WAIT_US;
	else
		us = 1UL << exponent;

	usleep(us);
}

/* SPSP: the operation code in SPSP0, the connection ID in SPSP1. */
static uint16_t spdm_spsp(const struct spdm_ctx *ctx, uint8_t op)
{
	return (uint16_t)op | ((uint16_t)ctx->conn_id << 8);
}

/*
 * Report a failed Security Send/Receive. A drive without an SPDM responder
 * rejects SECP itself, so the failure arrives as a transport error rather than
 * an SPDM ERROR response; say so explicitly, because the bare status alone
 * leaves an operator with no idea the drive simply lacks the feature.
 */
static void spdm_report_xport_err(struct spdm_ctx *ctx, int err, bool is_send)
{
	int sc = err > 0 ? (err & 0x7ff) : 0;

	/*
	 * nvme_show_err() drops the caller's message for a positive NVMe
	 * status, so route those through the helper that keeps both.
	 */
	if (err > 0)
		nvme_show_error_status(err, "SPDM: Security %s (SECP 0x%02x)",
				       is_send ? "Send" : "Receive", ctx->secp);
	else
		nvme_show_err(err, "SPDM: Security %s (SECP 0x%02x) failed",
			      is_send ? "Send" : "Receive", ctx->secp);

	/*
	 * A rejected SECP looks like Invalid Field in Command from the
	 * controller, or ENOTSUP/EINVAL when a host driver screens the
	 * protocol before it reaches the drive.
	 */
	if (sc == NVME_SC_INVALID_FIELD || err == -ENOTSUP ||
	    err == -EOPNOTSUPP || err == -EINVAL)
		nvme_show_error("SPDM: the drive rejected security protocol "
				"0x%02x, so its firmware may have no SPDM "
				"responder. List the protocols it does "
				"support with:\n"
				"  nvme security recv <device> --secp=0 "
				"--spsp=0 --size=512 --al=512 -b | xxd",
				ctx->secp);
}

static int spdm_send(struct spdm_ctx *ctx, const unsigned char *msg, size_t len)
{
	__cleanup_libnvme_free unsigned char *buf = NULL;
	struct libnvme_passthru_cmd cmd;
	size_t total = SPDM_STORAGE_HDR_SIZE + len;
	int err;

	if (len > SPDM_MAX_MSG_SIZE)
		return -EMSGSIZE;

	buf = libnvme_alloc(total);
	if (!buf)
		return -ENOMEM;

	put_le32(buf, (uint32_t)total);
	memcpy(buf + SPDM_STORAGE_HDR_SIZE, msg, len);

	nvme_init_security_send(&cmd, NVME_NSID_NONE, MICRON_SPDM_NSSF,
				spdm_spsp(ctx, SPDM_STORAGE_OP_MESSAGE),
				ctx->secp, (uint32_t)total, buf,
				(uint32_t)total);

	err = libnvme_exec_admin_passthru(ctx->hdl, &cmd);
	if (err)
		spdm_report_xport_err(ctx, err, true);

	return err;
}

/*
 * Read one storage message into @msg. The allocation length has to be chosen
 * before the response size is known, so ask for the largest message we are
 * willing to handle and let the length prefix say how much is real.
 */
static int spdm_recv(struct spdm_ctx *ctx, unsigned char *msg, size_t cap,
		     size_t *outlen)
{
	__cleanup_libnvme_free unsigned char *buf = NULL;
	struct libnvme_passthru_cmd cmd;
	size_t total = SPDM_STORAGE_HDR_SIZE + cap;
	size_t len;
	int err;

	/* Round up: some controllers reject a non-dword allocation length. */
	total = (total + 3) & ~(size_t)3;

	if (total > SPDM_MAX_XFER_SIZE)
		return -EMSGSIZE;

	buf = libnvme_alloc(total);
	if (!buf)
		return -ENOMEM;

	nvme_init_security_receive(&cmd, NVME_NSID_NONE, MICRON_SPDM_NSSF,
				   spdm_spsp(ctx, SPDM_STORAGE_OP_MESSAGE),
				   ctx->secp, (uint32_t)total, buf,
				   (uint32_t)total);

	err = libnvme_exec_admin_passthru(ctx->hdl, &cmd);
	if (err) {
		spdm_report_xport_err(ctx, err, false);
		return err;
	}

	/*
	 * The length is bounded against @cap rather than the rounded-up
	 * allocation, so a responder cannot talk us into copying past @msg.
	 */
	len = get_le32(buf);
	if (len < SPDM_STORAGE_HDR_SIZE + SPDM_HDR_SIZE ||
	    len > SPDM_STORAGE_HDR_SIZE + cap) {
		nvme_show_error("SPDM: response length %zu out of range",
				len);
		return -EPROTO;
	}

	*outlen = len - SPDM_STORAGE_HDR_SIZE;
	memcpy(msg, buf + SPDM_STORAGE_HDR_SIZE, *outlen);

	return 0;
}

/*
 * Send @req and collect the matching response, absorbing the ResponseNotReady
 * handshake. @expect is the response code the caller requires; an ERROR
 * response is reported with its SPDM error code rather than a bare errno,
 * because that code is usually the whole diagnosis (UnsupportedRequest for a
 * drive without SPDM, VersionMismatch for a stale connection).
 */
static int spdm_xfer(struct spdm_ctx *ctx, const unsigned char *req,
		     size_t reqlen, uint8_t expect, unsigned char *rsp,
		     size_t cap, size_t *rsplen)
{
	unsigned int retry = 0;
	int err;

	err = spdm_send(ctx, req, reqlen);
	if (err)
		return err;

	for (;;) {
		spdm_wait(ctx->ct_exponent);

		err = spdm_recv(ctx, rsp, cap, rsplen);
		if (err)
			return err;

		if (rsp[1] == expect)
			return 0;

		if (rsp[1] != SPDM_ERROR) {
			nvme_show_error("SPDM: expected response 0x%02x, got 0x%02x",
					expect, rsp[1]);
			return -EPROTO;
		}

		/*
		 * ResponseNotReady carries the delay and a token in its
		 * extended data; poll with RESPOND_IF_READY until the
		 * responder produces the real response.
		 */
		if (rsp[2] == SPDM_ERR_RESPONSE_NOT_READY && *rsplen >= 8 &&
		    retry++ < SPDM_MAX_NOT_READY_RETRY) {
			unsigned char poll[SPDM_HDR_SIZE];
			uint8_t rdt_exponent = rsp[4];
			uint8_t token = rsp[6];

			spdm_wait(rdt_exponent);

			poll[0] = ctx->version;
			poll[1] = SPDM_RESPOND_IF_READY;
			poll[2] = req[1];
			poll[3] = token;

			err = spdm_send(ctx, poll, sizeof(poll));
			if (err)
				return err;
			continue;
		}

		nvme_show_error("SPDM: request 0x%02x failed, error 0x%02x (%s), data 0x%02x",
				req[1], rsp[2], spdm_error_str(rsp[2]), rsp[3]);
		return -EPROTO;
	}
}

/*
 * GET_VERSION also resets the connection, so it must go first and must itself
 * be sent as version 1.0. Pick the highest version the responder lists that we
 * know how to encode.
 */
static int spdm_get_version(struct spdm_ctx *ctx)
{
	unsigned char rsp[SPDM_MAX_MSG_SIZE];
	unsigned char req[SPDM_HDR_SIZE] = { SPDM_VERSION_1_0, SPDM_GET_VERSION,
					     0x00, 0x00 };
	uint8_t best = 0;
	size_t rsplen;
	unsigned int i;
	unsigned int count;
	int err;

	err = spdm_xfer(ctx, req, sizeof(req), SPDM_VERSION, rsp, sizeof(rsp),
			&rsplen);
	if (err)
		return err;

	if (rsplen < SPDM_VERSION_RSP_MIN)
		return -EPROTO;

	count = rsp[5];
	if (rsplen < SPDM_VERSION_RSP_MIN + (size_t)count * 2) {
		nvme_show_error("SPDM: VERSION lists %u entries but is only %zu bytes",
				count, rsplen);
		return -EPROTO;
	}

	for (i = 0; i < count; i++) {
		/*
		 * A VersionNumberEntry packs major/minor in its high byte and
		 * update/alpha in its low byte; only major.minor is negotiated.
		 */
		uint8_t ver = (uint8_t)(get_le16(&rsp[6 + i * 2]) >> 8);

		if (ver > best && ver <= SPDM_VERSION_1_3)
			best = ver;
	}

	if (best < SPDM_VERSION_1_1) {
		nvme_show_error("SPDM: device offers no supported version (need 1.1 or later)");
		return -ENOTSUP;
	}

	ctx->version = best;

	return 0;
}

static int spdm_get_capabilities(struct spdm_ctx *ctx)
{
	unsigned char req[SPDM_GET_CAPS_1_2_SIZE] = { 0 };
	unsigned char rsp[SPDM_MAX_MSG_SIZE];
	size_t reqlen;
	size_t rsplen;
	int err;

	req[0] = ctx->version;
	req[1] = SPDM_GET_CAPABILITIES;

	/*
	 * We are a requester with no capabilities to advertise: Flags stays
	 * zero. 1.2 added the transfer-size fields, which do change the
	 * request length.
	 */
	if (ctx->version >= SPDM_VERSION_1_2) {
		reqlen = SPDM_GET_CAPS_1_2_SIZE;
		/* DataTransferSize then MaxSPDMmsgSize. */
		put_le32(&req[12], SPDM_MAX_MSG_SIZE);
		put_le32(&req[16], SPDM_MAX_CHAIN_SIZE);
	} else {
		reqlen = SPDM_GET_CAPS_1_1_SIZE;
	}

	err = spdm_xfer(ctx, req, reqlen, SPDM_CAPABILITIES, rsp, sizeof(rsp),
			&rsplen);
	if (err)
		return err;

	if (rsplen < SPDM_CAPS_RSP_MIN)
		return -EPROTO;

	ctx->ct_exponent = rsp[5];

	if (ctx->version >= SPDM_VERSION_1_2 &&
	    rsplen >= SPDM_GET_CAPS_1_2_SIZE) {
		uint32_t dts = get_le32(&rsp[12]);

		/*
		 * DataTransferSize bounds a single message, so it bounds how
		 * much of the chain one GET_CERTIFICATE may return. Ignore an
		 * implausible value rather than deriving a zero chunk size.
		 */
		if (dts > SPDM_HDR_SIZE && dts <= SPDM_MAX_MSG_SIZE)
			ctx->xfer_size = dts;
	}

	return 0;
}

static int spdm_negotiate_algorithms(struct spdm_ctx *ctx)
{
	unsigned char req[SPDM_NEG_ALGS_SIZE] = { 0 };
	unsigned char rsp[SPDM_MAX_MSG_SIZE];
	size_t rsplen;
	uint32_t hash;
	int err;

	req[0] = ctx->version;
	req[1] = SPDM_NEGOTIATE_ALGORITHMS;
	req[2] = 0;			/* no ReqAlgStruct entries */
	put_le16(&req[4], SPDM_NEG_ALGS_SIZE);
	req[6] = SPDM_MEAS_SPEC_DMTF;
	put_le32(&req[8], SPDM_ASYM_ALGOS_SUPPORTED);
	put_le32(&req[12], SPDM_HASH_ALGOS_SUPPORTED);
	/* ExtAsymCount and ExtHashCount at 28 and 29 stay zero. */

	err = spdm_xfer(ctx, req, sizeof(req), SPDM_ALGORITHMS, rsp,
			sizeof(rsp), &rsplen);
	if (err)
		return err;

	if (rsplen < SPDM_ALGS_RSP_MIN)
		return -EPROTO;

	/* BaseHashSel must name exactly one algorithm, and one we offered. */
	hash = get_le32(&rsp[16]);
	if (!hash || (hash & (hash - 1)) ||
	    !(hash & SPDM_HASH_ALGOS_SUPPORTED)) {
		nvme_show_error("SPDM: device selected unusable hash algorithm 0x%08" PRIx32,
				hash);
		return -ENOTSUP;
	}

	ctx->base_hash_algo = hash;
	ctx->hash_size = hash_algo_size(hash);

	return 0;
}

/*
 * Fetch the digest of @slot. The response holds one digest per populated slot
 * in ascending slot order, so the offset of ours depends on how many lower
 * slots are populated.
 */
static int spdm_get_digest(struct spdm_ctx *ctx, uint8_t slot,
			   unsigned char **digest)
{
	unsigned char req[SPDM_HDR_SIZE] = { 0 };
	unsigned char rsp[SPDM_MAX_MSG_SIZE];
	unsigned int index = 0;
	uint8_t slot_mask;
	size_t rsplen;
	size_t off;
	uint8_t i;
	int err;

	req[0] = ctx->version;
	req[1] = SPDM_GET_DIGESTS;

	err = spdm_xfer(ctx, req, sizeof(req), SPDM_DIGESTS, rsp, sizeof(rsp),
			&rsplen);
	if (err)
		return err;

	slot_mask = rsp[3];
	if (!(slot_mask & (1u << slot))) {
		nvme_show_error("SPDM: slot %u is not populated (slot mask 0x%02x)",
				slot, slot_mask);
		return -ENOENT;
	}

	for (i = 0; i < slot; i++) {
		if (slot_mask & (1u << i))
			index++;
	}

	off = SPDM_HDR_SIZE + (size_t)index * ctx->hash_size;
	if (rsplen < off + ctx->hash_size) {
		nvme_show_error("SPDM: DIGESTS is %zu bytes, too short for slot %u",
				rsplen, slot);
		return -EPROTO;
	}

	*digest = malloc(ctx->hash_size);
	if (!*digest)
		return -ENOMEM;

	memcpy(*digest, &rsp[off], ctx->hash_size);

	return 0;
}

/*
 * Read the whole certificate chain of @slot. GET_CERTIFICATE returns a portion
 * at a time and reports what is left, so the total size is only known after the
 * first response.
 */
static int spdm_get_certificate(struct spdm_ctx *ctx, uint8_t slot,
				unsigned char **chain, size_t *chain_len)
{
	unsigned char rsp[SPDM_MAX_MSG_SIZE];
	unsigned char req[SPDM_GET_CERT_SIZE] = { 0 };
	unsigned char *buf = NULL;
	size_t total = 0;
	size_t off = 0;
	uint16_t chunk;
	int err;

	/*
	 * One response must fit a portion plus its header inside both the
	 * negotiated transfer size and the 16-bit Length field.
	 */
	chunk = (uint16_t)(ctx->xfer_size - SPDM_CERT_RSP_HDR_SIZE);

	req[0] = ctx->version;
	req[1] = SPDM_GET_CERTIFICATE;
	req[2] = slot & 0x0f;

	do {
		uint16_t portion, remainder;
		size_t rsplen;

		put_le16(&req[4], (uint16_t)off);
		put_le16(&req[6], chunk);

		err = spdm_xfer(ctx, req, sizeof(req), SPDM_CERTIFICATE, rsp,
				sizeof(rsp), &rsplen);
		if (err)
			goto err_free;

		if (rsplen < SPDM_CERT_RSP_HDR_SIZE) {
			err = -EPROTO;
			goto err_free;
		}

		portion = get_le16(&rsp[4]);
		remainder = get_le16(&rsp[6]);

		/*
		 * A zero portion would spin forever, and a portion larger than
		 * the response would read past it.
		 */
		if (!portion ||
		    rsplen < SPDM_CERT_RSP_HDR_SIZE + (size_t)portion) {
			nvme_show_error("SPDM: CERTIFICATE portion %u overruns a %zu byte response",
					portion, rsplen);
			err = -EPROTO;
			goto err_free;
		}

		if (!buf) {
			total = (size_t)portion + remainder;
			if (total > SPDM_MAX_CHAIN_SIZE) {
				nvme_show_error("SPDM: chain of %zu bytes exceeds the %u byte cap",
						total, SPDM_MAX_CHAIN_SIZE);
				return -EMSGSIZE;
			}
			buf = malloc(total);
			if (!buf)
				return -ENOMEM;
		}

		if (off + portion > total) {
			nvme_show_error("SPDM: chain grew past its announced %zu bytes",
					total);
			err = -EPROTO;
			goto err_free;
		}

		memcpy(buf + off, &rsp[SPDM_CERT_RSP_HDR_SIZE], portion);
		off += portion;

		if (!remainder)
			break;
	} while (off < total);

	if (off != total) {
		nvme_show_error("SPDM: got %zu of %zu certificate chain bytes",
				off, total);
		err = -EPROTO;
		goto err_free;
	}

	*chain = buf;
	*chain_len = total;

	return 0;

err_free:
	free(buf);
	return err;
}

static void chain_free(struct spdm_chain *chain)
{
	unsigned int i;

	for (i = 0; i < chain->count; i++)
		shr_x509_info_free(&chain->cert[i].info);

	free(chain->cert);
	free(chain->raw);
	memset(chain, 0, sizeof(*chain));
}

/*
 * Split the DSP0274 certificate-chain blob into its header and the concatenated
 * DER certificates, then parse each certificate. The chain is ordered root
 * first, so the last certificate is the leaf.
 */
static int chain_parse(struct spdm_chain *chain, size_t hash_size)
{
	size_t hdr_len = SPDM_CERT_CHAIN_HDR_SIZE + hash_size;
	unsigned int count = 0;
	unsigned int i;
	size_t off;
	uint16_t announced;
	int err;

	if (chain->raw_len <= hdr_len) {
		nvme_show_error("SPDM: certificate chain of %zu bytes has no certificates",
				chain->raw_len);
		return -EPROTO;
	}

	announced = get_le16(chain->raw);
	if (announced != chain->raw_len)
		nvme_show_error("SPDM: warning: chain header announces %u bytes, %zu received",
				announced, chain->raw_len);

	chain->root_hash = chain->raw + SPDM_CERT_CHAIN_HDR_SIZE;
	chain->certs = chain->raw + hdr_len;
	chain->certs_len = chain->raw_len - hdr_len;

	/*
	 * Count the certificates first, so the array is sized exactly.
	 * chain->count stays zero until the array exists, so a failure here
	 * leaves nothing for chain_free() to walk.
	 */
	for (off = 0; off < chain->certs_len; count++) {
		size_t len = shr_x509_der_len(chain->certs + off,
					      chain->certs_len - off);

		if (!len) {
			nvme_show_error("SPDM: malformed certificate at chain offset %zu",
					off);
			return -EILSEQ;
		}
		off += len;
	}

	chain->cert = calloc(count, sizeof(*chain->cert));
	if (!chain->cert)
		return -ENOMEM;

	chain->count = count;

	for (i = 0, off = 0; i < chain->count; i++) {
		err = shr_x509_parse(chain->certs + off, chain->certs_len - off,
				     &chain->cert[i].info);
		if (err) {
			/*
			 * Keep the certificates parsed so far so chain_free()
			 * releases them; count only the valid ones.
			 */
			chain->count = i;
			nvme_show_error("SPDM: cannot parse certificate %u of the chain",
					i);
			return err;
		}
		off += chain->cert[i].info.der_len;
	}

	/*
	 * Classify: a lone self-signed certificate is the device asserting its
	 * own identity, while a chain is only useful if it terminates in a
	 * self-signed root. Anything else is reported but not fatal -- the
	 * operator still gets the fields.
	 */
	if (chain->count == 1)
		chain->klass = chain->cert[0].info.self_signed ?
			SPDM_CHAIN_SELF_SIGNED : SPDM_CHAIN_INCOMPLETE;
	else if (chain->cert[0].info.self_signed)
		chain->klass = SPDM_CHAIN_COMPLETE;
	else
		chain->klass = SPDM_CHAIN_INCOMPLETE;

	for (i = 0; i < chain->count; i++) {
		if (i == 0 && chain->cert[i].info.self_signed)
			chain->cert[i].role = "root";
		else if (i + 1 == chain->count)
			chain->cert[i].role = "leaf";
		else
			chain->cert[i].role = "intermediate";
	}

	return 0;
}

static const char *chain_class_str(enum spdm_chain_class klass)
{
	switch (klass) {
	case SPDM_CHAIN_SELF_SIGNED:
		return "self-signed";
	case SPDM_CHAIN_COMPLETE:
		return "full chain";
	default:
		return "incomplete chain";
	}
}

static const char *chain_class_detail(enum spdm_chain_class klass)
{
	switch (klass) {
	case SPDM_CHAIN_SELF_SIGNED:
		return "single certificate, issuer equals subject";
	case SPDM_CHAIN_COMPLETE:
		return "terminates at a self-signed root CA";
	default:
		return "does not terminate at a self-signed root CA";
	}
}

/*
 * Advisory only: does any certificate in the chain name Micron as issuer or
 * subject? This never affects the exit status, because a genuine chain from a
 * differently branded product line would fail a name match while still being
 * authentic.
 */
static bool chain_is_micron(const struct spdm_chain *chain)
{
	static const char *needle = "Micron Technology";
	unsigned int i;

	for (i = 0; i < chain->count; i++) {
		const struct shr_x509_info *info = &chain->cert[i].info;

		if (info->issuer && strstr(info->issuer, needle))
			return true;
		if (info->subject && strstr(info->subject, needle))
			return true;
	}

	return false;
}

static char *hex_dup(const unsigned char *buf, size_t len)
{
	char *out;
	size_t i;

	out = malloc(len * 2 + 1);
	if (!out)
		return NULL;

	for (i = 0; i < len; i++)
		snprintf(out + i * 2, 3, "%02x", buf[i]);

	return out;
}

/*
 * The two integrity checks the device lets us make without verifying a
 * signature: GET_DIGESTS is a hash over the whole chain blob, and the chain
 * header carries a hash of the root certificate alone.
 */
static bool digest_matches(const struct spdm_ctx *ctx,
			   const unsigned char *data, size_t len,
			   const unsigned char *expect)
{
	unsigned char *got;
	bool match;

	got = spdm_hash(ctx, data, len);
	if (!got)
		return false;

	match = !memcmp(got, expect, ctx->hash_size);
	free(got);

	return match;
}

static const char *pass_fail(bool ok)
{
	return ok ? "PASS" : "FAIL";
}

static void show_chain_normal(const struct spdm_ctx *ctx,
			      const struct spdm_chain *chain, uint8_t slot,
			      bool digest_ok, bool root_hash_ok)
{
	unsigned int i;

	printf("SPDM certificate chain, slot %u\n\n", slot);
	printf("SPDM version              : %u.%u\n", ctx->version >> 4,
	       ctx->version & 0x0f);
	printf("Negotiated hash algorithm : %s\n",
	       hash_algo_name(ctx->base_hash_algo));
	printf("Certificate count         : %u\n", chain->count);
	printf("Classification            : %s (%s)\n",
	       chain_class_str(chain->klass), chain_class_detail(chain->klass));
	printf("Chain digest check        : %s\n", pass_fail(digest_ok));
	printf("Root hash check           : %s\n", pass_fail(root_hash_ok));
	printf("Micron origin             : %s\n",
	       chain_is_micron(chain) ? "yes" : "not indicated");

	for (i = 0; i < chain->count; i++) {
		const struct shr_x509_info *info = &chain->cert[i].info;

		printf("\nCertificate %u (%s)\n", i, chain->cert[i].role);
		printf("  Subject      : %s\n", info->subject);
		printf("  Issuer       : %s\n", info->issuer);
		printf("  Common name  : %s\n",
		       info->subject_cn ? info->subject_cn : "n/a");
		printf("  Serial       : %s\n", info->serial ? info->serial : "n/a");
		printf("  Valid from   : %s\n",
		       info->not_before ? info->not_before : "n/a");
		printf("  Valid to     : %s\n",
		       info->not_after ? info->not_after : "n/a");
		printf("  Self-signed  : %s\n", info->self_signed ? "yes" : "no");
	}
}

static void show_chain_json(const struct spdm_ctx *ctx,
			    const struct spdm_chain *chain, uint8_t slot,
			    bool digest_ok, bool root_hash_ok)
{
	struct json_object *root = json_create_object();
	struct json_object *certs = json_create_array();
	char version[8];
	char *root_hash;
	unsigned int i;

	snprintf(version, sizeof(version), "%u.%u", ctx->version >> 4,
		 ctx->version & 0x0f);

	json_object_add_value_uint(root, "slot", slot);
	json_object_add_value_string(root, "spdm_version", version);
	json_object_add_value_string(root, "hash_algorithm",
				     hash_algo_name(ctx->base_hash_algo));
	json_object_add_value_uint(root, "certificate_count", chain->count);
	json_object_add_value_string(root, "classification",
				     chain_class_str(chain->klass));
	json_object_add_value_string(root, "classification_detail",
				     chain_class_detail(chain->klass));
	json_object_add_value_bool(root, "digest_check", digest_ok);
	json_object_add_value_bool(root, "root_hash_check", root_hash_ok);
	json_object_add_value_bool(root, "micron_origin",
				   chain_is_micron(chain));

	root_hash = hex_dup(chain->root_hash, ctx->hash_size);
	json_object_add_value_string(root, "root_hash", root_hash);
	free(root_hash);

	for (i = 0; i < chain->count; i++) {
		const struct shr_x509_info *info = &chain->cert[i].info;
		struct json_object *cert = json_create_object();

		json_object_add_value_uint(cert, "index", i);
		json_object_add_value_string(cert, "role", chain->cert[i].role);
		json_object_add_value_string(cert, "subject", info->subject);
		json_object_add_value_string(cert, "issuer", info->issuer);
		json_object_add_value_string(cert, "common_name",
					     info->subject_cn);
		json_object_add_value_string(cert, "serial", info->serial);
		json_object_add_value_string(cert, "not_before",
					     info->not_before);
		json_object_add_value_string(cert, "not_after", info->not_after);
		json_object_add_value_bool(cert, "self_signed",
					   info->self_signed);
		json_array_add_value_object(certs, cert);
	}

	json_object_add_value_array(root, "certificates", certs);

	json_print_object(root, NULL);
	printf("\n");
	json_free_object(root);
}

/* Write the chain blob out verbatim, for openssl or another SPDM tool. */
static int chain_write_file(const char *path, const unsigned char *buf,
			    size_t len)
{
	int fd;
	int err;

	fd = shr_open_rawdata(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) {
		nvme_show_error("Failed to open %s: %s", path, strerror(errno));
		return -errno;
	}

	err = shr_write_all(fd, buf, len);
	if (err)
		nvme_show_error("Failed to write %s: %s", path, strerror(-err));

	close(fd);

	return err;
}

/*
 * With --dry-run the passthru layer prints the command and returns without
 * touching the device, so no response ever arrives. Emit just the GET_VERSION
 * round trip, which is what makes the SECP/SPSP/NSSF encoding visible, and
 * stop before trying to parse a response that does not exist.
 */
static int spdm_dry_run(struct spdm_ctx *ctx)
{
	unsigned char req[SPDM_HDR_SIZE] = { SPDM_VERSION_1_0, SPDM_GET_VERSION,
					     0x00, 0x00 };
	__cleanup_libnvme_free unsigned char *buf = NULL;
	struct libnvme_passthru_cmd cmd;
	int err;

	err = spdm_send(ctx, req, sizeof(req));
	if (err)
		return err;

	/*
	 * Build the Security Receive by hand rather than calling spdm_recv():
	 * that would try to parse the zeroed buffer a dry run leaves behind.
	 */
	buf = libnvme_alloc(SPDM_MAX_XFER_SIZE);
	if (!buf)
		return -ENOMEM;

	nvme_init_security_receive(&cmd, NVME_NSID_NONE, MICRON_SPDM_NSSF,
				   spdm_spsp(ctx, SPDM_STORAGE_OP_MESSAGE),
				   ctx->secp, SPDM_MAX_XFER_SIZE, buf,
				   SPDM_MAX_XFER_SIZE);

	return libnvme_exec_admin_passthru(ctx->hdl, &cmd);
}

/* Does the controller report Security Send/Receive support at all? */
static int check_security_support(struct libnvme_transport_handle *hdl)
{
	struct nvme_id_ctrl ctrl = { 0 };
	struct libnvme_passthru_cmd cmd;
	int err;

	nvme_init_identify_ctrl(&cmd, &ctrl);
	err = libnvme_exec_admin_passthru(hdl, &cmd);
	if (err) {
		nvme_show_err(err, "Failed to identify controller");
		return err;
	}

	if (!NVME_CTRL_OACS_SSRS(le16_to_cpu(ctrl.oacs))) {
		nvme_show_error("Device does not support Security Send/Receive");
		return -ENOTSUP;
	}

	return 0;
}

int micron_spdm_cert(int argc, char **argv, struct command *cmd,
		     struct plugin *plugin)
{
	const char *desc =
		"Retrieve the SPDM certificate chain from a certificate slot and\n"
		"report whether the device presents a self-signed certificate or a\n"
		"full chain terminating at a self-signed root CA.\n\n"
		"The command runs the SPDM requester handshake in band over NVMe\n"
		"Security Send/Receive: GET_VERSION, GET_CAPABILITIES,\n"
		"NEGOTIATE_ALGORITHMS, GET_DIGESTS and GET_CERTIFICATE. The\n"
		"retrieved chain is hashed with the negotiated algorithm and compared\n"
		"against the GET_DIGESTS value for the slot. No signature is\n"
		"verified.";
	const char *slot = "certificate slot to read (0-7)";
	const char *output_file = "write the raw certificate chain to this file";
	const char *secp = "override the SPDM security protocol (SECP)";
	const char *conn_id = "SPDM storage connection ID (SPSP1)";
	const char *fmt = "Output format: normal|json";

	__cleanup_nvme_transport_handle struct libnvme_transport_handle *hdl = NULL;
	__cleanup_nvme_global_ctx struct libnvme_global_ctx *ctx = NULL;

	struct spdm_chain chain = { 0 };
	unsigned char *digest = NULL;
	bool root_hash_ok = false;
	nvme_print_flags_t format;
	bool digest_ok = false;
	struct spdm_ctx spdm;
	int err;

	struct config {
		__u32	slot;
		char	*output_file;
		__u32	secp;
		__u32	conn_id;
	};

	struct config cfg = {
		.slot = 0,
		.output_file = NULL,
		.secp = MICRON_SPDM_SECP,
		.conn_id = 0,
	};

	NVME_ARGS_OUTPUT_FORMATS(opts, (JSON | NORMAL), fmt,
		OPT_UINT("slot", 's', &cfg.slot, slot),
		OPT_FILE("output-file", 'f', &cfg.output_file, output_file),
		OPT_UINT("secp", 0, &cfg.secp, secp),
		OPT_UINT("conn-id", 0, &cfg.conn_id, conn_id));

	err = parse_and_open(&ctx, &hdl, argc, argv, desc, opts);
	if (err)
		return err;

	err = validate_output_format(nvme_args.output_format, &format);
	if (err) {
		nvme_show_error("Invalid output format");
		return err;
	}

	if (cfg.slot > SPDM_MAX_SLOT) {
		nvme_show_error("Invalid slot %u, must be 0-%u", cfg.slot,
				SPDM_MAX_SLOT);
		return -EINVAL;
	}

	if (cfg.secp > 0xff || cfg.conn_id > 0xff) {
		nvme_show_error("secp and conn-id must each fit in one byte");
		return -EINVAL;
	}

	memset(&spdm, 0, sizeof(spdm));
	spdm.hdl = hdl;
	spdm.secp = (uint8_t)cfg.secp;
	spdm.conn_id = (uint8_t)cfg.conn_id;
	spdm.version = SPDM_VERSION_1_0;
	spdm.xfer_size = SPDM_DEFAULT_XFER_SIZE;

	if (nvme_args.dry_run)
		return spdm_dry_run(&spdm);

	err = check_security_support(hdl);
	if (err)
		return err;

	err = spdm_get_version(&spdm);
	if (err)
		return err;

	err = spdm_get_capabilities(&spdm);
	if (err)
		return err;

	err = spdm_negotiate_algorithms(&spdm);
	if (err)
		return err;

	err = spdm_get_digest(&spdm, (uint8_t)cfg.slot, &digest);
	if (err)
		return err;

	err = spdm_get_certificate(&spdm, (uint8_t)cfg.slot, &chain.raw,
				   &chain.raw_len);
	if (err)
		goto free_digest;

	if (cfg.output_file) {
		err = chain_write_file(cfg.output_file, chain.raw,
				       chain.raw_len);
		if (err)
			goto free_chain;
	}

	err = chain_parse(&chain, spdm.hash_size);
	if (err)
		goto free_chain;

	digest_ok = digest_matches(&spdm, chain.raw, chain.raw_len, digest);
	root_hash_ok = digest_matches(&spdm, chain.certs,
				      chain.cert[0].info.der_len,
				      chain.root_hash);

	if (format == JSON)
		show_chain_json(&spdm, &chain, (uint8_t)cfg.slot, digest_ok,
				root_hash_ok);
	else
		show_chain_normal(&spdm, &chain, (uint8_t)cfg.slot, digest_ok,
				  root_hash_ok);

	/* A digest mismatch means the chain we read is not the one the device
	 * attested to, which is a real failure and not just a report.
	 */
	if (!digest_ok || !root_hash_ok)
		err = -EPROTO;

free_chain:
	chain_free(&chain);
free_digest:
	free(digest);

	return err;
}
