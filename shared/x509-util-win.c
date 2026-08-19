// SPDX-License-Identifier: LGPL-2.1-or-later
/*
 * This file is part of nvme-cli.
 * Copyright (c) 2026 Micron Technology, Inc.
 *
 * Authors: Broc Going <bgoing@micron.com>
 *
 * Windows crypt32 X.509 backend. crypt32 decodes and validates the
 * certificate; the name, serial and time strings are formatted by the shared
 * helpers in x509-util.c so that this backend and the OpenSSL one in
 * x509-util-linux.c emit byte-identical output.
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <windows.h>
#include <wincrypt.h>

#include "x509-util.h"

/*
 * FILETIME as "YYYY-MM-DDThh:mm:ssZ". The buffer is sized for the full range of
 * the WORD fields rather than the nominal 20 characters, so a bogus SYSTEMTIME
 * is reported verbatim instead of being silently truncated.
 */
static char *time_to_str(const FILETIME *ft)
{
	SYSTEMTIME st;
	char *out;

	if (!FileTimeToSystemTime(ft, &st))
		return NULL;

	out = malloc(SHR_X509_TIME_SIZE);
	if (!out)
		return NULL;

	snprintf(out, SHR_X509_TIME_SIZE,
		 "%04u-%02u-%02uT%02u:%02u:%02uZ",
		 st.wYear, st.wMonth, st.wDay,
		 st.wHour, st.wMinute, st.wSecond);

	return out;
}

/*
 * crypt32 exposes the serial number little-endian, opposite to the DER
 * INTEGER contents the shared formatter expects. Reverse it before formatting.
 */
static char *serial_to_str(const CRYPT_INTEGER_BLOB *blob)
{
	unsigned char *be;
	char *out;
	DWORD i;

	if (!blob->cbData)
		return strdup("00");

	be = malloc(blob->cbData);
	if (!be)
		return NULL;

	for (i = 0; i < blob->cbData; i++)
		be[i] = blob->pbData[blob->cbData - 1 - i];

	out = shr_x509_serial_to_str(be, blob->cbData);
	free(be);

	return out;
}

int shr_x509_parse(const unsigned char *der, size_t len,
		   struct shr_x509_info *out)
{
	PCCERT_CONTEXT cert;
	size_t cert_len;
	int err = 0;

	if (!der || !out)
		return -EINVAL;

	memset(out, 0, sizeof(*out));

	/*
	 * Bound the parse to the first certificate so a concatenated chain does
	 * not feed trailing certificates to crypt32.
	 */
	cert_len = shr_x509_der_len(der, len);
	if (!cert_len)
		return -EILSEQ;

	/* CertCreateCertificateContext() takes a DWORD length. */
	if (cert_len > (size_t)MAXDWORD)
		return -EILSEQ;

	cert = CertCreateCertificateContext(X509_ASN_ENCODING, der,
					    (DWORD)cert_len);
	if (!cert)
		return -EILSEQ;

	out->der_len = cert_len;

	/*
	 * CertCompareCertificateName() compares the encoded names, which is the
	 * self-signed test: issuer DN equal to subject DN.
	 */
	out->self_signed = CertCompareCertificateName(X509_ASN_ENCODING,
			&cert->pCertInfo->Issuer,
			&cert->pCertInfo->Subject) != FALSE;

	out->issuer = shr_x509_name_to_str(cert->pCertInfo->Issuer.pbData,
					   cert->pCertInfo->Issuer.cbData);
	out->subject = shr_x509_name_to_str(cert->pCertInfo->Subject.pbData,
					    cert->pCertInfo->Subject.cbData);
	if (!out->issuer || !out->subject) {
		err = -ENOMEM;
		goto out;
	}

	/* The remaining fields are optional; a missing one is not an error. */
	out->issuer_cn = shr_x509_name_get_cn(cert->pCertInfo->Issuer.pbData,
					      cert->pCertInfo->Issuer.cbData);
	out->subject_cn = shr_x509_name_get_cn(cert->pCertInfo->Subject.pbData,
					       cert->pCertInfo->Subject.cbData);
	out->serial = serial_to_str(&cert->pCertInfo->SerialNumber);
	out->not_before = time_to_str(&cert->pCertInfo->NotBefore);
	out->not_after = time_to_str(&cert->pCertInfo->NotAfter);

out:
	CertFreeCertificateContext(cert);
	if (err)
		shr_x509_info_free(out);

	return err;
}
