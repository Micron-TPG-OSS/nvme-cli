// SPDX-License-Identifier: LGPL-2.1-or-later
/*
 * This file is part of nvme-cli.
 * Copyright (c) 2026 Micron Technology, Inc.
 *
 * Authors: Broc Going <bgoing@micron.com>
 *
 * The expected strings here are asserted verbatim on purpose: the OpenSSL and
 * crypt32 backends must render the same certificate identically, and a checked
 * in expectation is the only thing that catches one of them drifting.
 */

#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <shared/x509-util.h>

#include "x509-fixtures.h"

#define ROOT_DN		"CN=Micron Test Root CA,O=Micron Technology\\, Inc.,C=US"
#define DEV_DN		"CN=M7600-T01234567,OU=SSD,O=Micron Technology\\, Inc.,C=US"

static bool check_str(const char *name, const char *got, const char *want)
{
	if (got && !strcmp(got, want)) {
		printf(" - %s [PASS]\n", name);
		return true;
	}

	printf(" - %s: got %s, want %s [FAIL]\n", name,
	       got ? got : "(null)", want);
	return false;
}

static bool check_size(const char *name, size_t got, size_t want)
{
	if (got == want) {
		printf(" - %s [PASS]\n", name);
		return true;
	}

	printf(" - %s: got %zu, want %zu [FAIL]\n", name, got, want);
	return false;
}

static bool check_bool(const char *name, bool got, bool want)
{
	if (got == want) {
		printf(" - %s [PASS]\n", name);
		return true;
	}

	printf(" - %s: got %s, want %s [FAIL]\n", name,
	       got ? "true" : "false", want ? "true" : "false");
	return false;
}

/* The TLV length reader must work without help from a crypto library. */
static bool test_der_len(void)
{
	unsigned char short_form[] = { 0x30, 0x03, 0x02, 0x01, 0x07 };
	unsigned char high_tag[] = { 0x1f, 0x01, 0x00 };
	unsigned char indefinite[] = { 0x30, 0x80, 0x00, 0x00 };
	unsigned char truncated[] = { 0x30, 0x82, 0x03, 0x7b, 0x30 };
	bool pass = true;

	printf("test_der_len:\n");

	pass &= check_size("root", shr_x509_der_len(cert_root_der,
						    sizeof(cert_root_der)),
			   sizeof(cert_root_der));
	pass &= check_size("dev", shr_x509_der_len(cert_dev_der,
						   sizeof(cert_dev_der)),
			   sizeof(cert_dev_der));
	pass &= check_size("short form", shr_x509_der_len(short_form,
							  sizeof(short_form)),
			   sizeof(short_form));

	/* Rejected: not a certificate, unsupported encoding, or overruns @len. */
	pass &= check_size("high tag number rejected",
			   shr_x509_der_len(high_tag, sizeof(high_tag)), 0);
	pass &= check_size("indefinite length rejected",
			   shr_x509_der_len(indefinite, sizeof(indefinite)), 0);
	pass &= check_size("truncated rejected",
			   shr_x509_der_len(truncated, sizeof(truncated)), 0);
	pass &= check_size("empty rejected", shr_x509_der_len(short_form, 0), 0);

	return pass;
}

static bool test_self_signed(void)
{
	struct shr_x509_info info;
	bool pass = true;
	int err;

	printf("test_self_signed:\n");

	err = shr_x509_parse(cert_root_der, sizeof(cert_root_der), &info);
	if (err) {
		printf(" - parse: %s [FAIL]\n", strerror(-err));
		return false;
	}

	pass &= check_bool("self_signed", info.self_signed, true);
	pass &= check_str("subject", info.subject, ROOT_DN);
	pass &= check_str("issuer", info.issuer, ROOT_DN);
	pass &= check_str("subject_cn", info.subject_cn, "Micron Test Root CA");
	pass &= check_str("issuer_cn", info.issuer_cn, "Micron Test Root CA");
	pass &= check_str("serial", info.serial,
			  "5655A17935491F891D0CD82AD8C3F8D90BE5B3FA");
	pass &= check_str("not_before", info.not_before, "2026-08-17T22:46:28Z");
	pass &= check_str("not_after", info.not_after, "2046-08-12T22:46:28Z");
	pass &= check_size("der_len", info.der_len, sizeof(cert_root_der));

	shr_x509_info_free(&info);

	return pass;
}

static bool test_device_cert(void)
{
	struct shr_x509_info info;
	bool pass = true;
	int err;

	printf("test_device_cert:\n");

	err = shr_x509_parse(cert_dev_der, sizeof(cert_dev_der), &info);
	if (err) {
		printf(" - parse: %s [FAIL]\n", strerror(-err));
		return false;
	}

	pass &= check_bool("self_signed", info.self_signed, false);
	pass &= check_str("subject", info.subject, DEV_DN);
	pass &= check_str("issuer", info.issuer, ROOT_DN);
	pass &= check_str("subject_cn", info.subject_cn, "M7600-T01234567");
	pass &= check_str("issuer_cn", info.issuer_cn, "Micron Test Root CA");
	/* The sign-clearing leading zero is not part of the printed serial. */
	pass &= check_str("serial", info.serial, "1122334455");
	pass &= check_str("not_before", info.not_before, "2026-08-17T22:46:37Z");
	pass &= check_str("not_after", info.not_after, "2036-08-14T22:46:37Z");
	pass &= check_size("der_len", info.der_len, sizeof(cert_dev_der));

	shr_x509_info_free(&info);

	return pass;
}

/*
 * A concatenated chain, as SPDM returns it: der_len must advance the caller to
 * each following certificate with no length information other than the DER.
 */
static bool test_chain_walk(void)
{
	unsigned char chain[sizeof(cert_dev_der) + sizeof(cert_root_der)];
	const char *want_cn[] = { "M7600-T01234567", "Micron Test Root CA" };
	bool want_self_signed[] = { false, true };
	size_t off = 0;
	bool pass = true;
	int i;

	printf("test_chain_walk:\n");

	memcpy(chain, cert_dev_der, sizeof(cert_dev_der));
	memcpy(chain + sizeof(cert_dev_der), cert_root_der,
	       sizeof(cert_root_der));

	for (i = 0; i < 2; i++) {
		struct shr_x509_info info;
		char name[32];
		int err;

		err = shr_x509_parse(chain + off, sizeof(chain) - off, &info);
		if (err) {
			printf(" - cert %d parse: %s [FAIL]\n", i,
			       strerror(-err));
			return false;
		}

		snprintf(name, sizeof(name), "cert %d cn", i);
		pass &= check_str(name, info.subject_cn, want_cn[i]);
		snprintf(name, sizeof(name), "cert %d self_signed", i);
		pass &= check_bool(name, info.self_signed, want_self_signed[i]);

		off += info.der_len;
		shr_x509_info_free(&info);
	}

	pass &= check_size("consumed whole chain", off, sizeof(chain));

	return pass;
}

static bool test_malformed(void)
{
	unsigned char garbage[64];
	struct shr_x509_info info;
	bool pass = true;

	printf("test_malformed:\n");

	memset(garbage, 0xa5, sizeof(garbage));

	pass &= check_bool("garbage rejected",
			   shr_x509_parse(garbage, sizeof(garbage), &info) != 0,
			   true);
	/* A valid header over a truncated body must not be accepted. */
	pass &= check_bool("truncated cert rejected",
			   shr_x509_parse(cert_root_der,
					  sizeof(cert_root_der) / 2,
					  &info) != 0, true);
	pass &= check_bool("NULL der rejected",
			   shr_x509_parse(NULL, 0, &info) != 0, true);

	return pass;
}

int main(void)
{
	struct shr_x509_info info;
	bool pass = true;
	int err;

	err = shr_x509_parse(cert_root_der, sizeof(cert_root_der), &info);
	if (err == -ENOTSUP) {
		printf("X.509 backend unavailable, skipping\n");
		exit(77);
	}
	if (!err)
		shr_x509_info_free(&info);

	pass &= test_der_len();
	pass &= test_self_signed();
	pass &= test_device_cert();
	pass &= test_chain_walk();
	pass &= test_malformed();

	fflush(stdout);
	exit(pass ? EXIT_SUCCESS : EXIT_FAILURE);
}
