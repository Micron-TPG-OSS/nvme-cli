/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * This file is part of libnvme.
 * Copyright (c) 2026 Micron Technology, Inc.
 *
 * Cross-platform compatibility for sys/random.h functionality used by libnvme.
 *
 * Authors: Broc Going <bgoing@micron.com>
 */
#pragma once

#if HAVE_SYS_RANDOM
#include <sys/random.h>
#else

#ifndef GRND_NONBLOCK
#define GRND_NONBLOCK 0x01
#endif

#if defined(_WIN32)

#define WIN32_LEAN_AND_MEAN	/* keeps windows.h from including winsock.*/
#include <windows.h>
#include <bcrypt.h>

/* Windows-specific UUID generation using BCryptGenRandom */
static inline int getrandom(void *buf, size_t buflen, unsigned int flags)
{
	if (!BCRYPT_SUCCESS(BCryptGenRandom(NULL, buf, buflen,
			    BCRYPT_USE_SYSTEM_PREFERRED_RNG))) {
		errno = EIO;
		return -1;
	}
	return buflen;
}

#else

#include <fcntl.h>

#include "cleanup-linux.h"

/* Linux-specific UUID generation using /dev/urandom */
static inline int getrandom(void *buf, size_t buflen, unsigned int flags)
{
	__cleanup_fd int fd = -1;
	int ret = 0;

	fd = open("/dev/urandom", O_RDONLY);
	if (fd < 0)
		return -1;

	return read(f, buf, buflen);
}

#endif /* _WIN32 */

#endif /* HAVE_SYS_RANDOM */