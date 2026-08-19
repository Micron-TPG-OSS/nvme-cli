// SPDX-License-Identifier: LGPL-2.1-or-later
/*
 * This file is part of nvme-cli.
 * Copyright (c) 2026 SUSE Software Solutions
 *
 * Authors: Daniel Wagner <dwagner@suse.de>
 */

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <shared/crypto-util.h>

static bool check_hex(const char *name, const unsigned char *got, size_t got_len,
		       const char *want_hex)
{
	char buf[2 * SHR_SHA512_SIZE + 1] = { 0 };
	size_t i;

	if (!got) {
		printf(" - %s: got NULL [FAIL]\n", name);
		return false;
	}

	for (i = 0; i < got_len; i++)
		snprintf(buf + i * 2, 3, "%02x", got[i]);

	if (!strcmp(buf, want_hex)) {
		printf(" - %s [PASS]\n", name);
		return true;
	}

	printf(" - %s: got %s, want %s [FAIL]\n", name, buf, want_hex);
	return false;
}

static bool test_md5(void)
{
	unsigned char *hash;
	bool pass = true;

	printf("test_md5:\n");

	hash = shr_md5((unsigned char *)"abc", 3);
	pass &= check_hex("md5(\"abc\")", hash, 16, "900150983cd24fb0d6963f7d28e17f72");
	free(hash);

	hash = shr_md5((unsigned char *)"", 0);
	pass &= check_hex("md5(\"\")", hash, 16, "d41d8cd98f00b204e9800998ecf8427e");
	free(hash);

	return pass;
}

static bool test_hmac_sha256(void)
{
	static const char *msg = "The quick brown fox jumps over the lazy dog";
	unsigned char *hash;
	bool pass = true;

	printf("test_hmac_sha256:\n");

	hash = shr_hmac_sha256((unsigned char *)msg, strlen(msg),
				(unsigned char *)"key", 3);
	pass &= check_hex("hmac_sha256(msg, \"key\")", hash, 32,
			   "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8");
	free(hash);

	return pass;
}

/*
 * NIST FIPS 180-4 known-answer vectors for the one-block message "abc" and the
 * empty message.
 */
static bool test_sha2(void)
{
	unsigned char *hash;
	bool pass = true;

	printf("test_sha2:\n");

	hash = shr_sha256((const unsigned char *)"abc", 3);
	pass &= check_hex("sha256(\"abc\")", hash, SHR_SHA256_SIZE,
			  "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
	free(hash);

	hash = shr_sha256((const unsigned char *)"", 0);
	pass &= check_hex("sha256(\"\")", hash, SHR_SHA256_SIZE,
			  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
	free(hash);

	hash = shr_sha384((const unsigned char *)"abc", 3);
	pass &= check_hex("sha384(\"abc\")", hash, SHR_SHA384_SIZE,
			  "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7");
	free(hash);

	hash = shr_sha384((const unsigned char *)"", 0);
	pass &= check_hex("sha384(\"\")", hash, SHR_SHA384_SIZE,
			  "38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b");
	free(hash);

	hash = shr_sha512((const unsigned char *)"abc", 3);
	pass &= check_hex("sha512(\"abc\")", hash, SHR_SHA512_SIZE,
			  "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f");
	free(hash);

	hash = shr_sha512((const unsigned char *)"", 0);
	pass &= check_hex("sha512(\"\")", hash, SHR_SHA512_SIZE,
			  "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e");
	free(hash);

	return pass;
}

int main(void)
{
	bool pass = true;

	unsigned char *probe = shr_md5((unsigned char *)"x", 1);

	if (!probe) {
		printf("OpenSSL support unavailable, skipping\n");
		exit(77);
	}
	free(probe);

	pass &= test_md5();
	pass &= test_hmac_sha256();
	pass &= test_sha2();

	fflush(stdout);
	exit(pass ? EXIT_SUCCESS : EXIT_FAILURE);
}
