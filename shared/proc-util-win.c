// SPDX-License-Identifier: LGPL-2.1-or-later
/*
 * This file is part of nvme-cli.
 * Copyright (c) 2026 Micron Technology, Inc.
 *
 * Authors: Broc Going <bgoing@micron.com>
 */
#include <errno.h>
#include <fcntl.h>
#include <io.h>
#include <process.h>
#include <stdio.h>

#include "proc-util.h"

int shr_pipe(int fds[2])
{
	return _pipe(fds, 1 << 16, _O_BINARY) ? -errno : 0;
}

int shr_spawn_sync(const char *const argv[], int out_fd, int err_fd,
		   bool *exited, int *code)
{
	int saved_out = -1, saved_err = -1;
	intptr_t rc = -1;
	int err = 0;

	/*
	 * Windows has no fork(): _spawnv() runs a fresh process that inherits
	 * this process's stdout/stderr. Redirect ours onto the caller's fds for
	 * the duration of the spawn, then restore them.
	 *
	 * Flush first: stdout/stderr are buffered stdio streams, and _dup2()
	 * swaps the underlying fd without touching the buffer, so any pending
	 * parent output would otherwise drain into the child's capture pipe.
	 */
	if (out_fd >= 0) {
		fflush(stdout);
		saved_out = _dup(_fileno(stdout));
		if (saved_out < 0 || _dup2(out_fd, _fileno(stdout)) < 0) {
			err = errno;
			goto restore;
		}
	}
	if (err_fd >= 0) {
		fflush(stderr);
		saved_err = _dup(_fileno(stderr));
		if (saved_err < 0 || _dup2(err_fd, _fileno(stderr)) < 0) {
			err = errno;
			goto restore;
		}
	}

	rc = _spawnv(_P_WAIT, argv[0], argv);
	if (rc == -1)
		err = errno;

restore:
	/* Flush the child-directed streams before restoring the parent fds. */
	fflush(stdout);
	fflush(stderr);
	if (saved_out >= 0) {
		_dup2(saved_out, _fileno(stdout));
		_close(saved_out);
	}
	if (saved_err >= 0) {
		_dup2(saved_err, _fileno(stderr));
		_close(saved_err);
	}

	if (rc == -1)
		return err ? -err : -EIO;

	/*
	 * _spawnv(_P_WAIT) returns the child's exit code directly. Windows has
	 * no signals, but a crash (e.g. abort()) surfaces as a 0xCxxxxxxx
	 * status, negative once narrowed to int -- treat that as "not exited".
	 */
	*exited = (int)rc >= 0;
	*code = (int)rc;

	return 0;
}
