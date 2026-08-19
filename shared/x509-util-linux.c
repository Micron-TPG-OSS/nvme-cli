// SPDX-License-Identifier: LGPL-2.1-or-later
/*
 * This file is part of nvme-cli.
 * Copyright (c) 2026 Micron Technology, Inc.
 *
 * Authors: Broc Going <bgoing@micron.com>
 *
 * OpenSSL X.509 backend. OpenSSL decodes and validates the certificate; the
 * name, serial and time strings are formatted by the shared helpers in
 * x509-util.c so that this backend and the crypt32 one in x509-util-win.c emit
 * byte-identical output.
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "x509-util.h"

#ifdef CONFIG_OPENSSL
#include <openssl/asn1.h>
#include <openssl/x509.h>

/* Re-encode @name to DER for the shared formatter. */
static int name_der(const X509_NAME *name, unsigned char **der, size_t *len)
{
	unsigned char *buf = NULL;
	int ret;

	ret = i2d_X509_NAME((X509_NAME *)name, &buf);
	if (ret <= 0)
		return -EILSEQ;

	*der = buf;
	*len = (size_t)ret;

	return 0;
}

/* ASN1_TIME as "YYYY-MM-DDThh:mm:ssZ". */
static char *time_to_str(const ASN1_TIME *time)
{
	struct tm tm = { 0 };
	char *out;

	if (!time || !ASN1_TIME_to_tm(time, &tm))
		return NULL;

	out = malloc(SHR_X509_TIME_SIZE);
	if (!out)
		return NULL;

	snprintf(out, SHR_X509_TIME_SIZE,
		 "%04d-%02d-%02dT%02d:%02d:%02dZ",
		 tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
		 tm.tm_hour, tm.tm_min, tm.tm_sec);

	return out;
}

static char *serial_to_str(const ASN1_INTEGER *serial)
{
	if (!serial)
		return NULL;

	return shr_x509_serial_to_str(serial->data, (size_t)serial->length);
}

int shr_x509_parse(const unsigned char *der, size_t len,
		   struct shr_x509_info *out)
{
	unsigned char *issuer_der = NULL;
	unsigned char *subject_der = NULL;
	size_t issuer_len, subject_len;
	const unsigned char *p = der;
	X509_NAME *issuer;
	X509_NAME *subject;
	size_t cert_len;
	X509 *cert;
	int err = 0;

	if (!der || !out)
		return -EINVAL;

	memset(out, 0, sizeof(*out));

	/*
	 * Bound the parse to the first certificate so a concatenated chain does
	 * not feed trailing certificates to d2i_X509().
	 */
	cert_len = shr_x509_der_len(der, len);
	if (!cert_len)
		return -EILSEQ;

	cert = d2i_X509(NULL, &p, (long)cert_len);
	if (!cert)
		return -EILSEQ;

	out->der_len = cert_len;

	issuer = X509_get_issuer_name(cert);
	subject = X509_get_subject_name(cert);
	if (!issuer || !subject) {
		err = -EILSEQ;
		goto out;
	}

	out->self_signed = X509_NAME_cmp(issuer, subject) == 0;

	err = name_der(issuer, &issuer_der, &issuer_len);
	if (err)
		goto out;
	err = name_der(subject, &subject_der, &subject_len);
	if (err)
		goto out;

	out->issuer = shr_x509_name_to_str(issuer_der, issuer_len);
	out->subject = shr_x509_name_to_str(subject_der, subject_len);
	if (!out->issuer || !out->subject) {
		err = -ENOMEM;
		goto out;
	}

	/* The remaining fields are optional; a missing one is not an error. */
	out->issuer_cn = shr_x509_name_get_cn(issuer_der, issuer_len);
	out->subject_cn = shr_x509_name_get_cn(subject_der, subject_len);
	out->serial = serial_to_str(X509_get0_serialNumber(cert));
	out->not_before = time_to_str(X509_get0_notBefore(cert));
	out->not_after = time_to_str(X509_get0_notAfter(cert));

out:
	OPENSSL_free(issuer_der);
	OPENSSL_free(subject_der);
	X509_free(cert);
	if (err)
		shr_x509_info_free(out);

	return err;
}
#else /* CONFIG_OPENSSL */
int shr_x509_parse(const unsigned char *der, size_t len,
		   struct shr_x509_info *out)
{
	fprintf(stderr, "%s: nvme-cli was built without OpenSSL support\n", __func__);
	return -ENOTSUP;
}
#endif /* CONFIG_OPENSSL */
