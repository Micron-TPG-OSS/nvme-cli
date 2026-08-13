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
 * Create a pipe. fds[0] is the read end, fds[1] the write end. On Windows the
 * pipe is opened in binary mode (no CRLF translation).
 * Return: 0 on success, -errno otherwise.
 */
int shr_pipe(int fds[2]);

/*
 * Spawn argv[0] with arguments argv (NULL-terminated) WITHOUT a shell,
 * synchronously waiting for it, and report how it ended. No command string is
 * built, so there is no shell to interpret metacharacters. argv[0] must be a
 * path to the executable (no PATH search), mirroring _spawnv()/execv().
 *
 * If out_fd/err_fd are >= 0, the child's stdout/stderr are redirected to them
 * (pass the same fd for both to merge, the 2>&1 equivalent); -1 means inherit.
 *
 * The child is waited for before returning, so its total output must fit within
 * the OS pipe buffer if out_fd/err_fd point at a pipe whose read end is drained
 * afterward.
 *
 * On success, *exited is set true if the child terminated normally and *code to
 * its exit status; *exited is false if it crashed or was killed by a signal.
 * Return: 0 on success, -errno if the child could not be spawned or waited for.
 */
int shr_spawn_sync(const char *const argv[], int out_fd, int err_fd,
		   bool *exited, int *code);
