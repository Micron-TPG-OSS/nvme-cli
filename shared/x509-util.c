// SPDX-License-Identifier: LGPL-2.1-or-later
/*
 * This file is part of nvme-cli.
 * Copyright (c) 2026 Micron Technology, Inc.
 *
 * Authors: Broc Going <bgoing@micron.com>
 *
 * Platform-independent helpers shared by both X.509 backends.
 *
 * Distinguished names are rendered here rather than by OpenSSL or crypt32 so
 * that both backends emit byte-identical strings. The two libraries disagree on
 * DN syntax in a way that matters for the values this code exists to show: for
 * an organization of "Micron Technology, Inc." OpenSSL's RFC2253 output escapes
 * the embedded comma (O=Micron Technology\, Inc.) while CertNameToStr() quotes
 * the whole value (O="Micron Technology, Inc."). Formatting from the raw Name
 * DER, which both libraries hand back unaltered, keeps the output identical.
 */
#include <errno.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "x509-util.h"

/* ASN.1 identifier octets. */
#define DER_TAG_SEQUENCE		0x30
#define DER_TAG_SET			0x31
#define DER_TAG_OID			0x06

/* String types whose contents can be emitted as-is. */
#define DER_TAG_UTF8_STRING		0x0c
#define DER_TAG_NUMERIC_STRING		0x12
#define DER_TAG_PRINTABLE_STRING	0x13
#define DER_TAG_T61_STRING		0x14
#define DER_TAG_IA5_STRING		0x16
#define DER_TAG_VISIBLE_STRING		0x1a
#define DER_TAG_BMP_STRING		0x1e

/* Bit 8 of a length octet marks the long form; the low bits hold the count. */
#define DER_LEN_LONG_FORM		0x80
#define DER_LEN_COUNT_MASK		0x7f

/* A parsed tag-length-value triple. */
struct der_tlv {
	unsigned char		tag;
	const unsigned char	*hdr;	/* start of the TLV, at the tag octet */
	const unsigned char	*val;	/* contents, excluding the header */
	size_t			len;	/* length of the contents */
	size_t			total;	/* header + contents */
};

/*
 * Decode the TLV at the front of @buf. Only definite-length encodings are
 * accepted, as required by DER.
 * Return: 0 on success, -EILSEQ on a malformed or truncated encoding.
 */
static int der_tlv(const unsigned char *buf, size_t len, struct der_tlv *out)
{
	size_t contents_len;
	size_t header_len;
	unsigned int count;
	unsigned int i;

	if (len < 2)
		return -EILSEQ;

	/*
	 * High-tag-number form (low five bits all set) spans several identifier
	 * octets. Nothing in an X.509 Name uses it.
	 */
	if ((buf[0] & 0x1f) == 0x1f)
		return -EILSEQ;

	if (!(buf[1] & DER_LEN_LONG_FORM)) {
		contents_len = buf[1];
		header_len = 2;
	} else {
		count = buf[1] & DER_LEN_COUNT_MASK;

		/* count == 0 is the indefinite form, which DER forbids. */
		if (count == 0 || count > sizeof(size_t))
			return -EILSEQ;
		if (len < 2 + (size_t)count)
			return -EILSEQ;

		contents_len = 0;
		for (i = 0; i < count; i++)
			contents_len = (contents_len << 8) | buf[2 + i];

		header_len = 2 + count;
	}

	if (contents_len > len - header_len)
		return -EILSEQ;

	out->tag = buf[0];
	out->hdr = buf;
	out->val = buf + header_len;
	out->len = contents_len;
	out->total = header_len + contents_len;

	return 0;
}

size_t shr_x509_der_len(const unsigned char *buf, size_t len)
{
	struct der_tlv tlv;

	if (!buf || der_tlv(buf, len, &tlv) || tlv.tag != DER_TAG_SEQUENCE)
		return 0;

	return tlv.total;
}

/*
 * Attribute types that get a short name. RFC2253 only defines CN, L, ST, O,
 * OU, C, STREET, DC and UID; the rest are included because certificates use
 * them and a dotted OID would be less readable. Anything absent here is
 * rendered as a dotted OID, as RFC2253 requires.
 */
static const struct {
	const char	*name;
	size_t		len;
	unsigned char	oid[10];
} attr_types[] = {
	{ "CN",		3, { 0x55, 0x04, 0x03 } },
	{ "SN",		3, { 0x55, 0x04, 0x04 } },
	{ "serialNumber", 3, { 0x55, 0x04, 0x05 } },
	{ "C",		3, { 0x55, 0x04, 0x06 } },
	{ "L",		3, { 0x55, 0x04, 0x07 } },
	{ "ST",		3, { 0x55, 0x04, 0x08 } },
	{ "STREET",	3, { 0x55, 0x04, 0x09 } },
	{ "O",		3, { 0x55, 0x04, 0x0a } },
	{ "OU",		3, { 0x55, 0x04, 0x0b } },
	{ "title",	3, { 0x55, 0x04, 0x0c } },
	{ "GN",		3, { 0x55, 0x04, 0x2a } },
	{ "emailAddress", 9, { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01,
			       0x09, 0x01 } },
	{ "DC",		10, { 0x09, 0x92, 0x26, 0x89, 0x93, 0xf2, 0x2c, 0x64,
			      0x01, 0x19 } },
	{ "UID",	10, { 0x09, 0x92, 0x26, 0x89, 0x93, 0xf2, 0x2c, 0x64,
			      0x01, 0x01 } },
};

/*
 * A growable output string. All appends are no-ops once an allocation has
 * failed, so callers only need to check @failed once at the end.
 */
struct strbuf {
	char	*buf;
	size_t	len;
	size_t	cap;
	bool	failed;
};

static void sb_append(struct strbuf *sb, const char *data, size_t len)
{
	if (sb->failed)
		return;

	if (sb->len + len + 1 > sb->cap) {
		size_t cap = sb->cap ? sb->cap * 2 : 128;
		char *buf;

		while (cap < sb->len + len + 1)
			cap *= 2;

		buf = realloc(sb->buf, cap);
		if (!buf) {
			sb->failed = true;
			return;
		}
		sb->buf = buf;
		sb->cap = cap;
	}

	memcpy(sb->buf + sb->len, data, len);
	sb->len += len;
	sb->buf[sb->len] = '\0';
}

static void sb_putc(struct strbuf *sb, char c)
{
	sb_append(sb, &c, 1);
}

static void sb_printf(struct strbuf *sb, const char *fmt, ...)
{
	char tmp[64];
	va_list ap;
	int len;

	va_start(ap, fmt);
	len = vsnprintf(tmp, sizeof(tmp), fmt, ap);
	va_end(ap);

	if (len > 0)
		sb_append(sb, tmp, (size_t)len);
}

/* Release the buffer and return NULL, for the allocation-failure paths. */
static char *sb_abort(struct strbuf *sb)
{
	free(sb->buf);
	return NULL;
}

/* Append @oid in dotted-decimal form. */
static void append_oid(struct strbuf *sb, const unsigned char *oid, size_t len)
{
	uint64_t v = 0;
	size_t i;

	if (!len) {
		sb_append(sb, "OID", 3);
		return;
	}

	/* The first octet packs the first two arcs as 40 * arc1 + arc2. */
	sb_printf(sb, "%u.%u", oid[0] / 40, oid[0] % 40);

	for (i = 1; i < len; i++) {
		/* Guard against a varint wide enough to overflow. */
		if (v > (UINT64_MAX >> 7)) {
			v = 0;
			continue;
		}

		v = (v << 7) | (oid[i] & 0x7f);
		if (!(oid[i] & 0x80)) {
			sb_printf(sb, ".%" PRIu64, v);
			v = 0;
		}
	}
}

/*
 * Append @val escaped per RFC2253 section 2.4: a leading '#' or space, a
 * trailing space, and any of ,+"\<>; are backslash-escaped, and control
 * characters use the \HH hex form.
 */
static void append_escaped(struct strbuf *sb, const unsigned char *val,
			   size_t len)
{
	size_t i;

	for (i = 0; i < len; i++) {
		unsigned char c = val[i];
		bool first = i == 0;
		bool last = i == len - 1;

		if ((first && (c == '#' || c == ' ')) || (last && c == ' ')) {
			sb_putc(sb, '\\');
			sb_putc(sb, (char)c);
		} else if (strchr(",+\"\\<>;", c) && c != '\0') {
			sb_putc(sb, '\\');
			sb_putc(sb, (char)c);
		} else if (c < 0x20 || c == 0x7f) {
			sb_printf(sb, "\\%02X", c);
		} else {
			sb_putc(sb, (char)c);
		}
	}
}

/* Append a BMPString (UCS-2 big endian) as UTF-8. */
static void append_bmp_string(struct strbuf *sb, const unsigned char *val,
			      size_t len)
{
	unsigned char utf8[3];
	size_t i;

	/* An odd length is not a valid BMPString. */
	if (len & 1) {
		sb_printf(sb, "#");
		for (i = 0; i < len; i++)
			sb_printf(sb, "%02X", val[i]);
		return;
	}

	for (i = 0; i + 1 < len; i += 2) {
		unsigned int cp = ((unsigned int)val[i] << 8) | val[i + 1];

		if (cp < 0x80) {
			utf8[0] = (unsigned char)cp;
			append_escaped(sb, utf8, 1);
		} else if (cp < 0x800) {
			utf8[0] = (unsigned char)(0xc0 | (cp >> 6));
			utf8[1] = (unsigned char)(0x80 | (cp & 0x3f));
			append_escaped(sb, utf8, 2);
		} else {
			utf8[0] = (unsigned char)(0xe0 | (cp >> 12));
			utf8[1] = (unsigned char)(0x80 | ((cp >> 6) & 0x3f));
			utf8[2] = (unsigned char)(0x80 | (cp & 0x3f));
			append_escaped(sb, utf8, 3);
		}
	}
}

/* True if @tag holds text this code emits directly rather than as hex. */
static bool is_text_tag(unsigned char tag)
{
	switch (tag) {
	case DER_TAG_UTF8_STRING:
	case DER_TAG_NUMERIC_STRING:
	case DER_TAG_PRINTABLE_STRING:
	case DER_TAG_T61_STRING:
	case DER_TAG_IA5_STRING:
	case DER_TAG_VISIBLE_STRING:
		return true;
	default:
		return false;
	}
}

/* Append an AttributeValue, choosing a representation based on its tag. */
static void append_attr_value(struct strbuf *sb, const struct der_tlv *value)
{
	size_t i;

	if (is_text_tag(value->tag)) {
		append_escaped(sb, value->val, value->len);
		return;
	}

	if (value->tag == DER_TAG_BMP_STRING) {
		append_bmp_string(sb, value->val, value->len);
		return;
	}

	/*
	 * RFC2253 renders anything that is not a recognized string type as the
	 * hex of the whole TLV, prefixed with '#'.
	 */
	sb_putc(sb, '#');
	for (i = 0; i < value->total; i++)
		sb_printf(sb, "%02X", value->hdr[i]);
}

/* Append one AttributeTypeAndValue as "type=value". */
static int append_atv(struct strbuf *sb, const unsigned char *buf, size_t len)
{
	struct der_tlv value;
	struct der_tlv type;
	struct der_tlv atv;
	size_t i;

	if (der_tlv(buf, len, &atv) || atv.tag != DER_TAG_SEQUENCE)
		return -EILSEQ;
	if (der_tlv(atv.val, atv.len, &type) || type.tag != DER_TAG_OID)
		return -EILSEQ;
	if (der_tlv(atv.val + type.total, atv.len - type.total, &value))
		return -EILSEQ;

	for (i = 0; i < sizeof(attr_types) / sizeof(attr_types[0]); i++) {
		if (type.len == attr_types[i].len &&
		    !memcmp(type.val, attr_types[i].oid, type.len)) {
			sb_append(sb, attr_types[i].name,
				  strlen(attr_types[i].name));
			break;
		}
	}

	if (i == sizeof(attr_types) / sizeof(attr_types[0]))
		append_oid(sb, type.val, type.len);

	sb_putc(sb, '=');
	append_attr_value(sb, &value);

	return 0;
}

/*
 * Collect the offsets of each RelativeDistinguishedName in @der so they can be
 * emitted in reverse. Returns the count, or -EILSEQ on a malformed Name.
 */
static int rdn_offsets(const unsigned char *der, size_t len,
		       const unsigned char **offs, size_t *lens, int max)
{
	struct der_tlv name;
	size_t pos = 0;
	int count = 0;

	if (der_tlv(der, len, &name) || name.tag != DER_TAG_SEQUENCE)
		return -EILSEQ;

	while (pos < name.len) {
		struct der_tlv rdn;

		if (der_tlv(name.val + pos, name.len - pos, &rdn) ||
		    rdn.tag != DER_TAG_SET)
			return -EILSEQ;

		if (count == max)
			return -E2BIG;

		offs[count] = rdn.val;
		lens[count] = rdn.len;
		count++;
		pos += rdn.total;
	}

	return count;
}

/* An X.509 Name with more RDNs than this is rejected rather than truncated. */
#define MAX_RDNS	64

char *shr_x509_name_to_str(const unsigned char *der, size_t len)
{
	const unsigned char *offs[MAX_RDNS];
	struct strbuf sb = { 0 };
	size_t lens[MAX_RDNS];
	int count;
	int i;

	if (!der)
		return NULL;

	count = rdn_offsets(der, len, offs, lens, MAX_RDNS);
	if (count < 0)
		return NULL;

	/* RFC2253 lists the most specific RDN first, reversing DER order. */
	for (i = count - 1; i >= 0; i--) {
		size_t pos = 0;
		bool first = true;

		if (i != count - 1)
			sb_putc(&sb, ',');

		/* A multi-valued RDN joins its attributes with '+'. */
		while (pos < lens[i]) {
			struct der_tlv atv;

			if (der_tlv(offs[i] + pos, lens[i] - pos, &atv))
				return sb_abort(&sb);

			if (!first)
				sb_putc(&sb, '+');
			first = false;

			if (append_atv(&sb, offs[i] + pos, lens[i] - pos))
				return sb_abort(&sb);

			pos += atv.total;
		}
	}

	if (sb.failed)
		return sb_abort(&sb);

	/* An empty Name is legal and renders as an empty string. */
	if (!sb.buf)
		return calloc(1, 1);

	return sb.buf;
}

char *shr_x509_name_get_cn(const unsigned char *der, size_t len)
{
	static const unsigned char oid_cn[] = { 0x55, 0x04, 0x03 };
	const unsigned char *offs[MAX_RDNS];
	size_t lens[MAX_RDNS];
	int count;
	int i;

	if (!der)
		return NULL;

	count = rdn_offsets(der, len, offs, lens, MAX_RDNS);
	if (count < 0)
		return NULL;

	/*
	 * Search in RFC2253 display order so a certificate with more than one
	 * CN yields the most specific, matching the leading CN of the rendered
	 * DN.
	 */
	for (i = count - 1; i >= 0; i--) {
		size_t pos = 0;

		while (pos < lens[i]) {
			struct der_tlv value;
			struct der_tlv type;
			struct der_tlv atv;

			if (der_tlv(offs[i] + pos, lens[i] - pos, &atv) ||
			    atv.tag != DER_TAG_SEQUENCE)
				return NULL;
			if (der_tlv(atv.val, atv.len, &type) ||
			    type.tag != DER_TAG_OID)
				return NULL;
			if (der_tlv(atv.val + type.total,
				    atv.len - type.total, &value))
				return NULL;

			if (type.len == sizeof(oid_cn) &&
			    !memcmp(type.val, oid_cn, sizeof(oid_cn))) {
				struct strbuf sb = { 0 };

				/*
				 * Return the CN unescaped: it is shown on its
				 * own and matched against the expected device
				 * name pattern, not spliced into a DN.
				 */
				if (is_text_tag(value.tag))
					sb_append(&sb, (const char *)value.val,
						  value.len);
				else if (value.tag == DER_TAG_BMP_STRING)
					append_bmp_string(&sb, value.val,
							  value.len);
				else
					return NULL;

				if (sb.failed)
					return sb_abort(&sb);

				return sb.buf ? sb.buf : calloc(1, 1);
			}

			pos += atv.total;
		}
	}

	return NULL;
}

char *shr_x509_serial_to_str(const unsigned char *serial, size_t len)
{
	struct strbuf sb = { 0 };
	size_t i;

	if (!serial)
		return NULL;

	/* Drop the leading zero a positive INTEGER carries to clear the sign. */
	if (len > 1 && serial[0] == 0x00) {
		serial++;
		len--;
	}

	if (!len)
		return strdup("00");

	for (i = 0; i < len; i++)
		sb_printf(&sb, "%02X", serial[i]);

	if (sb.failed)
		return sb_abort(&sb);

	return sb.buf;
}

void shr_x509_info_free(struct shr_x509_info *info)
{
	if (!info)
		return;

	free(info->issuer);
	free(info->subject);
	free(info->issuer_cn);
	free(info->subject_cn);
	free(info->serial);
	free(info->not_before);
	free(info->not_after);

	memset(info, 0, sizeof(*info));
}
