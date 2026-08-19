/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * This file is part of nvme-cli.
 * Copyright (c) 2026 Micron Technology, Inc.
 *
 * Authors: Broc Going <bgoing@micron.com>
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>

/*
 * Buffer size for the "YYYY-MM-DDThh:mm:ssZ" validity strings. Sized for the
 * full range of the underlying fields, not the nominal 20 characters, so an
 * out-of-range date is reported verbatim rather than truncated.
 */
#define SHR_X509_TIME_SIZE	40

/*
 * Identifying fields extracted from a single DER-encoded X.509 certificate.
 * All strings are heap allocated and released by shr_x509_info_free(); any of
 * them may be NULL if the certificate omits the field.
 */
struct shr_x509_info {
	char	*issuer;	/* issuer DN, one line, RFC2253 order */
	char	*subject;	/* subject DN, one line, RFC2253 order */
	char	*issuer_cn;	/* issuer CN attribute alone */
	char	*subject_cn;	/* subject CN attribute alone, e.g. "M7600-T0123" */
	char	*serial;	/* serial number, uppercase hex, no separators */
	char	*not_before;	/* validity start, "YYYY-MM-DDThh:mm:ssZ" */
	char	*not_after;	/* validity end, same format */
	bool	self_signed;	/* issuer DN equals subject DN */
	size_t	der_len;	/* bytes of @der this certificate occupies */
};

/*
 * Length of the DER TLV starting at @buf, i.e. the size of the first
 * certificate in a concatenated chain. Only the outer SEQUENCE header is
 * examined, so this works without a crypto library and lets a caller split a
 * chain before parsing it.
 * Return: total TLV length (header + contents), or 0 if @buf does not start a
 * well-formed definite-length SEQUENCE that fits within @len.
 */
size_t shr_x509_der_len(const unsigned char *buf, size_t len);

/*
 * Render the DER-encoded X.509 Name at @der as a single line, most specific
 * RDN first, escaped per RFC2253.
 *
 * Both backends format names through this function rather than through their
 * platform library, because OpenSSL and crypt32 disagree on how to represent a
 * value containing a comma -- exactly the case for "Micron Technology, Inc.".
 * Return: allocated string the caller must free(), or NULL on a malformed Name
 * or allocation failure.
 */
char *shr_x509_name_to_str(const unsigned char *der, size_t len);

/*
 * Extract the CN attribute of the DER-encoded X.509 Name at @der, unescaped.
 * Return: allocated string the caller must free(), or NULL if the Name has no
 * CN or is malformed.
 */
char *shr_x509_name_get_cn(const unsigned char *der, size_t len);

/*
 * Format the contents of a DER INTEGER serial number as uppercase hex, without
 * the sign-clearing leading zero.
 * Return: allocated string the caller must free(), or NULL on failure.
 */
char *shr_x509_serial_to_str(const unsigned char *serial, size_t len);

/*
 * Parse the DER-encoded certificate at @der and fill in @out. @len may cover
 * more than one certificate; only the first is parsed and out->der_len reports
 * how many bytes it used.
 *
 * On success @out owns heap allocations that shr_x509_info_free() releases. On
 * failure @out is left zeroed and needs no cleanup.
 * Return: 0 on success, -errno otherwise. -ENOTSUP if nvme-cli was built
 * without the platform X.509 backend.
 */
int shr_x509_parse(const unsigned char *der, size_t len,
		   struct shr_x509_info *out);

/* Release the strings owned by @info and zero it. Safe on a zeroed struct. */
void shr_x509_info_free(struct shr_x509_info *info);
