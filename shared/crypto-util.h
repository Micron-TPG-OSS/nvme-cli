/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * This file is part of nvme-cli.
 */
#pragma once

#include <stddef.h>

/* Digest output sizes, in bytes. */
#define SHR_SHA256_SIZE		32
#define SHR_SHA384_SIZE		48
#define SHR_SHA512_SIZE		64

/*
 * Compute HMAC-SHA256 over data using key. Returns a newly allocated 32-byte
 * buffer the caller must free(), or NULL on failure.
 */
unsigned char *shr_hmac_sha256(unsigned char *data, int datalen,
		unsigned char *key, int keylen);

/*
 * Compute MD5 over data. Returns a newly allocated 16-byte buffer the caller
 * must free(), or NULL on failure.
 */
unsigned char *shr_md5(unsigned char *data, int datalen);

/*
 * Compute SHA2-256/384/512 over data. Each returns a newly allocated
 * 32/48/64-byte buffer the caller must free(), or NULL on failure.
 */
unsigned char *shr_sha256(const unsigned char *data, size_t datalen);
unsigned char *shr_sha384(const unsigned char *data, size_t datalen);
unsigned char *shr_sha512(const unsigned char *data, size_t datalen);
